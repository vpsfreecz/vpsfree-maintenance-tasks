#!/usr/bin/env ruby
# Remove all snapshots in pools that point to a non-existent dataset in pool.
# These snapshots were left over by a faulty os-to-os VPS migration.

ORIG_PWD = Dir.pwd

Dir.chdir('/opt/vpsadmin/api')
require '/opt/vpsadmin/api/lib/vpsadmin'

class Snapshot
  remove_method :destroy
end

module TransactionChains
  module Maintenance
    remove_const(:Custom)

    class Custom < TransactionChain
      label 'Clear snapshots'

      def link_chain
        ::SnapshotInPool
          .joins('LEFT JOIN dataset_in_pools ON dataset_in_pools.id = snapshot_in_pools.dataset_in_pool_id')
          .where('dataset_in_pools.id IS NULL')
          .each do |sip|
          s = sip.snapshot
          ds = sip.snapshot.dataset

          next if sip.snapshot.dataset.nil?

          puts "Found #{ds.full_name}@#{s.name} (sip=#{sip.id})"

          begin
            vps = ::Vps.find(ds.name.to_i)
          rescue ActiveRecord::RecordNotFound
            puts "  VPS not found"
          end

          if vps
            remove_from_vps(sip, vps)
          else
            remove_from_dataset(sip, ds)
          end
        end

        # fail 'not yet bro'
      end

      protected
      def remove_from_vps(sip, vps)
        puts "  VPS #{vps.id} on #{vps.dataset_in_pool.pool.node.domain_name}"

        dip = vps.dataset_in_pool
        ds = dip.dataset

        lock(dip)
        remove_sip_from_dip(sip, dip)
      end

      def remove_from_dataset(sip, ds)
        begin
          dip = ds.primary_dataset_in_pool!
        rescue ActiveRecord::RecordNotFound
          puts "  primary dip not found, just remove it"
          s = sip.snapshot
          sip.update!(confirmed: ::SnapshotInPool.confirmed(:confirm_destroy))
          cleanup = cleanup_snapshot?(sip)
          sip.destroy!
          s.destroy! if cleanup
          return
        end

        puts "  found primary ds on #{dip.pool.node.domain_name}"
        lock(dip)

        remove_sip_from_dip(sip, dip)
      end

      def remove_sip_from_dip(sip, dip)
        sip.update!(
          confirmed: ::SnapshotInPool.confirmed(:confirm_destroy),
          dataset_in_pool_id: dip.id,
        )
        cleanup = cleanup_snapshot?(sip)

        if cleanup
          puts "  purge #{dip.pool.node.domain_name}:#{dip.dataset.full_name}@#{sip.snapshot.name}"
        else
          puts "  destroy #{dip.pool.node.domain_name}:#{dip.dataset.full_name}@#{sip.snapshot.name}"
        end

        append_t(
          Transactions::Storage::DestroySnapshot,
          args: sip,
          reversible: :keep_going,
        )
        append_t(Transactions::Utils::NoOp, args: find_node_id) do |t|
          t.edit_before(sip, dataset_in_pool_id: nil)
          t.destroy(sip)
          t.destroy(sip.snapshot) if cleanup
        end
      end

      def cleanup_snapshot?(snapshot_in_pool)
        ::Snapshot.joins(:snapshot_in_pools)
          .where(snapshots: {id: snapshot_in_pool.snapshot_id})
          .where.not(snapshot_in_pools: {confirmed: ::SnapshotInPool.confirmed(:confirm_destroy)}).count == 0
      end
    end
  end
end

TransactionChains::Maintenance::Custom.fire
