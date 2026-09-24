#!/usr/bin/env ruby
require 'open3'
require 'optparse'
require 'socket'
require_relative 'inventory'

options = { roots: [], zfs: 'zfs' }
OptionParser.new do |o|
  o.banner = 'Usage: capture_zfs.rb --root POOL/FS [--root ...] --output capture.jsonl'
  o.on('--root NAME') { |v| options[:roots] << StorageInventory.valid_path!(v) }
  o.on('--zfs-bin PATH') { |v| options[:zfs] = v }
  o.on('--output PATH') { |v| options[:output] = v }
end.parse!
raise ArgumentError, 'unexpected arguments' unless ARGV.empty?
raise ArgumentError, '--root and --output required' if options[:roots].empty? || !options[:output]
roots = options[:roots].uniq.sort
raise ArgumentError, 'overlapping roots' if roots.any? { |r| roots.any? { |other| r != other && r.start_with?("#{other}/") } }

kernel_host = Socket.gethostname.downcase.delete_suffix('.')
qualified_output, qualified_error, qualified_status = Open3.capture3('hostname', '-f')
qualified_host = qualified_output.strip.downcase.delete_suffix('.')
raise "unable to determine qualified host: #{qualified_error.slice(0, 1000)}" unless qualified_status.success?
raise ArgumentError, 'hostname -f must return a qualified host name' unless
  qualified_host.match?(/\A[a-z0-9_.-]+\.[a-z0-9_.-]+\z/) &&
  qualified_host.split('.').first == kernel_host.split('.').first

def run_zfs(command)
  lines = []
  error = nil
  status = nil
  Open3.popen3(*command) do |stdin, stdout, stderr, wait|
    stdin.close
    stderr_thread = Thread.new { StorageInventory.stderr_summary(stderr) }
    begin
      StorageInventory.each_bounded_line(stdout) { |line| lines << line }
      status = wait.value
      error = stderr_thread.value
    rescue StandardError
      Process.kill('TERM', wait.pid) rescue nil
      raise
    end
  end
  raise "zfs failed: #{error.to_s.slice(0, 1000)}" unless status.success?
  lines
end

def scan(zfs, roots)
  list = run_zfs([zfs, 'list', '-H', '-p', '-r', '-t', 'filesystem,volume,snapshot',
                  '-o', 'name,type,guid,origin', *roots])
  get = run_zfs([zfs, 'get', '-H', '-p', '-r', '-t', 'snapshot', '-o', 'name,property,value',
                 'clones,userrefs,defer_destroy', *roots])
  rows = {}
  list.each do |line|
    name, type, guid, origin = line.split("\t", -1)
    raise ArgumentError, 'malformed zfs list output' unless [name, type, guid, origin].all?
    raise ArgumentError, 'object outside requested roots' unless roots.any? do |root|
      name == root || name.start_with?("#{root}/", "#{root}@")
    end
    raise ArgumentError, 'duplicate ZFS object' if rows.key?(name)
    rows[name] = { 'name' => name, 'type' => type, 'guid' => guid,
                   'origin' => origin == '-' ? nil : origin }
  end
  get.each do |line|
    name, property, value = line.split("\t", 3)
    raise ArgumentError, 'malformed zfs get output' unless rows[name] &&
      rows[name]['type'] == 'snapshot' && %w[clones userrefs defer_destroy].include?(property) && value
    raise ArgumentError, 'duplicate ZFS property' if rows[name].key?(property)
    rows[name][property] = value
  end
  rows.each_value do |row|
    next unless row['type'] == 'snapshot'
    raise ArgumentError, 'missing snapshot property' unless
      %w[clones userrefs defer_destroy].all? { |key| row.key?(key) }
  end
  roots.each { |root| raise ArgumentError, "root absent from scan: #{root}" unless rows.key?(root) }
  rows
end

writer = StorageInventory::Writer.new(options.fetch(:output),
  'kind' => 'zfs', 'started_at' => StorageInventory.now,
  'scope' => { 'roots' => roots }, 'host' => qualified_host, 'kernel_host' => kernel_host,
  'consistency' => 'two live scans; no atomic ZFS snapshot')
begin
  first = scan(options.fetch(:zfs), roots)
  first_finished = StorageInventory.now
  first.sort.each { |_name, row| writer.add('zfs_object', row) }
  second_started = StorageInventory.now
  second = scan(options.fetch(:zfs), roots)
  changes = (first.keys | second.keys).sort.filter_map do |name|
    next if first[name] == second[name]
    { 'name' => name, 'first' => first[name], 'second' => second[name] }
  end
  changes.each { |change| writer.add('scan_change', change) }
  writer.finish('first_scan_finished_at' => first_finished,
                'second_scan_started_at' => second_started,
                'second_scan_finished_at' => StorageInventory.now,
                'volatile' => !changes.empty?)
rescue StandardError
  writer.abort
  raise
end
