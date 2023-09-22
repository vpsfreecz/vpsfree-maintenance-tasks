#!/run/current-system/sw/bin/vpsadmin-api-ruby
# There was a bug in vpsAdmin which broke VPS chowned by cloning. User namespace
# map wasn't updated, so the VPS kept using mapping of the original user. When
# that user was deleted, the VPS was left pointing to a no longer existing map id.
#
require 'vpsadmin'

module CustomTransactions
  class UseMap < ::Transaction
    t_name :userns_map_use
    t_type 7001
    queue :general

    include Transactions::Utils::UserNamespaces

    def params(vps, userns_map)
      self.node_id = vps.node_id
      self.vps_id = vps.id

      {
        pool_fs: vps.dataset_in_pool.pool.filesystem,
        name: userns_map.id.to_s,
        uidmap: build_map(userns_map, :uid),
        gidmap: build_map(userns_map, :gid),
      }
    end
  end

  class DisuseMap < ::Transaction
    t_name :userns_map_disuse
    t_type 7002
    queue :general

    include Transactions::Utils::UserNamespaces

    def params(vps, old_map_id, userns_map)
      self.node_id = vps.node_id
      self.vps_id = vps.id

      {
        pool_fs: vps.dataset_in_pool.pool.filesystem,
        name: old_map_id.to_s,
        uidmap: build_map(userns_map, :uid),
        gidmap: build_map(userns_map, :gid),
      }
    end
  end

  class Chown < ::Transaction
    t_name :vps_chown
    t_type 3041
    queue :vps

    def params(vps, current_userns_map_id, new_userns_map_id)
      self.vps_id = vps.id
      self.node_id = vps.node_id

      {
        original_user_id: vps.user_id,
        original_userns_map: current_userns_map_id.to_s,
        new_user_id: vps.user_id,
        new_userns_map: new_userns_map_id.to_s,
      }
    end
  end
end

module TransactionChains
  module Maintenance
    remove_const(:Custom)

    class Custom < TransactionChain
      label 'Fix userns'

      def link_chain(vps)
        if vps.user_namespace_map
          fail "Current mapping exists, no need to run this script"
        end

        uns = vps.user.user_namespaces.take!
        new_map = uns.user_namespace_maps.take!

        puts "VPS #{vps.id}:"
        puts "  Current map id: #{vps.user_namespace_map_id}"
        puts "  Correct map id: #{new_map.id} (#{new_map.label})"
        puts "y/Y to continue"

        unless STDIN.readline.strip.downcase == 'y'
          fail 'Aborted'
        end

        concerns(:affect, [vps.class.name, vps.id])

        append(CustomTransactions::UseMap, args: [vps, new_map])

        append_t(CustomTransactions::Chown, args: [
          vps,
          vps.user_namespace_map_id,
          new_map.id,
        ]) do |t|
          t.edit(vps, user_namespace_map_id: new_map.id)
        end

        append(CustomTransactions::DisuseMap, args: [vps, vps.user_namespace_map_id, new_map])
      end
    end
  end
end

if ARGV.length != 1
  fail "Usage: #{$0} <vps_id>"
end

TransactionChains::Maintenance::Custom.fire(::Vps.find(ARGV[0]))
