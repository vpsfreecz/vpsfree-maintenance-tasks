#!/usr/bin/env ruby
require 'open3'
require 'optparse'
require_relative 'inventory'

options = { mysql: 'mysql' }
OptionParser.new do |o|
  o.banner = 'Usage: capture_db.rb --node-id ID --defaults-file PRIVATE.cnf --output capture.jsonl'
  o.on('--node-id ID', Integer) { |v| options[:node_id] = v }
  o.on('--defaults-file PATH') { |v| options[:defaults_file] = v }
  o.on('--mysql-bin PATH') { |v| options[:mysql] = v }
  o.on('--output PATH') { |v| options[:output] = v }
end.parse!
raise ArgumentError, 'unexpected arguments' unless ARGV.empty?
raise ArgumentError, 'positive --node-id required' unless options[:node_id].to_i.positive?
raise ArgumentError, '--defaults-file and --output required' unless options[:defaults_file] && options[:output]
raise ArgumentError, 'defaults file must be a regular private file' unless
  File.file?(options[:defaults_file]) && (File.stat(options[:defaults_file]).mode & 0o077).zero?

node_id = options.fetch(:node_id)
scope = "p.node_id = #{node_id} AND p.role = 2"
dip_scope = "SELECT dip.id FROM dataset_in_pools dip JOIN pools p ON p.id = dip.pool_id WHERE #{scope}"
pool_scope = "SELECT p.id FROM pools p WHERE #{scope}"
tree_scope = "SELECT t.id FROM dataset_trees t WHERE t.dataset_in_pool_id IN (#{dip_scope})"
branch_scope = "SELECT b.id FROM branches b WHERE b.dataset_tree_id IN (#{tree_scope})"
sip_scope = "SELECT sip.id FROM snapshot_in_pools sip WHERE sip.dataset_in_pool_id IN (#{dip_scope})"
sipb_scope = "SELECT sipb.id FROM snapshot_in_pool_in_branches sipb WHERE sipb.snapshot_in_pool_id IN (#{sip_scope})"
clone_scope = "SELECT cl.id FROM snapshot_in_pool_clones cl WHERE cl.snapshot_in_pool_id IN (#{sip_scope})"
snapshot_scope = "SELECT DISTINCT dip.dataset_id FROM dataset_in_pools dip WHERE dip.id IN (#{dip_scope})"
lock_scopes = {
  'Node' => node_id.to_s, 'Pool' => pool_scope, 'Dataset' => snapshot_scope,
  'DatasetInPool' => dip_scope, 'DatasetTree' => tree_scope, 'Branch' => branch_scope,
  'SnapshotInPool' => sip_scope, 'SnapshotInPoolInBranch' => sipb_scope,
  'SnapshotInPoolClone' => clone_scope
}
lock_filter = lock_scopes.map do |type, ids|
  ids == node_id.to_s ? "(l.resource = '#{type}' AND l.row_id = #{ids})" :
    "(l.resource = '#{type}' AND l.row_id IN (#{ids}))"
end.join(' OR ')
maintenance_filter = %w[Node Pool Dataset DatasetInPool].map do |type|
  ids = lock_scopes.fetch(type)
  ids == node_id.to_s ? "(l.class_name = '#{type}' AND l.row_id = #{ids})" :
    "(l.class_name = '#{type}' AND l.row_id IN (#{ids}))"
end.join(' OR ')

