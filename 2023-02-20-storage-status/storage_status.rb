#!/run/nodectl/nodectl script
# Compare datasets/snapshots between DB and on-disk states
#
# This script does not take any locks, so some mismatches may be due to changes
# being done while this script is running.

require 'nodectld/standalone'

include OsCtl::Lib::Utils::Log
include NodeCtld::Utils::System

class Dataset
  attr_reader :name, :ident

  def initialize(row, **opts)
    @data = row

    @name = File.join(*[
      row['filesystem'],
      row['full_name'],
      (opts[:tree] || opts[:branch]) ? "tree.#{row['tree_index']}" : nil,
      opts[:branch] && "branch-#{row['branch_name']}.#{row['branch_index']}"
    ].compact)
    
    if opts[:snapshot]
      @name = "#{@name}@#{row['snapshot_name']}"
    end

    @ident = make_ident(row, **opts)
  end

  def to_s
    name
  end

  protected
  def make_ident(row, **opts)
    ret = []

    ret << "id=#{row['dataset_id']}"
    ret << "dip=#{row['dataset_in_pool_id']}"
    ret << "tree=#{row['tree_id']}" if opts[:tree] || opts[:branch]
    ret << "branch=#{row['branch_id']}" if opts[:branch]
    ret << "snap=#{row['snapshot_id']}" if opts[:snapshot]

    if opts[:snapshot]
      ret << "sip=#{row['snapshot_in_pool_id']}" if row['snapshot_in_pool_id']
      ret << "sipb=#{row['snapshot_in_pool_in_branch_id']}" if row['snapshot_in_pool_in_branch_id']
    end

    ret.join(' ')
  end
end

pools = []
db_datasets = {}
ondisk_datasets = {}

db = NodeCtld::Db.new

db.prepared(
  'SELECT filesystem FROM pools WHERE node_id = ?',
  $CFG.get(:vpsadmin, :node_id),
).each do |row|
  pools << row['filesystem']
end

# TODO: this is wrong for backups... we must capture snapshots *through* sipbs...
# this way it's like they're in all branches
db.prepared(
  'SELECT
    p.filesystem,
    ds.id AS dataset_id, ds.full_name,
    dips.id AS dataset_in_pool_id,
    s.id AS snapshot_id, s.name AS snapshot_name,
    sips.id AS snapshot_in_pool_id,
    sipbs.id AS snapshot_in_pool_in_branch_id,
    t.id AS tree_id, t.index AS tree_index,
    b.id AS branch_id, b.name AS branch_name, b.index AS branch_index
  FROM datasets ds
  INNER JOIN dataset_in_pools dips ON ds.id = dips.dataset_id
  INNER JOIN pools p ON p.id = dips.pool_id
  LEFT JOIN snapshot_in_pools sips ON sips.dataset_in_pool_id = dips.id
  LEFT JOIN snapshots s ON s.id = sips.snapshot_id
  LEFT JOIN snapshot_in_pool_in_branches sipbs ON sipbs.snapshot_in_pool_id = sips.id
  LEFT JOIN dataset_trees t ON t.dataset_in_pool_id = dips.id
  LEFT JOIN branches b ON b.dataset_tree_id = t.id
  WHERE
    p.node_id = ?
    AND
    (sipbs.id IS NULL OR sipbs.branch_id = b.id)
    AND
    ds.confirmed = 1
    AND
    dips.confirmed = 1
    AND
    (sips.confirmed IS NULL or sips.confirmed = 1)
    AND
    (s.confirmed IS NULL or s.confirmed = 1)
    AND
    (sipbs.confirmed IS NULL or sipbs.confirmed = 1)
    AND
    (t.confirmed IS NULL or t.confirmed = 1)
    AND
    (b.confirmed IS NULL or b.confirmed = 1)
  ',
  $CFG.get(:vpsadmin, :node_id),
).each do |row|
  [
    Dataset.new(row),
    row['tree_index'] && Dataset.new(row, tree: true),
    row['branch_index'] && Dataset.new(row, branch: true),
    row['snapshot_name'] && Dataset.new(row, snapshot: true, branch: row['branch_index']),
  ].compact.each do |ds|
    db_datasets[ds.name] = ds
  end
end

zfs(:list, '-r -t all -o name -H', pools.join(' ')).output.strip.split[1..-1].each do |name|
  ondisk_datasets[name.strip] = true
end

db_datasets.delete_if do |name, _|
  ondisk_datasets.delete(name)
end

ondisk_datasets.delete_if do |name, _|
  db_datasets.delete(name)
end

if db_datasets.any?
  puts "Missing on-disk datasets:"
  
  db_datasets.sort do |a, b|
    a[1].name <=> b[1].name
  end.each do |_, ds|
    puts "#{ds} (#{ds.ident})"
  end

  puts
  puts
  puts
end

if ondisk_datasets.any?
  puts "Unknown datasets:"
  
  ondisk_datasets.sort do |a, b|
    a[0] <=> b[0]
  end.each do |name, _|
    puts "#{name}"
  end

  puts
  puts
  puts
end
