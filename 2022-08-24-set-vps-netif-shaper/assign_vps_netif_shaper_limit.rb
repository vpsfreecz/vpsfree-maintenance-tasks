#!/run/current-system/sw/bin/vpsadmin-api-ruby
require 'vpsadmin'

module TransactionChains
  module Maintenance
    remove_const(:Custom)

    class Custom < TransactionChain
      label 'Shaper'

      def link_chain
        ::Vps.where(
          node_id: 400,
          object_state: [
            ::Vps.object_states[:active],
            ::Vps.object_states[:suspended],
            ::Vps.object_states[:soft_delete],
          ],
        ).each do |vps|
          vps.network_interfaces.each do |netif|
            puts "VPS #{vps.id} #{netif.name}"

            use_chain(TransactionChains::NetworkInterface::Update, args: [netif, {
              max_tx: 300 * 1024 * 1024,
              max_rx: 300 * 1024 * 1024,
            }])
          end
        end

        fail 'not yet bro'
      end
    end
  end
end

TransactionChains::Maintenance::Custom.fire
