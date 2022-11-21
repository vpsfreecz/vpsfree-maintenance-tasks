#!/usr/bin/env ruby
# Change cpuset configuration of containers on a specific CPU package
#
require 'json'

class ReconfigureCpuset
  CPUSET_ROOT = '/sys/fs/cgroup/cpuset'

  def initialize(pkg_id, new_cpuset, execute)
    @pkg_id = pkg_id
    @new_cpuset = new_cpuset
    @execute = execute
  end

  def run
    cts = JSON.parse(`osctl -j ct ls -S running`, symbolize_names: true)

    cts.each do |ct|
      next if ct[:cpu_package_inuse] != @pkg_id

      puts "CT #{ct[:id]} on CPU package #{ct[:cpu_package_inuse]}"

      cg_user_owned = File.join(CPUSET_ROOT, ct[:group_path])
      cg_ct = File.realpath(File.join(cg_user_owned, '..'))

      unless configure_cgroup_recursive(cg_ct)
        puts "  > failed to reconfigure CT #{ct[:id]}"
      end
    end
  end

  protected
  def configure_cgroup_recursive(cg_path)
    begin
      entries = Dir.entries(cg_path)
    rescue Errno::ENOENT
      return false
    end
      
    entries.each do |f|
      next if %w(. ..).include?(f)
      
      f_path = File.join(cg_path, f)
      next unless Dir.exist?(f_path)

      configure_cgroup_recursive(f_path)  
    end

    puts "  > #{cg_path}"
    ret = true

    if @execute
      begin
        File.write(File.join(cg_path, 'cpuset.cpus'), @new_cpuset)
      rescue Errno::ENOENT
        # pass
      rescue SystemCallError => e
        puts "  > #{e.message} (#{e.class})"
        ret = false
      end
    end

    ret
  end
end

if ARGV.size != 2 && ARGV.size != 3
  warn "Usage: #{$0} <cpu-package> <new-cpuset> execute"
  exit(false)
end

pkg_id = ARGV[0].to_i
new_cpuset = ARGV[1]
execute = ARGV[2] == 'execute'

reconf = ReconfigureCpuset.new(pkg_id, new_cpuset, execute)
reconf.run
