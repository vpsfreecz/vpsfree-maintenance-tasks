#!/run/nodectl/nodectl script
require 'nodectld/standalone'

class Operation
  include OsCtl::Lib::Utils::Log
  include NodeCtld::Utils::System

  Dataset = Struct.new(:id, :name)
  DatasetInPool = Struct.new(:id, :dataset)
  SnapshotInPool = Struct.new(:id, :name, :dip, :snapshot_id, :pool_cnt) do
    def destroy_snapshot?
      pool_cnt == 1
    end
  end

  attr_reader :ctid, :db, :dips, :sips, :trees, :branches

  def initialize(ctid)
    @ctid = ctid
    @dips = []
    @sips = []
    @trees = []
    @branches = []
  end

  def run
    @db = NodeCtld::Db.new
    fetch_info

    puts
    STDOUT.write('Continue? [y/N]: ')
    STDOUT.flush
    return if STDIN.readline.strip != 'y'

    puts "Acquiring locks"
    acquire_locks

    puts "Replacing datasets"
    replace_datasets

    puts "Checking state"
    sleep(5)
    puts syscmd("osctl ct ls -o id,state,init_pid,nproc,memory,cpu_time #{ctid}").output
    puts
    sleep(5)
    puts syscmd("osctl ct ps #{ctid}").output
    puts
    STDOUT.write('If it looks good, continue with cleanup [y/N]: ')
    STDOUT.flush
    return if STDIN.readline.strip != 'y'

    puts "Removing snapshots"
    remove_snapshots

    puts "Detaching backups"
    detach_backups

    puts "Releasing locks"
    release_locks

    puts
    puts "Datasets of CT #{ctid} replaced"
    puts
    puts "To remove old datasets, run:"
    puts
    sips.each { |sip| puts "zfs destroy #{sip.dip.dataset.name}.old@#{sip.name}" }
    dips.reverse_each { |dip| puts "zfs destroy #{dip.dataset.name}.old" }
  end

  protected
  def fetch_info
    # Find root dataset
    ds_id = db.prepared(
      'SELECT ds.id FROM dataset_in_pools dip
       INNER JOIN datasets ds ON dip.dataset_id = ds.id
       WHERE label = ?',
      "vps#{ctid}"
    ).get!['id']

    puts "Dataset ID = #{ds_id}"

    # Find IDs of all dataset in pools
    puts "Dataset in pools:"
    db.prepared(
      'SELECT p.filesystem, ds.id AS ds_id, ds.full_name, dip.id AS dip_id
       FROM dataset_in_pools dip
       INNER JOIN datasets ds ON dip.dataset_id = ds.id
       INNER JOIN pools p ON dip.pool_id = p.id
       WHERE p.node_id = ? AND (ds.id = ? OR ds.ancestry = ? OR ds.ancestry LIKE ?)',
       $CFG.get(:vpsadmin, :node_id),
       ds_id,
       ds_id,
       "#{ds_id}/%"
    ).each do |row|
      dip = DatasetInPool.new(
        row['dip_id'],
        Dataset.new(row['ds_id'], File.join(row['filesystem'], row['full_name']))
      )
      puts "  #{dip.dataset.name} = #{dip.id}"
      dips << dip
    end

    # Find snapshots
    puts "Snapshot in pools:"
    db.prepared(
      "SELECT
         sip.dataset_in_pool_id, sip.id AS sip_id, s.id AS s_id, s.name, sip.reference_count,
         (SELECT COUNT(*) FROM snapshot_in_pools WHERE snapshot_id = s.id) AS pool_cnt
       FROM snapshot_in_pools sip
       INNER JOIN snapshots s ON sip.snapshot_id = s.id
       WHERE sip.dataset_in_pool_id IN (#{dips.map(&:id).join(',')})"
    ).each do |row|
      dip = dips.detect { |dip| dip.id == row['dataset_in_pool_id'] }
      fail "unable to find dataset_in_pool=#{row['dataset_in_pool_id']}" if dip.nil?

      sip = SnapshotInPool.new(
        row['sip_id'],
        row['name'],
        dip,
        row['s_id'],
        row['pool_cnt'],
      )
      
      if row['reference_count'] > 1
        fail "unable to fix this vps, snapshot #{sip.dip.dataset.name}@#{sip.name} "+
             "(sip=#{sip.id},s=#{sip.snapshot_id}) is mounted or cloned"
      end

      puts "  #{sip.dip.dataset.name}@#{sip.name} "+
           "(sip=#{sip.id},s=#{sip.snapshot_id},cnt=#{sip.pool_cnt},"+
           "destroy=#{sip.destroy_snapshot? ? 'all' : 'pool'})"
      sips << sip
    end

    # Find backup dataset in pools, trees and branches
    puts "Backups:"
    db.prepared(
      'SELECT dip.id AS dip_id, tr.id AS tree_id, br.id AS branch_id
       FROM dataset_in_pools dip
       INNER JOIN datasets ds ON dip.dataset_id = ds.id
       INNER JOIN pools p ON dip.pool_id = p.id
       INNER JOIN dataset_trees tr ON tr.dataset_in_pool_id = dip.id
       INNER JOIN branches br ON br.dataset_tree_id = tr.id
       WHERE
         p.role = 2
         AND (ds.id = ? OR ds.ancestry = ? OR ds.ancestry LIKE ?)
         AND tr.head = 1 AND br.head = 1',
       ds_id,
       ds_id,
       "#{ds_id}/%"
    ).each do |row|
      puts "  Tree #{row['dip_id']}/#{row['tree_id']} will be detached"
      trees << row['tree_id']

      puts "  Branch #{row['branch_id']} of tree #{row['tree_id']} will be detached"
      branches << row['branch_id']
    end
  end

  def acquire_locks
    db.transaction(restart: false) do |t|
      t.prepared(
        'INSERT INTO resource_locks (resource, row_id, created_at, locked_by_type)
         VALUES (?, ?, NOW(), ?)',
         'Vps', ctid.to_i, locked_by_type
      )

      dips.each do |dip|
        t.prepared(
          'INSERT INTO resource_locks (resource, row_id, created_at, locked_by_type)
           VALUES (?, ?, NOW(), ?)',
           'DatasetInPool', dip.id, locked_by_type
        )
      end
    end
  end

  def release_locks
    db.prepared(
      'DELETE FROM resource_locks WHERE locked_by_type = ?',
      locked_by_type
    )
  end

  def locked_by_type
    "nodectld-maint-#{ctid}"
  end

  def replace_datasets
    datasets = dips.map do |dip|
      [dip.dataset.name, "#{dip.dataset.name}.new", "#{dip.dataset.name}.old"]
    end

    # Prepare new datasets
    datasets.each do |ds, new, old|
      uidmap, gidmap, refquota = zfs(
        :get,
        '-H -p -o value uidmap,gidmap,refquota',
      ds).output.split("\n")

      zfs(
        :create,
        "-o uidmap=#{uidmap} -o gidmap=#{gidmap} -o refquota=#{refquota} -o canmount=noauto",
        new
      )
      zfs(:mount, nil, new)
    end

    # Ensure the datasets are mounted
    syscmd("osctl ct mount #{ctid}")

    # Check ct state
    running = syscmd("osctl ct ls -H -o state #{ctid}").output.strip == 'running'

    if running
      puts 'Container is running and will be restarted'
    else
      puts 'Container is stopped and will not be restarted'
    end

    # First sync
    datasets.each do |ds, new, old|
      syscmd(
        "rsync -rlptgoDHXA --numeric-ids --inplace /#{ds}/private/ /#{new}/private/",
        valid_rcs: [23, 24]
      )
    end

    # Second sync
    datasets.each do |ds, new, old|
      syscmd(
        "rsync -rlptgoDHXA --numeric-ids --inplace --delete /#{ds}/private/ /#{new}/private/",
        valid_rcs: [23, 24]
      )
    end

    # Stop the VPS
    syscmd("osctl ct stop #{ctid}")

    # Final sync
    datasets.each do |ds, new, old|
      syscmd("rsync -rlptgoDHXA --numeric-ids --inplace --delete /#{ds}/private/ /#{new}/private/")
    end

    # Switch datasets
    datasets.each do |ds, new, old|
      zfs(:rename, nil, "#{ds} #{old}")
    end
    datasets.each do |ds, new, old|
      zfs(:rename, nil, "#{new} #{ds}")
    end

    # Restart the vps
    syscmd("osctl ct start #{ctid}") if running
  end

  def remove_snapshots
    db.transaction do |t|
      sips.each do |sip|
        puts "Removing snapshot_in_pools##{sip.id}"
        t.prepared('DELETE FROM snapshot_in_pools WHERE id = ?', sip.id)

        if sip.destroy_snapshot?
          puts "Removing snapshots##{sip.snapshot_id}"
          t.prepared('DELETE FROM snapshots WHERE id = ?', sip.snapshot_id)
        end
      end
    end
  end

  def detach_backups
    db.transaction do |t|
      if branches.any?
        t.prepared("UPDATE branches SET head = 0 WHERE id in (#{branches.join(',')})")
      end

      if trees.any?
        t.prepared("UPDATE dataset_trees SET head = 0 WHERE id in (#{trees.join(',')})")
      end
    end
  end
end

unless ENV['CTID']
  warn "Set CTID"
  exit(false)
end

op = Operation.new(ENV['CTID'])
op.run
