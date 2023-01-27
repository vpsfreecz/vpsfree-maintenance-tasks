#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Reconfigure shaper on selected nodes
#
# Usage: $0 <location domains> [execute]
#
require 'vpsadmin'

NEW_LIMIT = 1000*1024*1024 # bps

module TransactionChains
  module Maintenance
    remove_const(:Custom)

    class Custom < TransactionChain
      label 'Shaper'
      allow_empty

      def link_chain(node, new_limit, execute_it)
        ::Vps.where(
          node: node,
          object_state: [
            ::Vps.object_states[:active],
            ::Vps.object_states[:suspended],
            ::Vps.object_states[:soft_delete],
          ],
        ).each do |vps|
          vps.network_interfaces.each do |netif|
            puts "#{vps.node.domain_name}: VPS #{vps.id} #{netif.name}"
            puts "  TX = #{(new_limit / 1024.0 / 1024).round} Mbps"
            puts "  RX = #{(new_limit / 1024.0 / 1024).round} Mbps"
            puts

            use_chain(
              TransactionChains::NetworkInterface::Update,
              args: [
                netif,
                {max_tx: new_limit, max_rx: new_limit},
              ],
              reversible: :keep_going,
            )
          end
        end

        fail 'not yet bro' unless execute_it
      end
    end
  end
end

if ARGV.length < 1
  warn "Usage: #{$0} <location domains> [execute]"
  exit(false)
end

domains = ARGV[0].split(',')

::Node.joins(:location).where(
  locations: {domain: domains},
  nodes: {active: true, role: 'hypervisor'},
).each do |node|
  puts "### #{node.domain_name}"
  TransactionChains::Maintenance::Custom.fire(node, NEW_LIMIT, ARGV[1] == 'execute')
  puts
  puts
  puts "Pres enter to continue"
  STDIN.readline
end
