#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Fix external_source DNS zones on vpsAdmin-managed DNS servers.
#
# Background:
# Older vpsAdmin versions sent `secondaries: []` to nodectld when creating a
# DnsServerZone for an external_source zone. nodectld then generated BIND config
# with `allow-transfer { none; };`, which blocks AXFR/IXFR between vpsAdmin
# secondaries.
#
# This script enqueues transactions to:
#  - add the computed peer secondaries to each external_source DnsServerZone
#  - reload BIND once per DNS server
#
# Dry-run by default.
#
# Usage (dry-run):
#   PLAN=/root/external-dns-secondaries-plan.json \
#     ./2026-02-18-fix-external-dns-zone-secondaries/fix_external_dns_zone_secondaries.rb
#
# Usage (execute):
#   PLAN=/root/external-dns-secondaries-plan.json EXECUTE=yes \
#     ./2026-02-18-fix-external-dns-zone-secondaries/fix_external_dns_zone_secondaries.rb
#
# Optional filters:
#   ZONE=example.com.         (only this zone)
#   SERVER=ns3.vpsfree.cz     (only this DNS server)
#
require 'vpsadmin'
require 'json'
require 'time'

def truthy?(v)
  %w[1 yes true y].include?(v.to_s.strip.downcase)
end

zone_name_filter = ENV['ZONE']
server_name_filter = ENV['SERVER']
plan_path = ENV['PLAN']
execute = truthy?(ENV['EXECUTE'])

zone_scope = DnsZone.existing.where(zone_source: :external_source)
if zone_name_filter && !zone_name_filter.empty?
  zone_scope = zone_scope.where(name: zone_name_filter)
end

# Preload relationships to avoid excessive queries
zones = zone_scope.includes(dns_server_zones: { dns_server: :node }, dns_zone_transfers: [:host_ip_address, :dns_tsig_key]).to_a

# actions_by_server: { DnsServer => [ { dns_server_zone_id:, dns_zone_id:, zone_name:, peers: [server_opts...] } ] }
actions_by_server = Hash.new { |h, k| h[k] = [] }

zones.each do |zone|
  # All vpsAdmin-hosted server-zones of this external zone
  server_zones = zone.dns_server_zones.existing.includes(dns_server: :node).to_a
  next if server_zones.empty?

  # Base peers coming from zone transfers (if any)
  transfer_secondaries = zone.dns_zone_transfers.secondary_type.map(&:server_opts)

  # Precompute server_opts per server_zone for this zone
  opts_by_id = server_zones.to_h { |dsz| [dsz.id, dsz.server_opts] }

  server_zones.each do |dsz|
    dns_server = dsz.dns_server

    if server_name_filter && !server_name_filter.empty?
      next if dns_server.name != server_name_filter
    end

    # Peers = all other secondaries for this zone + transfer secondaries
    peers = transfer_secondaries.dup
    opts_by_id.each do |other_id, other_opts|
      next if other_id == dsz.id
      peers << other_opts
    end

    next if peers.empty?

    actions_by_server[dns_server] << {
      dns_server_zone_id: dsz.id,
      dns_zone_id: zone.id,
      zone_name: zone.name,
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
  servers: actions_by_server.map do |dns_server, actions|
    {
      dns_server_id: dns_server.id,
      dns_server_name: dns_server.name,
      node_id: dns_server.node_id,
      zones: actions.sort_by { |a| a[:zone_name] }.map do |a|
        {
          dns_zone_id: a[:dns_zone_id],
          dns_server_zone_id: a[:dns_server_zone_id],
          name: a[:zone_name],
          peer_ip_addrs: a[:peers].map { |p| p[:ip_addr] || p['ip_addr'] },
          peers: a[:peers]
        }
      end
    }
  end.sort_by { |s| s[:dns_server_name] }
}

# Print summary
server_count = actions_by_server.keys.count
zone_count = actions_by_server.values.sum(&:count)

puts "Found #{zone_count} external zone server-instances to update across #{server_count} DNS servers"

if plan_path && !plan_path.empty?
  File.write(plan_path, JSON.pretty_generate(plan))
  puts "Wrote plan to #{plan_path}"
end

if !execute
  puts "Dry-run: set EXECUTE=yes to enqueue transaction chains"
  exit 0
end

# Transaction chain definition
module TransactionChains
  module Maintenance
    remove_const(:Custom) if const_defined?(:Custom)

    class Custom < TransactionChain
      label 'Fix external DNS zone secondaries'

      # @param dns_server_id [Integer]
      # @param action_list [Array<Hash>]
      def link_chain(dns_server_id, action_list)
        dns_server = DnsServer.find(dns_server_id)

        action_list.each do |a|
          dsz = DnsServerZone.find(a.fetch(:dns_server_zone_id))
          peers = a.fetch(:peers)

          next if peers.nil? || peers.empty?

          append_t(
            Transactions::DnsServerZone::AddServers,
            args: [dsz],
            kwargs: { secondaries: peers }
          )
        end

        # Apply all updated zones on this server
        append_t(Transactions::DnsServer::Reload, args: [dns_server])
      end
    end
  end
end

# Enqueue one chain per DNS server
actions_by_server.each do |dns_server, actions|
  next if actions.empty?

  chain, _ret = TransactionChains::Maintenance::Custom.fire(
    dns_server.id,
    actions
  )

  puts "Queued chain ##{chain.id} for #{dns_server.name} (#{actions.length} zones)"
end
