#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Re-touch external_source DNS zones after peer also-notify support was added.
#
# Background:
# The previous maintenance task backfilled peer `secondaries` to restore
# AXFR/IXFR between vpsAdmin-managed DNS servers. That only fixed part of the
# issue:
#  - older zones may still be missing peer secondaries in `primaries`
#  - external zones need to be touched again after the libnodectld deployment
#    so BIND config is regenerated with `also-notify`
#
# This script enqueues transactions to:
#  - recompute peer vpsAdmin DNS servers for each external_source DnsServerZone
#  - re-apply those peers into both `primaries` and `secondaries`
#  - reload BIND once per affected DNS server
#
# Dry-run by default.
#
# Usage (dry-run):
#   ./2026-04-11-fix-external-dns-zone-peer-notify/fix_external_dns_zone_peer_notify.rb \
#     --plan /root/external-dns-peer-notify-plan.json
#
# Usage (execute):
#   ./2026-04-11-fix-external-dns-zone-peer-notify/fix_external_dns_zone_peer_notify.rb \
#     --plan /root/external-dns-peer-notify-plan.json --execute
#
# Optional filters:
#   --zone example.com.       (only this zone)
#   --server ns3.vpsfree.cz   (only this DNS server)
#
require 'vpsadmin'
require 'json'
require 'optparse'
require 'time'

options = {
  execute: false
}

OptionParser.new do |opts|
  opts.banner = 'Usage: fix_external_dns_zone_peer_notify.rb [options]'

  opts.on('--plan PATH', 'Write plan JSON to PATH') do |value|
    options[:plan] = value
  end

  opts.on('--execute', 'Enqueue transaction chains (default: dry-run)') do
    options[:execute] = true
  end

  opts.on('--zone NAME', 'Only this zone') do |value|
    options[:zone] = value
  end

  opts.on('--server NAME', 'Only this DNS server') do |value|
    options[:server] = value
  end

  opts.on('-h', '--help', 'Show this help') do
    puts opts
    exit 0
  end
end.parse!

zone_name_filter = options[:zone]
server_name_filter = options[:server]
plan_path = options[:plan]
execute = options[:execute]

zone_scope = DnsZone.existing.where(zone_source: :external_source)
if zone_name_filter && !zone_name_filter.empty?
  zone_scope = zone_scope.where(name: zone_name_filter)
end

# Preload relationships to avoid excessive queries.
zones = zone_scope.includes(dns_server_zones: { dns_server: :node }).to_a

# actions_by_zone:
# {
#   DnsZone => [
#     {
#       dns_server_zone_id:,
#       dns_zone_id:,
#       zone_name:,
#       dns_server_id:,
#       dns_server_name:,
#       dns_server_node_id:,
#       peers: [server_opts...]
#     }
#   ]
# }
actions_by_zone = Hash.new { |h, k| h[k] = [] }

zones.each do |zone|
  # All vpsAdmin-hosted server-zones of this external zone.
  server_zones = zone.dns_server_zones.existing.includes(dns_server: :node).to_a
  next if server_zones.empty?

  # Precompute server_opts for each existing vpsAdmin server-zone. Every
  # server-zone is updated with all other server-zones as peers.
  opts_by_id = server_zones.to_h { |dsz| [dsz.id, dsz.server_opts] }

  server_zones.each do |dsz|
    dns_server = dsz.dns_server

    if server_name_filter && !server_name_filter.empty?
      next if dns_server.name != server_name_filter
    end

    peers = opts_by_id.each_with_object([]) do |(other_id, other_opts), ret|
      next if other_id == dsz.id
      ret << other_opts
    end

    next if peers.empty?

    actions_by_zone[zone] << {
      dns_server_zone_id: dsz.id,
      dns_zone_id: zone.id,
      zone_name: zone.name,
      dns_server_id: dns_server.id,
      dns_server_name: dns_server.name,
      dns_server_node_id: dns_server.node_id,
      peers:
    }
  end
end

plan = {
  generated_at: Time.now.utc.iso8601,
  execute:,
  filters: {
    zone: zone_name_filter,
    server: server_name_filter
  },
  zones: actions_by_zone.map do |zone, actions|
    {
      dns_zone_id: zone.id,
      name: zone.name,
      servers: actions.sort_by { |a| a[:dns_server_name] }.map do |a|
        {
          dns_zone_id: a[:dns_zone_id],
          dns_server_zone_id: a[:dns_server_zone_id],
          dns_server_id: a[:dns_server_id],
          dns_server_name: a[:dns_server_name],
          dns_server_node_id: a[:dns_server_node_id],
          peer_ip_addrs: a[:peers].map { |p| p[:ip_addr] || p['ip_addr'] },
          peers: a[:peers]
        }
      end
    }
  end.sort_by { |z| z[:name] }
}

server_zone_count = actions_by_zone.values.sum(&:count)
zone_count = actions_by_zone.keys.count
server_count = actions_by_zone.values.flat_map { |actions| actions.map { |a| a[:dns_server_id] } }.uniq.count

puts "Found #{server_zone_count} external zone server-instances to update across #{server_count} DNS servers (#{zone_count} zones)"

if plan_path && !plan_path.empty?
  File.write(plan_path, JSON.pretty_generate(plan))
  puts "Wrote plan to #{plan_path}"
end

unless execute
  puts 'Dry-run: pass --execute to enqueue transaction chains'
  exit 0
end

module TransactionChains
  module Maintenance
    remove_const(:Custom) if const_defined?(:Custom)

    class Custom < TransactionChain
      label 'Fix external DNS zone peer notify'

      # @param _dns_zone_id [Integer]
      # @param action_list [Array<Hash>]
      def link_chain(_dns_zone_id, action_list)
        dns_server_ids = {}

        action_list.each do |a|
          dsz = ::DnsServerZone.find(a.fetch(:dns_server_zone_id))
          peers = a.fetch(:peers)

          next if peers.nil? || peers.empty?

          append_t(
            ::Transactions::DnsServerZone::AddServers,
            args: [dsz],
            kwargs: {
              primaries: peers,
              secondaries: peers
            }
          )

          dns_server_ids[dsz.dns_server_id] = true
        end

        dns_server_ids.keys.sort.each do |server_id|
          append_t(::Transactions::DnsServer::Reload, args: [::DnsServer.find(server_id)])
        end
      end
    end
  end
end

actions_by_zone.each do |zone, actions|
  next if actions.empty?

  chain, _ret = TransactionChains::Maintenance::Custom.fire(
    zone.id,
    actions
  )

  puts "Queued chain ##{chain.id} for #{zone.name} (#{actions.length} servers)"
end
