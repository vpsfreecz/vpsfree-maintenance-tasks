#!/usr/bin/env ruby
# Remove all snapshots from primary pool. If the snapshots are backed up, only
# the copy from primary pool is removed. If there's no backup, the snapshots
# are removed completely.

ORIG_PWD = Dir.pwd

Dir.chdir('/opt/vpsadmin/api')
require '/opt/vpsadmin/api/lib/vpsadmin'

VPS_ID = ARGV[0].to_i

module TransactionChains
  module Maintenance
    remove_const(:Custom)

    class Custom < TransactionChain
      label 'Clear snapshots'

      def link_chain
        vps = ::Vps.find(VPS_ID)
        dip = vps.dataset_in_pool
        ds = dip.dataset
        any = false

        lock(dip)

        dip.snapshot_in_pools.each do |sip|
          any = true
          sip.update!(confirmed: ::SnapshotInPool.confirmed(:confirm_destroy))
          cleanup = cleanup_snapshot?(sip)

          if cleanup
            puts "purge #{dip.pool.node.domain_name}:#{ds.full_name}@#{sip.snapshot.name}"
          else
            puts "destroy #{dip.pool.node.domain_name}:#{ds.full_name}@#{sip.snapshot.name}"
          end

          append_t(Transactions::Storage::DestroySnapshot, args: sip) do |t|
            t.destroy(sip)
            t.destroy(sip.snapshot) if cleanup
          end
        end

        if any
          puts "detach backup heads"
          use_chain(DatasetInPool::DetachBackupHeads, args: dip)
        end

        # fail 'not yet bro'
      end

      protected
      def cleanup_snapshot?(snapshot_in_pool)
        ::Snapshot.joins(:snapshot_in_pools)
          .where(snapshots: {id: snapshot_in_pool.snapshot_id})
          .where.not(snapshot_in_pools: {confirmed: ::SnapshotInPool.confirmed(:confirm_destroy)}).count == 0
      end
    end
  end
end

TransactionChains::Maintenance::Custom.fire
