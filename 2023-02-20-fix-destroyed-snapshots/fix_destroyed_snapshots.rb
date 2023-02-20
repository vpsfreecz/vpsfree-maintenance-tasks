#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Fix a disconnect of DB from on-disk state, where we have three snapshots
# on the hypervisor in DB, but the oldest snapshot doesn't exist on-disk. Since
# it's not backed up, we must delete it from DB and detach backup heads.
#
# Usage: $0 <file with dataset ids per line>
#

require 'vpsadmin'

# Override unfortunate methods
class Snapshot
  def destroy
    super
  end
end

if ARGV.length < 2
  fail "Usage: #{$0} <file with dataset ids> [execute]"
end

dataset_ids = File.read(ARGV[0]).strip.split.map(&:to_i)
execute = ARGV[1] == 'execute'

dataset_ids.each do |ds_id|
  ActiveRecord::Base.transaction do
    ds = ::Dataset.find(ds_id)

    puts "Dataset id=#{ds.id} name=#{ds.full_name}"

    dip_hv = ds.primary_dataset_in_pool!
    puts "  #{dip_hv.pool.node.domain_name}: #{ds.full_name}"

    dip_backup = ds.dataset_in_pools.joins(:pool).where(pools: {role: Pool.roles[:backup]}).take!
    puts "  #{dip_backup.pool.node.domain_name}: #{ds.full_name}"

    sips_hv = dip_hv.snapshot_in_pools.order(:id).to_a
    sips_hv.each do |sip|
      puts "  hv @#{sip.snapshot.name}"
    end

    if sips_hv.length != 3
      fail "#{ds.full_name} does not have 3 snapshots on hypervisor"
    end

    if dip_backup.snapshot_in_pools.where(snapshot_id: sips_hv.first.snapshot_id).empty?
      fail "#{ds.full_name}@#{sip.snapshot.name} is not in backup"
    end

    sips_backup = dip_backup.snapshot_in_pools.order(:id).to_a

    if sips_backup.last.snapshot_id == sips_hv.last.snapshot_id
      puts "  leaving backups"
    else
      sip_backup = sips_backup.first
      puts "  backup @#{sip_backup.snapshot.name}"

      # Delete the oldest snapshot
      puts "  destroy hv #{sips_hv.first.snapshot.name}"
      sips_hv.first.destroy! if execute

      puts "  destroy backup #{sip_backup.snapshot.name}"

      sip_backup.snapshot_in_pool_in_branches.each do |sipb|
        puts "  destroy sipb #{sipb.id}"
        sipb.destroy! if execute
      end

      sip_backup.destroy! if execute
      sip_backup.snapshot.destroy! if execute

      # Detach backup heads
      dip_backup.dataset_trees.where(head: true).each do |tree|
        puts "  tree=#{tree.id} detach"
        tree.update!(head: false) if execute

        tree.branches.where(head: true).each do |b|
          puts "    branch=#{b.id} detach"
          b.update!(head: false) if execute
        end
      end
    end

    puts
    puts
  end
end