queries = {
  'pool' => ["pools p", scope, %w[p.id p.node_id p.role p.filesystem p.is_open p.maintenance_lock p.state]],
  'dataset_in_pool' => ["dataset_in_pools dip", "dip.id IN (#{dip_scope})", %w[dip.id dip.pool_id dip.dataset_id dip.confirmed]],
  'dataset' => ["datasets ds", "ds.id IN (#{snapshot_scope})", %w[ds.id ds.full_name ds.confirmed ds.object_state]],
  'tree' => ["dataset_trees t", "t.dataset_in_pool_id IN (#{dip_scope})", %w[t.id t.dataset_in_pool_id t.index t.head t.confirmed]],
  'branch' => ["branches b", "b.dataset_tree_id IN (#{tree_scope})", %w[b.id b.dataset_tree_id b.name b.index b.head b.confirmed]],
  'snapshot' => ["snapshots s", "s.dataset_id IN (#{snapshot_scope})", %w[s.id s.dataset_id s.name s.history_id s.confirmed s.created_at]],
  'snapshot_in_pool' => ["snapshot_in_pools sip", "sip.id IN (#{sip_scope})", %w[sip.id sip.dataset_in_pool_id sip.snapshot_id sip.reference_count sip.mount_id sip.confirmed]],
  'snapshot_in_branch' => ["snapshot_in_pool_in_branches sipb", "sipb.snapshot_in_pool_id IN (#{sip_scope})", %w[sipb.id sipb.branch_id sipb.snapshot_in_pool_id sipb.snapshot_in_pool_in_branch_id sipb.confirmed]],
  'clone' => ["snapshot_in_pool_clones cl", "cl.snapshot_in_pool_id IN (#{sip_scope})", %w[cl.id cl.snapshot_in_pool_id cl.name cl.state cl.confirmed]],
  'resource_lock' => ["resource_locks l", lock_filter, %w[l.id l.resource l.row_id l.locked_by_id l.locked_by_type l.created_at l.updated_at]],
  'maintenance_lock' => ["maintenance_locks l", maintenance_filter, %w[l.id l.class_name l.row_id l.active l.created_at l.updated_at]]
}

def select_line(type, table, where, columns)
  fields = columns.flat_map { |col| ["'#{col.split('.').last}'", col] }.join(', ')
  "SELECT CONCAT('#{type}', CHAR(9), JSON_OBJECT(#{fields})) FROM #{table} WHERE #{where};"
end

sql = [
  "SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;",
  "SET time_zone = '+00:00';",
  'START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY;',
  "SELECT CONCAT('observation', CHAR(9), JSON_OBJECT('server_time_utc', UTC_TIMESTAMP(6)));",
  "SELECT CONCAT('node', CHAR(9), JSON_OBJECT('id', n.id, 'name', n.name, 'location_domain', CONCAT(n.name, '.', l.domain), 'fqdn', CONCAT(n.name, '.', l.domain, '.', e.domain))) FROM nodes n JOIN locations l ON l.id = n.location_id JOIN environments e ON e.id = l.environment_id WHERE n.id = #{node_id};",
  *queries.map { |type, (table, where, columns)| select_line(type, table, where, columns) },
  'COMMIT;'
].join("\n") + "\n"

writer = StorageInventory::Writer.new(
  options.fetch(:output),
  'kind' => 'db', 'started_at' => StorageInventory.now,
  'scope' => { 'node_id' => node_id, 'pool_role' => 'backup' },
  'consistency' => 'repeatable-read read-only consistent snapshot'
)

begin
  command = [options.fetch(:mysql), "--defaults-file=#{options.fetch(:defaults_file)}",
             '--batch', '--raw', '--quick', '--skip-reconnect', '--skip-column-names',
             '--default-character-set=utf8mb4']
  status = nil
  error = nil
  Open3.popen3(*command) do |stdin, stdout, stderr, wait|
    stderr_thread = Thread.new { StorageInventory.stderr_summary(stderr) }
    begin
      stdin.write(sql)
      stdin.close
      StorageInventory.each_bounded_line(stdout) do |line|
        type, payload = line.split("\t", 2)
        raise ArgumentError, 'unexpected DB output' unless payload &&
          (queries.key?(type) || %w[node observation].include?(type))
        writer.add(type, JSON.parse(payload))
      end
      status = wait.value
      error = stderr_thread.value
    rescue StandardError
      Process.kill('TERM', wait.pid) rescue nil
      raise
    end
  end
  raise "mysql failed: #{error.to_s.slice(0, 1000)}" unless status.success?
  raise 'node identity not found' unless writer.counts['node'] == 1
  raise 'no backup pools found for node' if writer.counts['pool'].zero?
  writer.finish
rescue StandardError
  writer.abort
  raise
end
