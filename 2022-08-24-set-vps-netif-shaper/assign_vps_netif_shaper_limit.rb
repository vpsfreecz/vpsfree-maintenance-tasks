#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Usage: $0 <node id> [execute]
#
# Description: set network interface shaper on the selected node
require 'vpsadmin'

module TransactionChains
  module Maintenance
    remove_const(:Custom)

    class Custom < TransactionChain
      label 'Shaper'

      def link_chain(node_id, execute_it)
        ::Vps.where(
          node_id: node_id,
          object_state: [
            ::Vps.object_states[:active],
            ::Vps.object_states[:suspended],
            ::Vps.object_states[:soft_delete],
          ],
        ).each do |vps|
          vps.network_interfaces.each do |netif|
            puts "VPS #{vps.id} #{netif.name}"

            max_tx_ip = netif.ip_addresses.order('max_tx DESC').take
            max_tx = max_tx_ip ? max_tx_ip.max_tx * 8 : 300 * 1024 * 1024

            max_rx_ip = netif.ip_addresses.order('max_rx DESC').take
            max_rx = max_rx_ip ? max_rx_ip.max_rx * 8 : 300 * 1024 * 1024

            puts "  TX = #{(max_tx / 1024.0 / 1024).round} Mbps"
            puts "  RX = #{(max_rx / 1024.0 / 1024).round} Mbps"
            puts

            use_chain(
              TransactionChains::NetworkInterface::Update,
              args: [
                netif,
                {max_tx: max_tx, max_rx: max_rx},
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
  warn "Usage: #{$0} <node id> [execute]"
  exit(false)
end

TransactionChains::Maintenance::Custom.fire(ARGV[0].to_i, ARGV[1] == 'execute')
