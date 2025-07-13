#!/run/nodectl/nodectl script
# Delete snapshots that exist in database, but are not present on disk.

require 'nodectld/standalone'

include OsCtl::Lib::Utils::Log
include NodeCtld::Utils::System

puts 'Reading all on-disk snapshots...'
ondisk_snapshots = `zfs list -r -t snapshot -H -o name`.strip.split("\n")

db = NodeCtld::Db.new

nonexistent = []

puts 'Fetching snapshots from db...'
db.prepared(
  "SELECT p.role, p.filesystem, ds.full_name, s.name AS snapshot_name,
          b.name AS branch_name, b.index AS branch_index, tr.index AS tree_index,
          s.id AS snapshot_id, sips.id AS snapshot_in_pool_id, sipbs.id AS snapshot_in_pool_in_branch_id
  FROM pools p
  INNER JOIN dataset_in_pools dips ON dips.pool_id = p.id
  INNER JOIN datasets ds ON ds.id = dips.dataset_id
  INNER JOIN snapshot_in_pools sips ON sips.dataset_in_pool_id = dips.id
  INNER JOIN snapshots s ON s.id = sips.snapshot_id
  LEFT JOIN snapshot_in_pool_in_branches sipbs ON sipbs.snapshot_in_pool_id = sips.id
  LEFT JOIN branches b ON b.id = sipbs.branch_id
  LEFT JOIN dataset_trees tr ON tr.id = b.dataset_tree_id
  WHERE p.node_id = ?",
  $CFG.get(:vpsadmin, :node_id)
).each do |row|
  ondisk_name =
    if row['role'] == 2
      "#{row['filesystem']}/#{row['full_name']}/tree.#{row['tree_index']}/branch-#{row['branch_name']}.#{row['branch_index']}@#{row['snapshot_name']}"
    else
      "#{row['filesystem']}/#{row['full_name']}@#{row['snapshot_name']}"
    end

  next if ondisk_snapshots.include?(ondisk_name)

  row['ondisk_name'] = ondisk_name
  nonexistent << row
end

if nonexistent.empty?
  puts 'All snapshots from the database exist on disk'
  exit
end

puts
puts
puts "The following snapshots do not exist on disk:"

nonexistent.each do |row|
  sips = db.prepared('SELECT id FROM snapshot_in_pools WHERE snapshot_id = ?', row['snapshot_id'])

  puts "#{row['ondisk_name']} (#{sips.count} snapshot in pools)"
end

STDOUT.write('Remove snapshots from db? [y/N] ')
raise 'abort' if STDIN.readline.strip != 'y'

nonexistent.each do |row|
  puts "Deleting #{row['ondisk_name']}"

  if row['role'] == 2
    puts "  snapshot in pool in branch id = #{row['snapshot_in_pool_in_branch_id']}"
    db.prepared('DELETE FROM snapshot_in_pool_in_branches WHERE id = ?', row['snapshot_in_pool_in_branch_id'])
  end

  puts "  snapshot in pool id = #{row['snapshot_in_pool_id']}"
  db.prepared('DELETE FROM snapshot_in_pools WHERE id = ?', row['snapshot_in_pool_id'])

  other_sips = db.prepared('SELECT id FROM snapshot_in_pools WHERE snapshot_id = ?', row['snapshot_id'])

  if other_sips.count == 0
    puts "  snapshot id = #{row['snapshot_id']}"
    db.prepared('DELETE FROM snapshots WHERE id = ?', row['snapshot_id'])
  end

  puts
  puts 'hit enter'
  STDIN.readline
end
