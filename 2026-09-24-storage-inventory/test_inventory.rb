require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require 'socket'
require_relative 'compare'

class InventoryTest < Minitest::Test
  ROOT = 'tank/backups'.freeze
  SNAP = "#{ROOT}/users/42/tree.1/branch-main.1@daily".freeze
  CLONE = "#{ROOT}/vpsadmin/mount/42.daily".freeze

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

  def test_reference_count_mismatch_is_reported
    db = db_records
    db.find { |type, _| type == 'snapshot_in_pool' }[1]['reference_count'] = 0
    assert_includes compare(db).map { |f| f['code'] }, 'reference_count_mismatch'
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

  def test_db_client_failure_leaves_no_capture
    config = File.join(@dir, 'client.cnf')
    File.write(config, "[client]\nuser=reader\n")
    File.chmod(0o600, config)
    fake = File.join(@dir, 'mysql')
    File.write(fake, <<~RUBY)
      #!#{RbConfig.ruby}
      input = STDIN.read
      abort 'missing read-only transaction' unless input.include?('START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY')
      abort 'missing streaming/no-reconnect options' unless ARGV.include?('--quick') && ARGV.include?('--skip-reconnect')
      puts "pool\\t{\\"id\\":1,\\"filesystem\\":\\"tank/backups\\"}"
      warn 'simulated mysql failure'
      exit 1
    RUBY
    File.chmod(0o700, fake)
    output = File.join(@dir, 'db.jsonl')
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby,
      File.join(__dir__, 'capture_db.rb'), '--node-id', '2',
      '--defaults-file', config, '--mysql-bin', fake, '--output', output)
    refute status.success?
    assert_includes stderr, 'simulated mysql failure'
    refute File.exist?(output)
    refute Dir.children(@dir).any? { |name| name.end_with?('.tmp') }
  end

  def test_db_collector_streams_complete_private_capture
    config = File.join(@dir, 'client.cnf')
    File.write(config, "[client]\nuser=reader\n")
    File.chmod(0o600, config)
    fake = File.join(@dir, 'mysql-ok')
    File.write(fake, <<~RUBY)
      #!#{RbConfig.ruby}
      input = STDIN.read
      abort 'missing node scope' unless input.include?('WHERE n.id = 2')
      abort 'missing lock query' unless input.include?("l.resource = 'Branch'")
      abort 'missing streaming/no-reconnect options' unless ARGV.include?('--quick') && ARGV.include?('--skip-reconnect')
      puts "observation\\t{\\"server_time_utc\\":\\"2026-09-24T00:00:00Z\\"}"
      puts "node\\t{\\"id\\":2,\\"name\\":\\"backuper2\\",\\"location_domain\\":\\"backuper2.prg\\",\\"fqdn\\":\\"backuper2.prg.vpsfree.cz\\"}"
      puts "pool\\t{\\"id\\":1,\\"node_id\\":2,\\"filesystem\\":\\"tank/backups\\"}"
    RUBY
    File.chmod(0o700, fake)
    output = File.join(@dir, 'db.jsonl')
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby,
      File.join(__dir__, 'capture_db.rb'), '--node-id', '2',
      '--defaults-file', config, '--mysql-bin', fake, '--output', output)
    assert status.success?, stderr
    capture = StorageInventory::Reader.new(output, 'db')
    assert_equal 1, capture.records['node'].length
    assert_equal 0o600, File.stat(output).mode & 0o777
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
