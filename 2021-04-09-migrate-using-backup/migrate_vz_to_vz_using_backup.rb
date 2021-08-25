#!/usr/bin/env ruby
# Migrate vz->vz VPS and make the first transfer from backuper if possible.
# It works only if there's just one snapshot on the hypervisor and if it is
# it the backup.

Dir.chdir('/opt/vpsadmin/api')

require '/opt/vpsadmin/api/lib/vpsadmin'
require '/opt/vpsadmin/api/models/transaction_chains/vps/migrate/base'

module TransactionChains
  module Maintenance
    remove_const(:Custom)
  end

  # Migrate VPS between two OpenVZ nodes through backuper
  class Maintenance::Custom < Vps::Migrate::Base
    label 'Migrate'

    def link_chain(vps, dst_node, opts = {})
      if vps.node.hypervisor_type != 'openvz' || dst_node.hypervisor_type != 'openvz'
        fail 'invalid hypervisor'
      end

      if vps.node_id == dst_node.id
        fail 'already there'
      end

      setup(vps, dst_node, opts)

      # Mail notification
      notify_begun

      # Transfer resources if the destination node is in a different
      # environment.
      transfer_cluster_resources

      # Copy configs, create /vz/root/$veid
      append(Transactions::Vps::CopyConfigs, args: [src_vps, dst_node])
      append(Transactions::Vps::CreateRoot, args: [src_vps, dst_node])

      # Create datasets
      datasets.each do |pair|
        src, dst = pair

        # Transfer resources
        if environment_changed?
          # This code expects that the datasets have a just one cluster resource,
          # which is diskspace.
          changes = src.transfer_resources_to_env!(vps_user, dst_node.location.environment)
          changes[changes.keys.first][:row_id] = dst.id
          resources_changes.update(changes)

        else
          ::ClusterResourceUse.for_obj(src).each do |use|
            resources_changes[use] = {row_id: dst.id}
          end
        end

        # Create datasets with canmount=off for the transfer
        append_t(Transactions::Storage::CreateDataset, args: [
          dst, {canmount: 'off'}, {create_private: false},
        ]) { |t| t.create(dst) }

        # Set all properties except for quotas to ensure send/recv will pass
        props = {}

        src.dataset_properties.where(inherited: false).each do |p|
          next if %w(quota refquota).include?(p.name)
          props[p.name.to_sym] = [p, p.value]
        end

        append(Transactions::Storage::SetDataset, args: [dst, props]) if props.any?
      end

      # Unmount VPS datasets & snapshots in other VPSes
      mounts = Vps::Migrate::MountMigrator.new(self, vps, dst_vps)
      mounts.umount_others

      # Transfer datasets
      migration_snapshots = []

      # Port for transfer from backup
      port = ::PortReservation.reserve(
        dst_node,
        dst_node.addr,
        self,
      )

      datasets.each do |pair|
        src, dst = pair

        # Find the last backup.. if we can't find the right thing, we fail
        hypervisor_sip = src.snapshot_in_pools.all.last

        backup_sip = hypervisor_sip.snapshot.snapshot_in_pools
          .joins(dataset_in_pool: [:pool])
          .where(pools: {role: ::Pool.roles[:backup]})
          .take

        if backup_sip.nil?
          fail 'last snapshot not in backup'
        end
        
        snap_in_branch = backup_sip.snapshot_in_pool_in_branches
                           .where.not(confirmed: ::SnapshotInPoolInBranch.confirmed(:confirm_destroy)).take!
        
        use_chain(Dataset::Send, args: [
          port,
          backup_sip.dataset_in_pool,
          dst,
          [backup_sip],
          snap_in_branch.branch,
          nil,
          true,
        ])
      end
        
      # Reserve a slot in zfs_send queue
      append(Transactions::Queue::Reserve, args: [src_node, :zfs_send])

      # Transfer current changes from the backup
      datasets.each do |pair|
        src, dst = pair

        migration_snapshots << use_chain(Dataset::Snapshot, args: src)
        use_chain(Dataset::Transfer, args: [src, dst])
      end

      if @opts[:maintenance_window]
        # Temporarily release the reserved spot in the queue, we'll get another
        # reservation within the maintenance window
        append(Transactions::Queue::Release, args: [src_node, :zfs_send])

        # Wait for the outage window to open
        append(Transactions::MaintenanceWindow::Wait, args: [src_vps, 15])
        append(Transactions::Queue::Reserve, args: [src_node, :zfs_send])
        append(Transactions::MaintenanceWindow::InOrFail, args: [src_vps, 15])

        # Second transfer while inside the outage window. The VPS is still running.
        datasets.each do |pair|
          src, dst = pair

          migration_snapshots << use_chain(Dataset::Snapshot, args: src, urgent: true)
          use_chain(Dataset::Transfer, args: [src, dst], urgent: true)
        end

        # Check if we're still inside the outage window. We're in if the window
        # closes in not less than 5 minutes. Fail if not.
        append(Transactions::MaintenanceWindow::InOrFail, args: [src_vps, 5], urgent: true)
      end

      # Stop the VPS
      use_chain(Vps::Stop, args: src_vps, urgent: true)

      datasets.each do |pair|
        src, dst = pair

        # The final transfer is done when the VPS is stopped
        migration_snapshots << use_chain(Dataset::Snapshot, args: src, urgent: true)
        use_chain(Dataset::Transfer, args: [src, dst], urgent: true)
      end

      # Set quotas when all data is transfered
      datasets.each do |pair|
        src, dst = pair
        props = {}

        src.dataset_properties.where(inherited: false, name: %w(quota refquota)).each do |p|
          props[p.name.to_sym] = [p, p.value]
        end

        append(
          Transactions::Storage::SetDataset,
          args: [dst, props],
          urgent: true,
        ) if props.any?
      end

      # Set canmount=on on all datasets and mount them
      append(Transactions::Storage::SetCanmount, args: [
        datasets.map { |src, dst| dst },
        canmount: 'on',
        mount: true,
      ], urgent: true)

      dst_ip_addresses = vps.ip_addresses

      # Migration to different location - remove or replace IP addresses
      migrate_network_interfaces

      # Regenerate mount scripts of the migrated VPS
      mounts.datasets = datasets
      mounts.remount_mine

      # Wait for routing to remove routes from the original system
      append(Transactions::Vps::WaitForRoutes, args: [dst_vps], urgent: true)

      # Restore VPS state
      call_hooks_for(:pre_start, self, args: [dst_vps, was_running?])
      use_chain(Vps::Start, args: dst_vps, urgent: true, reversible: :keep_going) if was_running?
      call_hooks_for(:post_start, self, args: [dst_vps, was_running?])

      # Remount and regenerate mount scripts of mounts in other VPSes
      mounts.remount_others

      # Release reserved spot in the queue
      append(Transactions::Queue::Release, args: [src_node, :zfs_send], urgent: true)

      # Remove migration snapshots
      migration_snapshots.each do |sip|
        dst_sip = sip.snapshot.snapshot_in_pools.joins(:dataset_in_pool).where(
          dataset_in_pools: {pool_id: dst_pool.id}
        ).take!

        use_chain(SnapshotInPool::Destroy, args: dst_sip, urgent: true)
      end

      # Move the dataset in pool to the new pool in the database
      append_t(Transactions::Utils::NoOp, args: dst_node.id, urgent: true) do |t|
        t.edit(src_vps, dataset_in_pool_id: datasets.first[1].id)
        t.edit(src_vps, node_id: dst_node.id)

        # Transfer resources
        resources_changes.each do |use, changes|
          t.edit(use, changes) unless changes.empty?
        end

        # Handle dataset properties
        datasets.each do |src, dst|
          src.dataset_properties.all.each do |p|
            t.edit(p, dataset_in_pool_id: dst.id)
          end

          migrate_dataset_plans(src, dst, t)
        end

        t.just_create(src_vps.log(:node, {
          src: {id: src_node.id, name: src_node.domain_name},
          dst: {id: dst_node.id, name: dst_node.domain_name},
        }))
      end

      # Call DatasetInPool.migrated hook
      datasets.each do |src, dst|
        src.call_hooks_for(:migrated, self, args: [src, dst])
      end

      # Setup firewall and shapers
      # Unregister from firewall and remove shaper on source node
      if @opts[:handle_ips]
        use_chain(Vps::FirewallUnregister, args: src_vps, urgent: true)
        use_chain(Vps::ShaperUnset, args: src_vps, urgent: true)
      end

      # Is is needed to register IP in fw and shaper when changing location,
      # as IPs are removed or replaced sooner.
      unless location_changed?
        # Register to firewall and set shaper on destination node
        use_chain(Vps::FirewallRegister, args: [dst_vps, dst_ip_addresses], urgent: true)
        use_chain(Vps::ShaperSet, args: [dst_vps, dst_ip_addresses], urgent: true)
      end

      # Destroy old dataset in pools
      # Do not detach backup trees and branches
      # Do not delete repeatable tasks - they are re-used for new datasets
      use_chain(DatasetInPool::Destroy, args: [src_vps.dataset_in_pool, {
        recursive: true,
        top: true,
        tasks: false,
        detach_backups: false,
        destroy: @opts[:cleanup_data],
      }])

      # Destroy old root
      append(Transactions::Vps::Destroy, args: src_vps)

      # Mail notification
      notify_finished

      # fail 'ohnoes'
      self
    end
  end
end

if ARGV.length != 2
  fail "usage: #{$0} vps_id dst_node_id"
end

vps = ::Vps.find(ARGV[0].to_i)
dst_node = ::Node.find(ARGV[1].to_i)

# if vps_id.node_id != 111
#   fail 'dude its only for node10 ok?'
# end

chain, _ = TransactionChains::Maintenance::Custom.fire(
  vps,
  dst_node,
  #replace_ips: false,
  #transfer_ips: false,
  #swap: :force,
  maintenance_window: false,
  send_mail: true,
  reason: 'explain yourself',
  cleanup_data: false,
)

loop do
  puts "waiting for chain #{chain.id} to finish ok"
  c = ::TransactionChain.find(chain.id)
  if c.state == 'done'
    puts "chain #{chain.id} done"
    break
  end
  fail "chain #{chain.id} error" if c.state != 'queued'
  sleep(3)
end
