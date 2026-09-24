require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require 'socket'
require_relative 'compare'
require_relative 'db_capture'

class InventoryTest < Minitest::Test
  ROOT = 'tank/backups'.freeze
  SNAP = "#{ROOT}/users/42/tree.1/branch-main.1@daily".freeze
  CLONE = "#{ROOT}/vpsadmin/mount/42.daily".freeze

  class FakeConnection
    attr_reader :commands

    def initialize
      @commands = []
      @raw_connection = Object.new
    end

    def open_transactions
      0
    end

    def execute(sql)
      @commands << sql
    end

    def select_value(sql)
      @commands << sql
      case sql
      when 'SELECT @@SESSION.max_statement_time' then '0'
      when StorageInventory::DbCapture::SERVER_CLOCK_SQL then '2026-09-24T12:00:00.000000Z'
      when 'SELECT CONNECTION_ID()' then 17
      else raise "unexpected scalar query: #{sql}"
      end
    end

    def raw_connection
      @raw_connection
    end

    def reconnect!
      @raw_connection = Object.new
    end
  end

  class FakeRelation
    def initialize(rows, model)
      @rows, @model = rows, model
    end

    def where(conditions)
      selected = @rows.select do |row|
        conditions.all? do |key, expected|
          Array(expected).any? { |value| value.to_s == row[key].to_s }
        end
      end
      self.class.new(selected, @model)
    end

    def in_batches(of:)
      @rows.each_slice(of) do |slice|
        @model.batch_sizes << slice.length
        yield self.class.new(slice, @model)
      end
    end

    def pluck(*fields)
      raise 'simulated model query failure' if @model.fail_pluck
      @model.after_pluck&.call
      @rows.map { |row| fields.map { |field| row[field] } }
    end
  end

  class FakeModel
    attr_reader :connection, :rows, :batch_sizes
    attr_accessor :fail_pluck, :after_pluck

    def initialize(rows, connection, single: nil)
      @rows, @connection, @single = rows, connection, single
      @batch_sizes = []
    end

    def includes(*)
      self
    end

    def find(id)
      raise 'node absent' unless @single && @single.id == id
      @single
    end

    def where(conditions)
      FakeRelation.new(@rows, self).where(conditions)
    end

    def roles
      { 'backup' => 2 }
    end

    def states
      { 'online' => 1, 'active' => 0 }
    end

    def object_states
      { 'active' => 0, 'deleted' => 1 }
    end
  end

  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    Dir.children(@dir).each { |name| File.unlink(File.join(@dir, name)) }
    Dir.rmdir(@dir)
  end

  def capture(name, kind, scope, records, extra = {})
    path = File.join(@dir, name)
    header = { 'kind' => kind, 'scope' => scope, 'started_at' => StorageInventory.now }
    header['host'] = extra.fetch('capture_host', 'backuper2.prg') if kind == 'zfs'
    extra = extra.reject { |key, _value| key == 'capture_host' }
    writer = StorageInventory::Writer.new(path, header)
    records.each { |type, data| writer.add(type, data) }
    if kind == 'zfs'
      now = StorageInventory.now
      extra = { 'first_scan_finished_at' => now, 'second_scan_started_at' => now,
                'second_scan_finished_at' => now }.merge(extra)
    end
    writer.finish(extra)
    path
  end

  def db_records
    [
      ['observation', { 'server_time_utc' => StorageInventory.now }],
      ['node', { 'id' => 2, 'name' => 'backuper2',
                 'location_domain' => 'backuper2.prg', 'fqdn' => 'backuper2.prg.vpsfree.cz' }],
      ['pool', { 'id' => 1, 'node_id' => 2, 'filesystem' => ROOT, 'maintenance_lock' => 0 }],
      ['dataset', { 'id' => 10, 'full_name' => 'users/42', 'confirmed' => 1 }],
      ['dataset_in_pool', { 'id' => 20, 'pool_id' => 1, 'dataset_id' => 10, 'confirmed' => 1 }],
      ['tree', { 'id' => 30, 'dataset_in_pool_id' => 20, 'index' => 1, 'head' => 1, 'confirmed' => 1 }],
      ['branch', { 'id' => 40, 'dataset_tree_id' => 30, 'index' => 1, 'name' => 'main', 'head' => 1, 'confirmed' => 1 }],
      ['snapshot', { 'id' => 50, 'dataset_id' => 10, 'name' => 'daily', 'confirmed' => 1 }],
      ['snapshot_in_pool', { 'id' => 60, 'dataset_in_pool_id' => 20, 'snapshot_id' => 50, 'reference_count' => 1, 'confirmed' => 1 }],
      ['snapshot_in_branch', { 'id' => 70, 'branch_id' => 40, 'snapshot_in_pool_id' => 60, 'confirmed' => 1 }],
      ['clone', { 'id' => 80, 'snapshot_in_pool_id' => 60, 'name' => '42.daily', 'confirmed' => 1 }]
    ]
  end

  def fake_db_models(connection)
    records = db_records.group_by(&:first)
    models = StorageInventory::DbCapture::MODEL_NAMES.keys.to_h do |key|
      rows = records.fetch(key.to_s, []).map { |_type, row| row.transform_keys(&:to_sym) }
      [key, FakeModel.new(rows, connection)]
    end
    node = records.fetch('node').first.last
    node_struct = Struct.new(:id, :name, :location_domain, :fqdn, keyword_init: true)
    models[:node] = FakeModel.new([], connection, single: node_struct.new(**node.transform_keys(&:to_sym)))
    models[:pool].rows.first.merge!(role: 'backup', state: 'online', is_open: 1)
    models[:dataset].rows.first[:object_state] = 'active'
    models[:tree].rows.first[:head] = true
    models[:branch].rows.first[:head] = true
    models[:clone].rows.first[:state] = 'active'
    models
  end

  def zfs_records
    [ROOT, "#{ROOT}/users/42", "#{ROOT}/users/42/tree.1",
     "#{ROOT}/users/42/tree.1/branch-main.1", SNAP, CLONE].map do |name|
      row = { 'name' => name, 'type' => name.include?('@') ? 'snapshot' : 'filesystem',
              'guid' => (name.hash.abs % 1_000_000).to_s, 'origin' => name == CLONE ? SNAP : nil }
      row.merge!('clones' => CLONE, 'userrefs' => '0', 'defer_destroy' => 'off') if name == SNAP
      ['zfs_object', row]
    end
  end

  def compare(db_rows = db_records, zfs_rows = zfs_records, volatile: false)
    db = StorageInventory::Reader.new(capture('db.jsonl', 'db', { 'node_id' => 2 }, db_rows), 'db')
    zfs = StorageInventory::Reader.new(capture('zfs.jsonl', 'zfs', { 'roots' => [ROOT] }, zfs_rows,
      'volatile' => volatile), 'zfs')
    StorageInventory::Comparator.new(db, zfs).run
  end

  def test_exact_branch_path_and_clone_origin
    codes = compare.map { |f| f['code'] }
    assert_equal [], codes - ['untracked_zfs_object']
    refute_includes codes, 'missing_zfs_object'
  end

  def test_missing_snapshot_and_external_clone_are_reported
    rows = zfs_records.reject { |_type, row| row['name'] == SNAP }
    rows << ['zfs_object', { 'name' => "#{ROOT}/unexpected@daily", 'type' => 'snapshot',
                             'guid' => '999', 'origin' => nil, 'clones' => 'otherpool/clone',
                             'userrefs' => '1', 'defer_destroy' => 'on' }]
    codes = compare(db_records, rows).map { |f| f['code'] }
    assert_includes codes, 'missing_zfs_object'
    assert_includes codes, 'untracked_zfs_object'
    assert_includes codes, 'external_or_unscanned_clone'
    assert_includes codes, 'zfs_hold_or_deferred'
  end

  def test_unconfirmed_rows_and_locks_are_preserved_as_findings
    rows = db_records
    rows.find { |type, _| type == 'snapshot_in_branch' }[1]['confirmed'] = 0
    rows << ['resource_lock', { 'id' => 90, 'row_id' => 20 }]
    codes = compare(rows).map { |f| f['code'] }
    assert_includes codes, 'unconfirmed_db_row'
    assert_includes codes, 'resource_lock'
  end

  def test_tampered_capture_is_rejected
    path = capture('tampered.jsonl', 'db', { 'node_id' => 2 }, db_records)
    File.open(path, 'a') { |f| f.puts('{"record":"pool","data":{}}') }
    assert_raises(ArgumentError) { StorageInventory::Reader.new(path, 'db') }
  end

  def test_scope_mismatch_fails_closed
    db = StorageInventory::Reader.new(capture('db.jsonl', 'db', { 'node_id' => 2 }, db_records), 'db')
    zfs = StorageInventory::Reader.new(capture('zfs.jsonl', 'zfs', { 'roots' => ['wrong/root'] },
      zfs_records, 'volatile' => false), 'zfs')
    assert_raises(ArgumentError) { StorageInventory::Comparator.new(db, zfs).run }
  end

  def test_host_mismatch_fails_closed
    db = StorageInventory::Reader.new(capture('db.jsonl', 'db', { 'node_id' => 2 }, db_records), 'db')
    path = capture('zfs.jsonl', 'zfs', { 'roots' => [ROOT] }, zfs_records)
    File.write(path, File.read(path).sub('backuper2.prg', 'wrong.prg'))
    assert_raises(ArgumentError) { StorageInventory::Reader.new(path, 'zfs') }
    writer = StorageInventory::Writer.new(File.join(@dir, 'other.jsonl'),
      'kind' => 'zfs', 'scope' => { 'roots' => [ROOT] }, 'started_at' => StorageInventory.now,
      'host' => 'wrong.prg')
    zfs_records.each { |type, row| writer.add(type, row) }
    now = StorageInventory.now
    writer.finish('volatile' => false, 'first_scan_finished_at' => now,
                  'second_scan_started_at' => now, 'second_scan_finished_at' => now)
    zfs = StorageInventory::Reader.new(File.join(@dir, 'other.jsonl'), 'zfs')
    assert_raises(ArgumentError) { StorageInventory::Comparator.new(db, zfs).run }
  end

  def test_short_host_is_rejected_for_nodes_with_colliding_names
    # These nodes can share a short name in separate locations. Each scoped
    # capture contains only one node, so neither can prove global uniqueness.
    %w[prg lhr].each do |location|
      db_rows = db_records
      node = db_rows.find { |type, _| type == 'node' }[1]
      node['location_domain'] = "backuper2.#{location}"
      node['fqdn'] = "backuper2.#{location}.vpsfree.cz"
      db = StorageInventory::Reader.new(capture("db-#{location}.jsonl", 'db',
        { 'node_id' => 2 }, db_rows), 'db')
      zfs = StorageInventory::Reader.new(capture("zfs-#{location}.jsonl", 'zfs',
        { 'roots' => [ROOT] }, zfs_records,
        { 'volatile' => false, 'capture_host' => 'backuper2' }), 'zfs')
      assert_raises(ArgumentError) { StorageInventory::Comparator.new(db, zfs).run }
    end
  end

  def test_expected_zfs_type_is_checked
    rows = zfs_records
    rows.find { |_type, row| row['name'] == SNAP }[1]['type'] = 'filesystem'
    assert_includes compare(db_records, rows).map { |f| f['code'] }, 'zfs_type_mismatch'
  end

  def test_db_parent_edge_rejects_zfs_self_consistent_wrong_origin
    db = db_records
    old_branch = "#{ROOT}/users/42/tree.1/branch-old.2"
    wrong_source = "#{ROOT}/untracked@other"
    db << ['branch', { 'id' => 41, 'dataset_tree_id' => 30, 'index' => 2,
                       'name' => 'old', 'head' => 0, 'confirmed' => 1 }]
    db << ['snapshot', { 'id' => 51, 'dataset_id' => 10, 'name' => 'later', 'confirmed' => 1 }]
    db << ['snapshot_in_pool', { 'id' => 61, 'dataset_in_pool_id' => 20,
                                 'snapshot_id' => 51, 'reference_count' => 0, 'confirmed' => 1 }]
    db << ['snapshot_in_branch', { 'id' => 71, 'branch_id' => 41,
                                   'snapshot_in_pool_id' => 61,
                                   'snapshot_in_pool_in_branch_id' => 70, 'confirmed' => 1 }]
    db.find { |type, row| type == 'snapshot_in_pool' && row['id'] == 60 }[1]['reference_count'] = 2
    zfs = zfs_records
    zfs << ['zfs_object', { 'name' => old_branch, 'type' => 'filesystem',
                           'guid' => '900', 'origin' => wrong_source }]
    zfs << ['zfs_object', { 'name' => "#{old_branch}@later", 'type' => 'snapshot',
                           'guid' => '901', 'origin' => nil, 'clones' => '-',
                           'userrefs' => '0', 'defer_destroy' => 'off' }]
    zfs << ['zfs_object', { 'name' => wrong_source, 'type' => 'snapshot',
                           'guid' => '902', 'origin' => nil, 'clones' => old_branch,
                           'userrefs' => '0', 'defer_destroy' => 'off' }]
    codes = compare(db, zfs).map { |f| f['code'] }
    assert_includes codes, 'db_zfs_branch_origin_mismatch'
    assert_includes codes, 'db_zfs_clone_edge_missing'
  end

  def test_db_parent_edge_accepts_matching_physical_origin
    db = db_records
    old_branch = "#{ROOT}/users/42/tree.1/branch-old.2"
    db << ['branch', { 'id' => 41, 'dataset_tree_id' => 30, 'index' => 2,
                       'name' => 'old', 'head' => 0, 'confirmed' => 1 }]
    db << ['snapshot_in_branch', { 'id' => 71, 'branch_id' => 41,
                                   'snapshot_in_pool_id' => 60,
                                   'snapshot_in_pool_in_branch_id' => 70,
                                   'confirmed' => 1 }]
    db.find { |type, row| type == 'snapshot_in_pool' && row['id'] == 60 }[1]['reference_count'] = 2
    zfs = zfs_records
    zfs << ['zfs_object', { 'name' => old_branch, 'type' => 'filesystem',
                           'guid' => '920', 'origin' => SNAP }]
    zfs << ['zfs_object', { 'name' => "#{old_branch}@daily", 'type' => 'snapshot',
                           'guid' => '921', 'origin' => nil, 'clones' => '-',
                           'userrefs' => '0', 'defer_destroy' => 'off' }]
    zfs.find { |_type, row| row['name'] == SNAP }[1]['clones'] = "#{CLONE},#{old_branch}"
    codes = compare(db, zfs).map { |f| f['code'] }
    refute_includes codes, 'db_zfs_branch_origin_mismatch'
    refute_includes codes, 'db_zfs_clone_edge_missing'
    refute_includes codes, 'indeterminate_branch_origin'
  end

  def test_reference_count_below_scoped_minimum_is_reported
    db = db_records
    db << ['snapshot_in_branch', { 'id' => 71, 'branch_id' => 40,
                                   'snapshot_in_pool_id' => 60,
                                   'snapshot_in_pool_in_branch_id' => 70,
                                   'confirmed' => 1 }]
    finding = compare(db).find { |row| row['code'] == 'reference_count_below_scoped_minimum' }

    assert_equal({ id: 60, stored: 1, scoped_dependent_entries: 1,
                   scoped_clone_rows: 1, scoped_minimum: 2 }, finding['details'])
  end

  def test_reference_count_above_scoped_minimum_is_inconclusive_diagnostic
    db = db_records
    db.find { |type, _| type == 'snapshot_in_pool' }[1]['reference_count'] = 2

    assert_includes compare(db),
                    { 'code' => 'reference_count_above_scoped_minimum',
                      'details' => { id: 60, stored: 2, scoped_dependent_entries: 0,
                                     scoped_clone_rows: 1, scoped_minimum: 1 } }
  end

  def test_parent_absent_from_node_capture_is_unresolved
    db = db_records
    db.find { |type, _| type == 'snapshot_in_branch' }[1]['snapshot_in_pool_in_branch_id'] = 999

    findings = compare(db)
    assert_includes findings,
                    { 'code' => 'unresolved_snapshot_parent',
                      'details' => { id: 70, parent_id: 999, reason: 'absent_from_node_capture' } }
    refute findings.any? { |row| row['code'] == 'broken_db_link' &&
                               row['details'][:type] == 'snapshot_parent' }
  end

  def test_present_parent_with_broken_local_link_is_reported_separately
    db = db_records
    db.find { |type, _| type == 'snapshot_in_branch' }[1]['snapshot_in_pool_id'] = 999
    db << ['snapshot_in_branch', { 'id' => 71, 'branch_id' => 40,
                                   'snapshot_in_pool_id' => 60,
                                   'snapshot_in_pool_in_branch_id' => 70,
                                   'confirmed' => 1 }]

    findings = compare(db)
    assert_includes findings, { 'code' => 'broken_db_link',
                                'details' => { type: 'snapshot_in_branch', id: 70 } }
    refute findings.any? { |row| row['code'] == 'unresolved_snapshot_parent' &&
                               row['details'][:id] == 71 }
  end

  def test_nonhead_tree_without_head_branch_is_expected
    db = db_records
    db << ['tree', { 'id' => 31, 'dataset_in_pool_id' => 20,
                     'index' => 2, 'head' => 0, 'confirmed' => 1 }]
    db << ['branch', { 'id' => 41, 'dataset_tree_id' => 31,
                       'index' => 1, 'name' => 'older', 'head' => 0, 'confirmed' => 1 }]

    unexpected = compare(db).select do |row|
      %w[branch_head_count nonhead_tree_branch_head].include?(row['code']) &&
        row['details'][:id] == 31
    end
    assert_empty unexpected
  end

  def test_nonhead_tree_with_head_branch_is_reported
    db = db_records
    db << ['tree', { 'id' => 31, 'dataset_in_pool_id' => 20,
                     'index' => 2, 'head' => 0, 'confirmed' => 1 }]
    db << ['branch', { 'id' => 41, 'dataset_tree_id' => 31,
                       'index' => 1, 'name' => 'older', 'head' => 1, 'confirmed' => 1 }]

    assert_includes compare(db),
                    { 'code' => 'nonhead_tree_branch_head',
                      'details' => { id: 31, head_branch_count: 1 } }
  end

  def test_populated_headless_backup_dip_is_diagnostic
    db = db_records
    db.find { |type, _| type == 'tree' }[1]['head'] = 0
    db.find { |type, _| type == 'branch' }[1]['head'] = 0

    findings = compare(db)
    assert_includes findings,
                    { 'code' => 'headless_backup_dataset_in_pool',
                      'details' => { id: 20, tree_count: 1, branch_count: 1,
                                     snapshot_entry_count: 1 } }
    refute findings.any? { |row| row['code'] == 'tree_head_count' && row['details'][:id] == 20 }
  end

  def test_headless_backup_dip_without_snapshot_entries_reports_zero
    db = db_records
    db.find { |type, _| type == 'tree' }[1]['head'] = 0
    db.find { |type, _| type == 'branch' }[1]['head'] = 0
    db.reject! { |type, _| type == 'snapshot_in_branch' }

    assert_includes compare(db),
                    { 'code' => 'headless_backup_dataset_in_pool',
                      'details' => { id: 20, tree_count: 1, branch_count: 1,
                                     snapshot_entry_count: 0 } }
  end

  def test_multiple_tree_heads_remain_invariant_failure
    db = db_records
    db << ['tree', { 'id' => 31, 'dataset_in_pool_id' => 20,
                     'index' => 2, 'head' => 1, 'confirmed' => 1 }]
    db << ['branch', { 'id' => 41, 'dataset_tree_id' => 31,
                       'index' => 1, 'name' => 'other', 'head' => 1, 'confirmed' => 1 }]

    assert_includes compare(db),
                    { 'code' => 'tree_head_count',
                      'details' => { id: 20, count: 2, expected: 1 } }
  end

  def test_head_tree_without_head_branch_remains_invariant_failure
    db = db_records
    db.find { |type, _| type == 'branch' }[1]['head'] = 0

    assert_includes compare(db),
                    { 'code' => 'branch_head_count',
                      'details' => { id: 30, count: 0, expected: 1 } }
  end

  def test_head_tree_with_multiple_head_branches_remains_invariant_failure
    db = db_records
    db << ['branch', { 'id' => 41, 'dataset_tree_id' => 30,
                       'index' => 2, 'name' => 'other', 'head' => 1, 'confirmed' => 1 }]

    assert_includes compare(db),
                    { 'code' => 'branch_head_count',
                      'details' => { id: 30, count: 2, expected: 1 } }
  end

  def test_ambiguous_parent_pointer_is_not_treated_as_a_match
    db = db_records
    db << ['branch', { 'id' => 41, 'dataset_tree_id' => 30, 'index' => 2,
                       'name' => 'old', 'head' => 0, 'confirmed' => 1 }]
    db << ['snapshot_in_branch', { 'id' => 71, 'branch_id' => 41,
                                   'snapshot_in_pool_id' => 60,
                                   'snapshot_in_pool_in_branch_id' => 71,
                                   'confirmed' => 1 }]
    db.find { |type, row| type == 'snapshot_in_pool' && row['id'] == 60 }[1]['reference_count'] = 2
    old_branch = "#{ROOT}/users/42/tree.1/branch-old.2"
    zfs = zfs_records
    zfs << ['zfs_object', { 'name' => old_branch, 'type' => 'filesystem',
                           'guid' => '910', 'origin' => SNAP }]
    zfs << ['zfs_object', { 'name' => "#{old_branch}@daily", 'type' => 'snapshot',
                           'guid' => '911', 'origin' => nil, 'clones' => '-',
                           'userrefs' => '0', 'defer_destroy' => 'off' }]
    zfs.find { |_type, row| row['name'] == SNAP }[1]['clones'] = "#{CLONE},#{old_branch}"
    codes = compare(db, zfs).map { |f| f['code'] }
    assert_includes codes, 'indeterminate_branch_origin'
    assert_includes codes, 'unrepresented_branch_origin'
  end

  def test_trailer_volatility_is_integrity_checked
    path = capture('zfs.jsonl', 'zfs', { 'roots' => [ROOT] }, zfs_records,
                   'volatile' => false)
    File.write(path, File.read(path).sub('"volatile":false', '"volatile":true'))
    assert_raises(ArgumentError) { StorageInventory::Reader.new(path, 'zfs') }

    writer = StorageInventory::Writer.new(File.join(@dir, 'inconsistent.jsonl'),
      'kind' => 'zfs', 'scope' => { 'roots' => [ROOT] }, 'started_at' => StorageInventory.now,
      'host' => 'backuper2.prg')
    zfs_records.each { |type, row| writer.add(type, row) }
    now = StorageInventory.now
    writer.finish('volatile' => true, 'first_scan_finished_at' => now,
                  'second_scan_started_at' => now, 'second_scan_finished_at' => now)
    assert_raises(ArgumentError) do
      StorageInventory::Reader.new(File.join(@dir, 'inconsistent.jsonl'), 'zfs')
    end
  end

  def test_db_model_failure_rolls_back_and_leaves_no_capture
    connection = FakeConnection.new
    models = fake_db_models(connection)
    models[:snapshot].fail_pluck = true
    output = File.join(@dir, 'db.jsonl')
    error = assert_raises(RuntimeError) do
      StorageInventory::DbCapture.new(node_id: 2, output: output,
        connection: connection, models: models).run
    end
    assert_equal 'simulated model query failure', error.message
    assert_includes connection.commands, 'SET TRANSACTION ISOLATION LEVEL REPEATABLE READ'
    assert_includes connection.commands, 'START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY'
    assert_includes connection.commands, 'SET SESSION max_statement_time = 30'
    assert_equal ['ROLLBACK', 'SET SESSION max_statement_time = 0.0'], connection.commands.last(2)
    refute File.exist?(output)
    refute Dir.children(@dir).any? { |name| name.end_with?('.tmp') }
  end

  def test_db_models_capture_complete_private_batched_output
    connection = FakeConnection.new
    models = fake_db_models(connection)
    1_000.times do |i|
      models[:snapshot].rows << { id: 1_000 + i, dataset_id: 10,
                                  name: "extra-#{i}", history_id: 0, confirmed: 0 }
    end
    models[:resource_lock].rows << { id: 90, resource: 'DatasetInPool', row_id: 20 }
    output = File.join(@dir, 'db.jsonl')
    StorageInventory::DbCapture.new(node_id: 2, output: output,
      connection: connection, models: models).run
    capture = StorageInventory::Reader.new(output, 'db')
    assert_equal 1_001, capture.records['snapshot'].length
    assert_equal 1_000, models[:snapshot].batch_sizes.max
    assert_equal 2, capture.records['pool'].first['role']
    assert_equal 0, capture.records['dataset'].first['object_state']
    assert_equal 1, capture.records['branch'].first['head']
    assert_equal 0, capture.records['clone'].first['state']
    assert_equal 0, capture.records['snapshot'].last['confirmed']
    observation = capture.records['observation'].first
    assert_equal '2026-09-24T12:00:00.000000Z', observation['server_time_utc']
    assert_equal 17, observation['connection_id']
    assert_operator Time.iso8601(observation.fetch('collector_finished_at_utc')), :>=,
                    Time.iso8601(observation.fetch('collector_time_utc'))
    assert_equal 1, capture.records['resource_lock'].length
    assert_operator connection.commands.index('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ'), :<,
                    connection.commands.index('START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY')
    assert_equal ['ROLLBACK', 'SET SESSION max_statement_time = 0.0'], connection.commands.last(2)
    assert_equal 0o600, File.stat(output).mode & 0o777
  end

  def test_db_models_scope_to_backup_pools_on_selected_node
    connection = FakeConnection.new
    models = fake_db_models(connection)
    models[:pool].rows.concat([
      { id: 2, node_id: 3, role: 'backup', filesystem: 'tank/foreign' },
      { id: 3, node_id: 2, role: 'primary', filesystem: 'tank/primary' }
    ])
    models[:dataset_in_pool].rows << { id: 21, pool_id: 2, dataset_id: 11, confirmed: 0 }
    models[:dataset].rows << { id: 11, full_name: 'foreign', confirmed: 0 }
    models[:snapshot].rows << { id: 51, dataset_id: 11, name: 'foreign', confirmed: 0 }

    output = File.join(@dir, 'db.jsonl')
    StorageInventory::DbCapture.new(node_id: 2, output: output,
      connection: connection, models: models).run
    records = StorageInventory::Reader.new(output, 'db').records

    assert_equal [1], records.fetch('pool').map { |row| row.fetch('id') }
    assert_equal [20], records.fetch('dataset_in_pool').map { |row| row.fetch('id') }
    assert_equal [10], records.fetch('dataset').map { |row| row.fetch('id') }
    assert_equal [50], records.fetch('snapshot').map { |row| row.fetch('id') }
  end

  def test_db_snapshot_resource_lock_reaches_comparison_findings
    connection = FakeConnection.new
    models = fake_db_models(connection)
    models[:resource_lock].rows << { id: 91, resource: 'Snapshot', row_id: 50,
                                     locked_by_id: 12, locked_by_type: 'TransactionChain' }
    output = File.join(@dir, 'db.jsonl')

    StorageInventory::DbCapture.new(node_id: 2, output: output,
      connection: connection, models: models).run
    db = StorageInventory::Reader.new(output, 'db')
    zfs = StorageInventory::Reader.new(capture('zfs.jsonl', 'zfs',
      { 'roots' => [ROOT] }, zfs_records, 'volatile' => false), 'zfs')

    assert_includes db.records.fetch('resource_lock'),
                    { 'id' => 91, 'resource' => 'Snapshot', 'row_id' => 50,
                      'locked_by_id' => 12, 'locked_by_type' => 'TransactionChain',
                      'created_at' => nil, 'updated_at' => nil }
    assert_includes StorageInventory::Comparator.new(db, zfs).run,
                    { 'code' => 'resource_lock',
                      'details' => { id: 91, resource: 'Snapshot', row_id: 50 } }
  end

  def test_db_connection_replacement_aborts_capture
    connection = FakeConnection.new
    models = fake_db_models(connection)
    models[:snapshot].after_pluck = proc { connection.reconnect! }
    output = File.join(@dir, 'db.jsonl')

    error = assert_raises(RuntimeError) do
      StorageInventory::DbCapture.new(node_id: 2, output: output,
        connection: connection, models: models).run
    end

    assert_equal 'DB connection changed during capture', error.message
    assert_includes connection.commands, 'ROLLBACK'
    refute File.exist?(output)
    refute Dir.children(@dir).any? { |name| name.end_with?('.tmp') }
  end

  def test_db_deadline_aborts_incomplete_capture
    connection = FakeConnection.new
    models = fake_db_models(connection)
    output = File.join(@dir, 'db.jsonl')
    capture = StorageInventory::DbCapture.new(node_id: 2, output: output,
      connection: connection, models: models)
    models[:snapshot].after_pluck = proc { capture.instance_variable_set(:@deadline, 0) }

    error = assert_raises(RuntimeError) { capture.run }

    assert_equal 'DB capture exceeded 15-minute limit', error.message
    assert_includes connection.commands, 'ROLLBACK'
    refute File.exist?(output)
    refute Dir.children(@dir).any? { |name| name.end_with?('.tmp') }
  end

  def test_api_runner_load_invokes_cli
    argv = ARGV.dup
    called_with = nil
    ARGV.replace(['--node-id', '2', '--output', 'db.jsonl'])
    original_cli = StorageInventory::DbCapture.method(:cli)
    StorageInventory::DbCapture.define_singleton_method(:cli) { |args| called_with = args.dup }
    load File.join(__dir__, 'capture_db.rb')

    assert_equal ['--node-id', '2', '--output', 'db.jsonl'], called_with
  ensure
    StorageInventory::DbCapture.define_singleton_method(:cli, original_cli) if original_cli
    ARGV.replace(argv)
  end

  def test_db_cli_rejects_relative_output_before_loading_api
    error = assert_raises(ArgumentError) do
      StorageInventory::DbCapture.cli(['--node-id', '2', '--output', 'db.jsonl'])
    end

    assert_equal '--output must be an absolute path', error.message
  end

  def test_zfs_double_scan_marks_changed_guid
    fake = File.join(@dir, 'zfs')
    counter = File.join(@dir, 'counter')
    File.write(fake, <<~RUBY)
      #!#{RbConfig.ruby}
      if ARGV[0] == 'list'
        n = File.exist?(ENV.fetch('FAKE_COUNTER')) ? File.read(ENV.fetch('FAKE_COUNTER')).to_i + 1 : 1
        File.write(ENV.fetch('FAKE_COUNTER'), n)
        puts "tank/backups\\tfilesystem\\t1\\t-"
        puts "tank/backups/data@daily\\tsnapshot\\t#{'#{n}'}\\t-"
      elsif ARGV[0] == 'get'
        %w[clones userrefs defer_destroy].zip(%w[- 0 off]).each do |property, value|
          puts "tank/backups/data@daily\\t#{'#{property}'}\\t#{'#{value}'}"
        end
      else
        exit 1
      end
    RUBY
    File.chmod(0o700, fake)
    output = File.join(@dir, 'zfs.jsonl')
    _stdout, stderr, status = Open3.capture3({ 'FAKE_COUNTER' => counter }, RbConfig.ruby,
      File.join(__dir__, 'capture_zfs.rb'), '--root', ROOT, '--zfs-bin', fake, '--output', output)
    assert status.success?, stderr
    capture = StorageInventory::Reader.new(output, 'zfs')
    assert_equal true, capture.trailer['volatile']
    assert_equal 1, capture.records['scan_change'].length
    assert_equal 0o600, File.stat(output).mode & 0o777
  end

  def test_zfs_failure_leaves_no_capture
    fake = File.join(@dir, 'zfs-fail')
    File.write(fake, "#!#{RbConfig.ruby}\nwarn 'simulated zfs failure'\nexit 9\n")
    File.chmod(0o700, fake)
    output = File.join(@dir, 'zfs.jsonl')
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby,
      File.join(__dir__, 'capture_zfs.rb'), '--root', ROOT, '--zfs-bin', fake, '--output', output)
    refute status.success?
    assert_includes stderr, 'simulated zfs failure'
    refute File.exist?(output)
    refute Dir.children(@dir).any? { |name| name.end_with?('.tmp') }
  end

  def test_unqualified_hostname_leaves_no_zfs_capture
    fake_hostname = File.join(@dir, 'hostname')
    File.write(fake_hostname, "#!#{RbConfig.ruby}\nputs #{Socket.gethostname.split('.').first.inspect}\n")
    File.chmod(0o700, fake_hostname)
    output = File.join(@dir, 'zfs.jsonl')
    _stdout, stderr, status = Open3.capture3(
      { 'PATH' => "#{@dir}:#{ENV.fetch('PATH')}" }, RbConfig.ruby,
      File.join(__dir__, 'capture_zfs.rb'), '--root', ROOT, '--output', output
    )
    refute status.success?
    assert_includes stderr, 'hostname -f must return a qualified host name'
    refute File.exist?(output)
  end
end
