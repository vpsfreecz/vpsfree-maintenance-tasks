#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Repair missing backup branch clone dependency metadata.
#
# Usage:
#   ./fix_backup_branch_dependencies.rb [--apply] [--dataset DATASET_NAME]
#
# Dry-run is the default. Use --apply to update rows after reviewing output.

require 'optparse'
require 'set'
require 'vpsadmin'

POOL_FS = 'storage/vpsfree.cz/backup'
POOL_NODE = 'backuper2.prg'

EDGES = [
  {
    dataset: '29494',
    tree: 1,
    parent_branch: '2026-06-02T23:00:32',
    parent_snapshot: '2026-06-02T23:00:32',
    child_branch: '2026-05-19T02:28:40'
  },
  {
    dataset: '28821',
    tree: 2,
    parent_branch: '2026-06-02T23:00:21',
    parent_snapshot: '2026-06-02T23:00:21',
    child_branch: '2026-06-04T23:00:21'
  },
  {
    dataset: '28915',
    tree: 2,
    parent_branch: '2026-06-02T23:00:01',
    parent_snapshot: '2026-06-02T23:00:01',
    child_branch: '2026-06-16T23:00:01'
  },
  {
    dataset: '28915',
    tree: 2,
    parent_branch: '2026-06-16T23:00:01',
    parent_snapshot: '2026-06-16T23:00:01',
    child_branch: '2026-05-20T13:13:45'
  }
].freeze

options = {
  apply: false,
  dataset: nil
}

OptionParser.new do |opts|
  opts.banner = "Usage: #{$PROGRAM_NAME} [--apply] [--dataset DATASET_NAME]"

  opts.on('--apply', 'Update database rows') do
    options[:apply] = true
  end

  opts.on('--dataset DATASET_NAME', 'Limit to one dataset full_name') do |v|
    options[:dataset] = v
  end
end.parse!

def live_sipb_scope
  ::SnapshotInPoolInBranch.live
end

def branch_full_name(branch)
  "branch-#{branch.name}.#{branch.index}"
end

def tree_full_name(tree)
  "tree.#{tree.index}"
end

def find_edge!(pool, edge)
  dataset = ::Dataset.find_by!(full_name: edge.fetch(:dataset))
  dip = ::DatasetInPool.find_by!(dataset:, pool:)
  tree = dip.dataset_trees.find_by!(index: edge.fetch(:tree))
  parent_branch = tree.branches.find_by!(
    name: edge.fetch(:parent_branch),
    index: edge.fetch(:parent_index, 0)
  )
  child_branch = tree.branches.find_by!(
    name: edge.fetch(:child_branch),
    index: edge.fetch(:child_index, 0)
  )

  parent_entry = live_sipb_scope
                 .joins(snapshot_in_pool: :snapshot)
                 .find_by!(
                   branch: parent_branch,
                   snapshots: { name: edge.fetch(:parent_snapshot) }
                 )

  {
    dataset:,
    dip:,
    tree:,
    parent_branch:,
    child_branch:,
    parent_entry:
  }
end

def child_entries(branch)
  live_sipb_scope
    .joins(snapshot_in_pool: :snapshot)
    .where(branch:)
    .order('snapshots.id')
end

def reference_count_for(snapshot_in_pool)
  parent_entry_ids = ::SnapshotInPoolInBranch.where(
    snapshot_in_pool_id: snapshot_in_pool.id
  ).select(:id)

  branch_refs = live_sipb_scope
                .where(snapshot_in_pool_in_branch_id: parent_entry_ids)
                .count
  clone_refs = ::SnapshotInPoolClone
               .where(snapshot_in_pool:)
               .where.not(confirmed: ::SnapshotInPoolClone.confirmed(:confirm_destroy))
               .count

  branch_refs + clone_refs
end

def find_pool!
  matches = ::Pool.includes(node: :location).where(filesystem: POOL_FS).to_a
  exact = matches.select { |pool| pool.node.domain_name == POOL_NODE }

  if exact.empty?
    found = matches.map { |pool| "#{pool.id}:#{pool.node.domain_name}" }
    found = ['none'] if found.empty?

    fail "#{POOL_FS} on #{POOL_NODE} not found; matching pools: #{found.join(', ')}"
  elsif exact.length > 1
    fail "#{POOL_FS} on #{POOL_NODE} is ambiguous: #{exact.map(&:id).join(', ')}"
  end

  exact.first
end

pool = find_pool!

edges = EDGES
edges = edges.select { |edge| edge.fetch(:dataset) == options[:dataset] } if options[:dataset]

fail "No edges selected for dataset #{options[:dataset]}" if edges.empty?

puts "#{options[:apply] ? 'Apply' : 'Dry-run'} mode"
puts "Pool: #{pool.node.domain_name}:#{pool.filesystem}"
puts

touched_sip_ids = Set.new
updates = []

ActiveRecord::Base.transaction do
  edges.each do |edge|
    data = find_edge!(pool, edge)
    dip = data.fetch(:dip)
    parent_entry = data.fetch(:parent_entry)
    parent_sip = parent_entry.snapshot_in_pool
    entries = child_entries(data.fetch(:child_branch)).to_a

    locks = ::ResourceLock.where(resource: 'DatasetInPool', row_id: dip.id)

    if locks.any?
      fail "DatasetInPool #{dip.id} is locked by #{locks.map(&:locked_by_id).join(', ')}"
    end

    puts "Dataset #{data.fetch(:dataset).full_name}"
    puts "  #{tree_full_name(data.fetch(:tree))}"
    puts "  parent " \
         "#{branch_full_name(data.fetch(:parent_branch))}@#{edge.fetch(:parent_snapshot)} " \
         "(sipb=#{parent_entry.id}, sip=#{parent_sip.id})"
    puts "  child  #{branch_full_name(data.fetch(:child_branch))} (#{entries.length} snapshots)"

    touched_sip_ids << parent_sip.id

    entries.each do |entry|
      old_parent = entry.snapshot_in_pool_in_branch

      next if old_parent&.id == parent_entry.id

      touched_sip_ids << old_parent.snapshot_in_pool_id if old_parent

      snapshot_name = entry.snapshot_in_pool.snapshot.name
      old_desc = old_parent ? "sipb=#{old_parent.id}" : 'none'
      puts "    @#{snapshot_name}: parent #{old_desc} -> sipb=#{parent_entry.id}"

      updates << [entry.id, old_parent&.id, parent_entry.id]
      entry.update!(snapshot_in_pool_in_branch: parent_entry) if options[:apply]
    end

    puts
  end

  puts "#{updates.length} branch entries to update"
  puts

  touched_sip_ids.each do |sip_id|
    sip = ::SnapshotInPool.find(sip_id)
    expected = reference_count_for(sip)
    next if sip.reference_count == expected

    puts "SnapshotInPool #{sip.id} reference_count #{sip.reference_count} -> #{expected}"
    sip.update!(reference_count: expected) if options[:apply]
  end

  unless options[:apply]
    puts
    puts 'Dry-run only; no rows changed.'
    raise ActiveRecord::Rollback
  end
end

puts
puts 'Done'
