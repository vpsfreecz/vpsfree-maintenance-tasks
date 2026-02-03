#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Configure swap for all active and suspended VPS in Staging.
#
# Usage:
#   ./add_swap_on_staging.rb

require 'vpsadmin'

ENVIRONMENT_LABEL = 'Staging'
SWAP_MIB = 8192

module TransactionChains
  module Maintenance
    remove_const(:Custom)

    class Custom < TransactionChain
      label 'Add swap on staging'
      allow_empty

      def link_chain(vpses, swap_mib)
        vpses.each do |vps|
          desired_swap = swap_mib

          puts "VPS #{vps.id} #{vps.node.domain_name}: swap #{vps.swap} -> #{desired_swap} MiB"
          concerns(:affect, [vps.class.name, vps.id])
          lock(vps)

          resources = vps.reallocate_resources(
            { memory: vps.memory, swap: desired_swap },
            vps.user,
            chain: self,
          )

          use_chain(TransactionChains::Vps::SetResources, args: [vps, resources])
        end
      end
    end
  end
end

env = ::Environment.find_by!(label: ENVIRONMENT_LABEL)

vpses = ::Vps.joins(node: :location).where(
  object_state: [
    ::Vps.object_states[:active],
    ::Vps.object_states[:suspended],
  ],
  locations: { environment_id: env.id },
).order('vpses.id')

TransactionChains::Maintenance::Custom.fire(vpses, SWAP_MIB)
