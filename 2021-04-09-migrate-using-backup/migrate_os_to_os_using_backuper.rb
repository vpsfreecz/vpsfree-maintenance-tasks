#!/usr/bin/env ruby
# Migrate os->os VPS and make the first transfer from backuper if possible.
# It works only if there's just one snapshot on the hypervisor and if it is
# it the backup.

Dir.chdir('/opt/vpsadmin/api')

require '/opt/vpsadmin/api/lib/vpsadmin'
require '/opt/vpsadmin/api/models/transaction_chains/vps/migrate/base'

module TransactionChains
  module Maintenance
    remove_const(:Custom)
  end

  # Migrate VPS between two vpsAdminOS nodes through backuper
  class Maintenance::Custom < Vps::Migrate::Base
    label 'Migrate'

    def link_chain(vps, dst_node, opts = {})
      if vps.node.hypervisor_type != 'vpsadminos' || dst_node.hypervisor_type != 'vpsadminos'
        fail 'invalid hypervisor'
      end

      if vps.node_id == dst_node.id
        fail 'already there'
      end
      
      self.userns_map = vps.userns_map

      setup(vps, dst_node, opts)
      token = SecureRandom.hex(6)

      # Check swap is available on the destination node
      check_swap!

      # Mail notification
      notify_begun

      # Transfer resources if the destination node is in a different
      # environment.
      transfer_cluster_resources

      ### Backup-specific section
      # Create datasets
      datasets.each do |pair|
        src, dst = pair
        
        # Create datasets with canmount=noauto
        append_t(Transactions::Storage::CreateDataset, args: [
          dst,
          {canmount: 'noauto'},
          {create_private: false},
        ]) { |t| t.create(dst) }

        # Set all properties except for quotas to ensure send/recv will pass
        props = {}

        src.dataset_properties.where(inherited: false).each do |p|
          next if %w(quota refquota).include?(p.name)
          props[p.name.to_sym] = [p, p.value]
        end

        append(Transactions::Storage::SetDataset, args: [dst, props]) if props.any?
      end

      # Transfer datasets
      last_snapshot_name = nil

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

        if last_snapshot_name.nil?
          last_snapshot_name = backup_sip.snapshot.name
        elsif last_snapshot_name != backup_sip.snapshot.name
          fail 'all VPS datasets must have the same latest snapshot, unable to continue'
        end
        
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

      if last_snapshot_name.nil?
        fail 'programming error, no last snapshot name'
      end
      ### End of backup-specific section

      # Prepare userns
      use_chain(UserNamespaceMap::Use, args: [src_vps.userns_map, dst_node])

      # Authorize the migration
      append(
        Transactions::Pool::AuthorizeSendKey,
        args: [dst_pool, src_pool, vps.id, "chain-#{id}-#{token}", token],
      )

      # Copy configs
      append(
        Transactions::Vps::SendConfig,
        args: [
          src_vps,
          dst_node,
          network_interfaces: true,
          passphrase: token,

          # These options tell osctld to do only incremental sends
          from_snapshot: last_snapshot_name,
          preexisting_datasets: true,
        ],
      )

      # In case of rollback on the target node
      append(Transactions::Vps::SendRollbackConfig, args: dst_vps)

      # Handle dataset resources
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
      end
        
      # Reserve a slot in zfs_send queue
      append(Transactions::Queue::Reserve, args: [src_node, :zfs_send])

      # Incremental transfer with changes from the backed-up snapshot
      append(Transactions::Vps::SendRootfs, args: [src_vps])

      if @opts[:maintenance_window]
        # Temporarily release the reserved spot in the queue, we'll get another
        # reservation within the maintenance window
        append(Transactions::Queue::Release, args: [src_node, :zfs_send])

        # Wait for the outage window to open
        append(Transactions::MaintenanceWindow::Wait, args: [src_vps, 15])
        append(Transactions::Queue::Reserve, args: [src_node, :zfs_send])
        append(Transactions::MaintenanceWindow::InOrFail, args: [src_vps, 15])

        append(Transactions::Vps::SendSync, args: [src_vps], urgent: true)

        # Check if we're still inside the outage window. We're in if the window
        # closes in not less than 5 minutes. Fail if not.
        append(Transactions::MaintenanceWindow::InOrFail, args: [src_vps, 5], urgent: true)
      end

      # Stop the VPS
      use_chain(Vps::Stop, args: src_vps, urgent: true)

      # Send it to the target node
      append(
        Transactions::Vps::SendState,
        args: [src_vps, start: false],
        urgent: true,
      )

      ### Backup-specific step
      # Set quotas when all data is transfered, since we have not sent ZFS
      # properties from the source node
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

      dst_ip_addresses = vps.ip_addresses

      # Migration to different location - remove or replace IP addresses
      migrate_network_interfaces

      # Regenerate mount scripts of the migrated VPS
      mounts = Vps::Migrate::MountMigrator.new(self, vps, dst_vps)
      mounts.datasets = datasets
      mounts.remount_mine

      # Wait for routing to remove routes from the original system
      append(Transactions::Vps::WaitForRoutes, args: [dst_vps], urgent: true)

      # Restore VPS state
      call_hooks_for(:pre_start, self, args: [dst_vps, was_running?])
      use_chain(Vps::Start, args: dst_vps, urgent: true) if was_running?
      call_hooks_for(:post_start, self, args: [dst_vps, was_running?])

      # Release reserved spot in the queue
      append(Transactions::Queue::Release, args: [src_node, :zfs_send], urgent: true)

      # Move the dataset in pool to the new pool in the database
      append_t(Transactions::Utils::NoOp, args: dst_node.id, urgent: true) do |t|
        t.edit(src_vps, dataset_in_pool_id: datasets.first[1].id)
        t.edit(src_vps, node_id: dst_node.id)

        # Transfer resources
        resources_changes.each do |use, changes|
          t.edit(use, changes) unless changes.empty?
        end

        # Transfer datasets, snapshots and properties
        datasets.each do |src, dst|
          src.dataset_properties.all.each do |p|
            t.edit(p, dataset_in_pool_id: dst.id)
          end

          src.snapshot_in_pools.each do |sip|
            t.edit(sip, dataset_in_pool_id: dst.id)
          end

          ### Backup-specific step
          # The problem here is that the first snapshot, the one which
          # was sent from the backup, will be here twice... once created
          # by Dataset::Send and once here... we should probably delete the one
          # created by Dataset::Send
          dst.snapshot_in_pools.each do |sip|
            t.destroy(sip)
          end

          migrate_dataset_plans(src, dst, t)

          t.destroy(src)
          t.create(dst)
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

      # It is needed to register IP in fw and shaper when either staying
      # in the same location or when the addresses are just recharged to a new
      # env, but otherwise are untouched by {migrate_network_interfaces}.
      #
      # {migrate_network_interfaces} was already called, so here we don't have
      # to check if it is valid to recharge IP addresses.
      if !location_changed? || opts[:transfer_ips]
        # Register to firewall and set shaper on destination node
        use_chain(Vps::FirewallRegister, args: [dst_vps, dst_ip_addresses], urgent: true)
        use_chain(Vps::ShaperSet, args: [dst_vps, dst_ip_addresses], urgent: true)
      end

      # Destroy old VPS
      append(Transactions::Vps::SendCleanup, args: src_vps)
      append(Transactions::Vps::RemoveConfig, args: src_vps)

      # Free userns map
      use_chain(UserNamespaceMap::Disuse, args: [src_vps])

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
