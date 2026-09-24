#!/usr/bin/env ruby
require 'optparse'
require_relative 'inventory'

module StorageInventory
  class Comparator
    attr_reader :findings

    def initialize(db, zfs)
      @db, @zfs = db, zfs
      @findings = []
      @expected = Hash.new { |h, k| h[k] = [] }
      @sources = {}
    end

    def run
      pools = rows('pool')
      roots = pools.map { |p| p.fetch('filesystem') }.sort
      raise ArgumentError, 'capture roots differ from DB backup pool filesystems' unless
        roots.uniq == roots && roots == @zfs.header.fetch('scope').fetch('roots')
      raise ArgumentError, 'DB capture has no backup pools' if pools.empty?
      nodes = rows('node')
      raise ArgumentError, 'DB node identity missing or ambiguous' unless nodes.length == 1 &&
        nodes.first['id'] == @db.header.fetch('scope').fetch('node_id') &&
        pools.all? { |p| p['node_id'] == nodes.first['id'] }
      host = @zfs.header.fetch('host').downcase.delete_suffix('.')
      accepted_hosts = %w[location_domain fqdn].map { |key| nodes.first.fetch(key).downcase.delete_suffix('.') }
      raise ArgumentError, 'ZFS capture host does not match DB node' unless accepted_hosts.include?(host)

      index = %w[dataset dataset_in_pool tree branch snapshot snapshot_in_pool
                 snapshot_in_branch clone].to_h do |type|
        [type, rows(type).to_h { |r| [r.fetch('id'), r] }]
      end
      index.each do |type, by_id|
        finding('duplicate_db_id', type: type) if by_id.size != rows(type).size
      end
      sipb_by_sip = index['snapshot_in_branch'].values.group_by { |r| r['snapshot_in_pool_id'] }
      pools.each { |p| expect_path(p.fetch('filesystem'), 'pool', p['id']) }
      index['dataset'].each_value { |row| unconfirmed('dataset', row) }
      index['dataset_in_pool'].each_value do |dip|
        unconfirmed('dataset_in_pool', dip)
        ds = index['dataset'][dip['dataset_id']]
        pool = pools.find { |p| p['id'] == dip['pool_id'] }
        unless ds && pool
          finding('broken_db_link', type: 'dataset_in_pool', id: dip['id'])
          next
        end
        path = "#{pool['filesystem']}/#{ds['full_name']}"
        expect_path(path, 'dataset_in_pool', dip['id'])
      end
      index['tree'].each_value do |tree|
        dip = index['dataset_in_pool'][tree['dataset_in_pool_id']]
        path = dip && path_for_dip(dip, index, pools)
        path ? expect_path("#{path}/tree.#{tree['index']}", 'tree', tree['id']) :
          finding('broken_db_link', type: 'tree', id: tree['id'])
        unconfirmed('tree', tree)
      end
      index['branch'].each_value do |branch|
        path = path_for_branch(branch, index, pools)
        path ? expect_path(path, 'branch', branch['id']) :
          finding('broken_db_link', type: 'branch', id: branch['id'])
        unconfirmed('branch', branch)
      end
      index['snapshot'].each_value { |row| unconfirmed('snapshot', row) }
      index['snapshot_in_pool'].each_value do |sip|
        dip = index['dataset_in_pool'][sip['dataset_in_pool_id']]
        snap = index['snapshot'][sip['snapshot_id']]
        finding('broken_db_link', type: 'snapshot_in_pool', id: sip['id']) unless
          dip && snap && snap['dataset_id'] == dip['dataset_id']
        finding('invalid_reference_count', id: sip['id'], count: sip['reference_count']) if
          sip['reference_count'].to_i.negative?
        finding('unlinked_backup_snapshot', id: sip['id']) unless sipb_by_sip.key?(sip['id'])
        unconfirmed('snapshot_in_pool', sip)
      end
      index['snapshot_in_branch'].each_value do |sipb|
        unconfirmed('snapshot_in_branch', sipb)
        sip = index['snapshot_in_pool'][sipb['snapshot_in_pool_id']]
        branch = index['branch'][sipb['branch_id']]
        snap = sip && index['snapshot'][sip['snapshot_id']]
        tree = branch && index['tree'][branch['dataset_tree_id']]
        unless sip && branch && snap && tree && tree['dataset_in_pool_id'] == sip['dataset_in_pool_id']
          finding('broken_db_link', type: 'snapshot_in_branch', id: sipb['id'])
          next
        end
        base = path_for_branch(branch, index, pools)
        expect_path("#{base}@#{snap['name']}", 'snapshot_in_branch', sipb['id']) if base
        parent = sipb['snapshot_in_pool_in_branch_id']
        # The parent may belong to a pool outside this node-scoped capture.
        finding('unresolved_snapshot_parent', id: sipb['id'], parent_id: parent,
                reason: 'absent_from_node_capture') if
          parent && !index['snapshot_in_branch'].key?(parent)
      end
      build_branch_origin_evidence(index, pools)
      check_reference_counts(index)
      index['clone'].each_value do |clone|
        unconfirmed('clone', clone)
        sip = index['snapshot_in_pool'][clone['snapshot_in_pool_id']]
        dip = sip && index['dataset_in_pool'][sip['dataset_in_pool_id']]
        pool = dip && pools.find { |p| p['id'] == dip['pool_id'] }
        unless pool
          finding('broken_db_link', type: 'clone', id: clone['id'])
          next
        end
        clone_path = "#{pool['filesystem']}/vpsadmin/mount/#{clone['name']}"
        expect_path(clone_path, 'clone', clone['id'])
        sources = sipb_by_sip.fetch(sip['id'], [])
        if sources.length == 1
          branch = index['branch'][sources.first['branch_id']]
          snap = index['snapshot'][sip['snapshot_id']]
          base = branch && path_for_branch(branch, index, pools)
          @sources[clone_path] = "#{base}@#{snap['name']}" if base && snap
        else
          finding('ambiguous_clone_source', id: clone['id'], source_count: sources.length)
        end
      end
      check_heads(index)
      rows('resource_lock').each do |r|
        finding('resource_lock', id: r['id'], resource: r['resource'], row_id: r['row_id'])
      end
      rows('maintenance_lock').each do |r|
        finding('maintenance_lock', id: r['id'], class_name: r['class_name'],
                row_id: r['row_id']) if r['active'] == 1
      end
      pools.each do |p|
        finding('pool_maintenance_lock', id: p['id']) if p['maintenance_lock'].to_i != 0
      end
      compare_zfs
      if @zfs.trailer['volatile']
        finding('scan_volatility', changed_object_count: rows('scan_change').length)
        rows('scan_change').each { |r| finding('volatile_zfs_object', name: r['name']) }
      end
      @findings
    end

    private

    def rows(type)
      (@db.records[type] || []) + (@zfs.records[type] || [])
    end

    def finding(code, details = {})
      raise ArgumentError, 'finding limit exceeded' if @findings.length >= MAX_RECORDS
      @findings << { 'code' => code, 'details' => details }
    end

    def unconfirmed(type, row)
      finding('unconfirmed_db_row', type: type, id: row['id'], confirmed: row['confirmed']) if row['confirmed'] != 1
    end

    def expect_path(path, type, id)
      @expected[path] << { 'type' => type, 'id' => id }
    end

    def path_for_dip(dip, index, pools)
      ds = index['dataset'][dip['dataset_id']]
      pool = pools.find { |p| p['id'] == dip['pool_id'] }
      "#{pool['filesystem']}/#{ds['full_name']}" if ds && pool
    end

    def path_for_branch(branch, index, pools)
      tree = branch && index['tree'][branch['dataset_tree_id']]
      dip = tree && index['dataset_in_pool'][tree['dataset_in_pool_id']]
      base = dip && path_for_dip(dip, index, pools)
      "#{base}/tree.#{tree['index']}/branch-#{branch['name']}.#{branch['index']}" if base
    end

    def check_heads(index)
      trees_by_dip = index['tree'].values.group_by { |r| r['dataset_in_pool_id'] }
      branches_by_tree = index['branch'].values.group_by { |r| r['dataset_tree_id'] }
      entries_by_branch = index['snapshot_in_branch'].values.group_by { |r| r['branch_id'] }
      index['dataset_in_pool'].each_value do |dip|
        trees = trees_by_dip.fetch(dip['id'], [])
        head_count = trees.count { |r| r['head'] == 1 }
        if head_count.zero?
          branches = trees.flat_map { |tree| branches_by_tree.fetch(tree['id'], []) }
          entry_count = branches.sum { |branch| entries_by_branch.fetch(branch['id'], []).length }
          finding('headless_backup_dataset_in_pool', id: dip['id'], tree_count: trees.length,
                  branch_count: branches.length, snapshot_entry_count: entry_count)
        elsif head_count > 1
          finding('tree_head_count', id: dip['id'], count: head_count, expected: 1)
        end
      end
      index['tree'].each_value do |tree|
        branches = branches_by_tree.fetch(tree['id'], [])
        head_count = branches.count { |r| r['head'] == 1 }
        if tree['head'] == 1
          finding('branch_head_count', id: tree['id'], count: head_count, expected: 1) if head_count != 1
        elsif head_count.positive?
          finding('nonhead_tree_branch_head', id: tree['id'], head_branch_count: head_count)
        end
      end
    end

    def build_branch_origin_evidence(index, pools)
      @branch_paths = {}
      @branch_origins = {}
      @pointer_free_branch_paths = {}
      entries_by_branch = index['snapshot_in_branch'].values.group_by { |r| r['branch_id'] }
      index['branch'].each_value do |branch|
        branch_path = path_for_branch(branch, index, pools)
        next unless branch_path
        @branch_paths[branch_path] = branch['id']
        parent_ids = entries_by_branch.fetch(branch['id'], [])
                                      .filter_map { |entry| entry['snapshot_in_pool_in_branch_id'] }.uniq
        if parent_ids.empty?
          @pointer_free_branch_paths[branch_path] = true
          next
        end

        candidates = []
        unresolved = false
        parent_ids.each do |parent_id|
          parent = index['snapshot_in_branch'][parent_id]
          parent_branch = parent && index['branch'][parent['branch_id']]
          parent_sip = parent && index['snapshot_in_pool'][parent['snapshot_in_pool_id']]
          parent_snapshot = parent_sip && index['snapshot'][parent_sip['snapshot_id']]
          base = parent_branch && path_for_branch(parent_branch, index, pools)
          if !base || !parent_snapshot || parent_branch['id'] == branch['id']
            unresolved = true
          else
            candidates << "#{base}@#{parent_snapshot['name']}"
          end
        end
        if unresolved || candidates.uniq.length != 1
          finding('indeterminate_branch_origin', branch: branch_path,
                  parent_entry_ids: parent_ids, candidates: candidates.uniq.sort)
        else
          @branch_origins[branch_path] = candidates.first
        end
      end
    end

    def check_reference_counts(index)
      dependent_entries = Hash.new { |hash, key| hash[key] = { confirmed: 0, pending: 0 } }
      index['snapshot_in_branch'].each_value do |entry|
        parent = index['snapshot_in_branch'][entry['snapshot_in_pool_in_branch_id']]
        next unless parent
        counts = dependent_entries[parent['snapshot_in_pool_id']]
        state = entry['confirmed'] == 1 && parent['confirmed'] == 1 ? :confirmed : :pending
        counts[state] += 1
      end
      clone_counts = index['clone'].values.group_by { |r| r['snapshot_in_pool_id'] }
      index['snapshot_in_pool'].each_value do |sip|
        entries = dependent_entries[sip['id']]
        clones = clone_counts.fetch(sip['id'], [])
        confirmed_clones = clones.count { |clone| clone['confirmed'] == 1 }
        pending_clones = clones.length - confirmed_clones
        # Pending rows may precede their counter updates. Other pools are absent.
        minimum = entries[:confirmed] + confirmed_clones
        stored = sip['reference_count']
        details = {
          id: sip['id'], stored: stored,
          confirmed_scoped_dependent_entries: entries[:confirmed],
          confirmed_scoped_clone_rows: confirmed_clones,
          pending_dependent_entries: entries[:pending], pending_clone_rows: pending_clones,
          scoped_minimum: minimum
        }
        finding('reference_count_pending_references', details) if
          entries[:pending].positive? || pending_clones.positive?
        next if stored == minimum
        code = stored < minimum ? 'reference_count_below_scoped_minimum' :
                                  'reference_count_above_scoped_minimum'
        finding(code, details)
      end
    end

    def compare_zfs
      objects = rows('zfs_object').to_h { |r| [r.fetch('name'), r] }
      finding('duplicate_zfs_path') if objects.length != rows('zfs_object').length
      @expected.each do |path, refs|
        finding('duplicate_db_path', path: path, refs: refs) if refs.length > 1
        finding('missing_zfs_object', path: path, refs: refs) unless objects.key?(path)
        next unless objects.key?(path)
        expected_type = refs.any? { |ref| ref['type'] == 'snapshot_in_branch' } ? 'snapshot' : 'filesystem'
        finding('zfs_type_mismatch', path: path, expected: expected_type,
                actual: objects[path]['type']) unless objects[path]['type'] == expected_type
      end
      @branch_origins.each do |branch_path, source|
        branch = objects[branch_path]
        finding('db_zfs_branch_origin_mismatch', branch: branch_path,
                expected: source, actual: branch['origin']) if branch && branch['origin'] != source
        snapshot = objects[source]
        next unless snapshot
        clones = snapshot['clones'] == '-' ? [] : snapshot['clones'].to_s.split(',')
        finding('db_zfs_clone_edge_missing', snapshot: source, branch: branch_path) unless clones.include?(branch_path)
      end
      @pointer_free_branch_paths.each_key do |branch_path|
        branch = objects[branch_path]
        finding('unrepresented_branch_origin', branch: branch_path, origin: branch['origin']) if
          branch && branch['origin']
      end
      objects.each do |path, obj|
        finding('untracked_zfs_object', path: path, guid: obj['guid']) unless @expected.key?(path)
        finding('external_or_unscanned_origin', path: path, origin: obj['origin']) if
          obj['origin'] && !objects.key?(obj['origin'])
        finding('origin_mismatch', path: path, expected: @sources[path], actual: obj['origin']) if
          @sources.key?(path) && @sources[path] != obj['origin']
        if obj['type'] == 'snapshot'
          finding('zfs_hold_or_deferred', path: path, userrefs: obj['userrefs'],
                  defer_destroy: obj['defer_destroy']) if
            obj['userrefs'].to_i.positive? || obj['defer_destroy'] == 'on'
          clones = obj['clones'] == '-' ? [] : obj['clones'].split(',')
          clones.each do |clone|
            finding('unrepresented_branch_clone', snapshot: path, branch: clone) if
              @pointer_free_branch_paths.key?(clone)
            if objects[clone]
              finding('clone_edge_mismatch', snapshot: path, clone: clone) unless objects[clone]['origin'] == path
            else
              finding('external_or_unscanned_clone', snapshot: path, clone: clone)
            end
          end
        elsif obj['origin'] && objects[obj['origin']]
          clones = objects[obj['origin']]['clones']
          finding('clone_edge_mismatch', snapshot: obj['origin'], clone: path) unless
            clones && clones.split(',').include?(path)
        end
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  OptionParser.new do |o|
    o.banner = 'Usage: compare.rb --db db.jsonl --zfs zfs.jsonl --output report.jsonl'
    o.on('--db PATH') { |v| options[:db] = v }
    o.on('--zfs PATH') { |v| options[:zfs] = v }
    o.on('--output PATH') { |v| options[:output] = v }
  end.parse!
  raise ArgumentError, 'unexpected arguments' unless ARGV.empty?
  raise ArgumentError, '--db, --zfs and --output required' unless %i[db zfs output].all? { |key| options[key] }
  db = StorageInventory::Reader.new(options[:db], 'db')
  zfs = StorageInventory::Reader.new(options[:zfs], 'zfs')
  writer = StorageInventory::Writer.new(options[:output],
    'kind' => 'report', 'started_at' => StorageInventory.now,
    'scope' => db.header.fetch('scope'),
    'db_window' => [db.header['started_at'], db.trailer['finished_at']],
    'zfs_window' => [zfs.header['started_at'], zfs.trailer['finished_at']],
    'zfs_volatile' => zfs.trailer['volatile'])
  begin
    findings = StorageInventory::Comparator.new(db, zfs).run
    findings.each { |row| writer.add('finding', row) }
    writer.finish('finding_counts' => findings.group_by { |r| r['code'] }.transform_values(&:length))
    puts "#{findings.length} findings; report written to #{options[:output]}"
  rescue StandardError
    writer.abort
    raise
  end
end
