#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Migrate datasets between pools while taking number of VPS with mounts
# into account.

require 'vpsadmin'

SRC_POOL_ID = 15
DST_POOL_ID = 42
LIMIT = 50
MAX_VPS_WITH_MOUNTS = 1

REASONS = {
  'cs' => 'Přesun na novější diskové pole.',
  'en' => 'Transfer to a newer storage pool.'
}

MULTIPLE_VPS = {
  'cs' => <<~END,
    Po přesunu bude nutné NFS mounty ve VPS odpojit a znovu připojit, jinak to při
    přístupu k datům bude vracet chybu "Stale file handle" z důvodu nevyhnutelné
    změny fsid v NFS.
  END
  'en' => <<~END,
    After the transfer, it will be necessary to remount NFS mounts inside VPS.
    Otherwise, accessing the mountpoints will result in "Stale file handle" error
    due to unavoidable change of fsid in NFS.
  END
}

RSYNC_DATASETS = %w[]

dst_pool = ::Pool.find(DST_POOL_ID)
env_prod = ::Environment.find_by!(label: 'Production')
counter = 0

::Dataset.roots.joins(:dataset_in_pools).where(dataset_in_pools: { pool_id: SRC_POOL_ID }).each do |ds|
  break if counter >= LIMIT

  puts "Dataset #{ds.full_name}"

  dip = ds.primary_dataset_in_pool!

  if ::ResourceLock.where(resource: 'DatasetInPool', row_id: dip.id).any?
    puts '  locked'
    puts
    next
  end

  puts "  user #{ds.user.login}"

  exports = []

  ds.subtree.each do |sub_ds|
    sub_dip = sub_ds.primary_dataset_in_pool!

    exports.concat(sub_dip.exports.to_a)
  end

  puts "  #{exports.length} exports"

  exports.each do |export|
    puts "    #{export.host_ip_address.ip_addr}:#{export.path}"
  end

  export_mounts = exports.map { |export| export.export_mounts.to_a }.flatten
  vps_count = export_mounts.map(&:vps_id).uniq.length

  puts "  #{vps_count} VPS with mounts"

  export_mounts.each do |ex_mnt|
    puts "    #{ex_mnt.vps_id} #{ex_mnt.mountpoint}"
  end

  if vps_count > MAX_VPS_WITH_MOUNTS
    puts '  too many mounts, skipping'
    puts
    next
  end

  # First get a VPS with existing mount
  vps = export_mounts.first&.vps

  # Otherwise, find a production VPS
  vps ||= ::Vps
    .joins(node: :location)
    .where(
      user: ds.user,
      locations: { environment_id: env_prod.id },
      object_state: ::Vps.object_states[:active]
    ).take

  # As a last resort, pick any VPS
  vps ||= ::Vps.find_by(user: ds.user)

  if vps
    puts "  using VPS #{vps.id} #{vps.hostname}"
  else
    puts '  no VPS found'
  end

  rsync = RSYNC_DATASETS.include?(ds.full_name)

  if rsync
    puts '  using rsync'
  else
    puts '  using send/recv'
  end

  restart_vps = true
  reason = REASONS.fetch(ds.user.language.code).dup

  if vps_count > 1
    restart_vps = false
    reason << "\n\n" << MULTIPLE_VPS.fetch(ds.user.language.code)
  end

  if restart_vps
    puts '  would restart VPS'
  else
    puts '  no VPS restart'
  end

  STDOUT.write('Continue? [y/N]:')

  if STDIN.readline.strip.downcase != 'y'
    puts
    next
  end

  begin
    chain, = TransactionChains::Dataset::Migrate.fire2(
      args: [dip, dst_pool],
      kwargs: {
        rsync:,
        restart_vps:,
        maintenance_window_vps: vps,
        optional_maintenance_window: true,
        cleanup_data: false,
        send_mail: true,
        reason:
      }
    )

    puts "  chain #{chain.id} started"
    # puts "  would migrate dataset"
  rescue ::ResourceLocked => e
    puts "  resource locked (#{e.message})"
    puts
    next
  end

  counter += 1
  puts
end
