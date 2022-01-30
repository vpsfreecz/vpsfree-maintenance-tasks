#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Remove all snapshots from primary pool. If the snapshots are backed up, only
# the copy from primary pool is removed. If there's no backup, the snapshots
# are removed completely.

require 'vpsadmin'

DATASET_NAME = ARGV[0]

module TransactionChains
  module Maintenance
    remove_const(:Custom)

    class Custom < TransactionChain
      label 'Clear snapshots'

      def link_chain
        ds = ::Dataset.find_by!(full_name: DATASET_NAME)
        dip = ds.primary_dataset_in_pool!
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

        use_chain(Dataset::Snapshot, args: [dip])

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

chain, _ = TransactionChains::Maintenance::Custom.fire

puts "wait for the chain to finish"
60.times do
  c = ::TransactionChain.find(chain.id)
  if c.state == 'done'
    puts "chain done"
    break
  end
  fail 'chain error' if c.state != 'queued'
  sleep(1)
end

begin
  ds = ::Dataset.find_by!(full_name: DATASET_NAME)
  dip = ds.primary_dataset_in_pool!
  action = DatasetAction.find_by!(
      src_dataset_in_pool: dip,
      action: DatasetAction.actions['backup']
  )

  task = RepeatableTask.find_for!(action)

  puts 'Backup dataset action:'
  puts "  DatasetAction  id = #{action.id}"
  puts "  RepeatableTask id = #{task.id}"

  cmd = "/opt/vpsadmin/api/bin/vpsadmin-run-task /var/run/vpsadmin-scheduler.sock #{task.id}"
  puts "Executing task"
  puts cmd
  puts `#{cmd}`

rescue ActiveRecord::RecordNotFound => e
  p e
end
