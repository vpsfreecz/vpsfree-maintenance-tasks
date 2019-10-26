#!/usr/bin/env ruby
# Finds NFS over UDP mounts and replaces them with TCP mounts in place.

require_relative '/opt/vpsadmin/vpsadmind/lib/vpsadmind/standalone'
require 'pp'

include VpsAdmind::Utils::Log
include VpsAdmind::Utils::System
include VpsAdmind::Utils::Vz

syscmd('vzlist -Ha -o veid,status')[:output].split("\n").map(&:strip).each do |line|
  veid, status = line.split
  puts "VEID=#{veid} STATUS=#{status}"

  path = File.join('/var/vpsadmin/mounts', "#{veid}.mounts")
  unless File.exist?(path)
    puts "  no mounts found"
    next
  end

  load(path)

  new_mounts = []
  to_fix = []

  MOUNTS.each do |m|
    STDOUT.write("  mountpoint #{m['dst']}: ")

    if m['type'] != 'dataset_remote'
      STDOUT.write("not dataset_remote, ignoring")
    elsif m['mount_opts'].include?('-oproto=udp')
      STDOUT.write("replacing with TCP")
      m['mount_opts'].sub!('-oproto=udp', '-oproto=tcp')
      to_fix << m
    else
      STDOUT.write("already on TCP")
    end

    STDOUT.write("\n")
    new_mounts << m
  end

  if to_fix.any?
    puts "  going to replace:"
    to_fix.reverse_each do |m|
      puts "  umount #{m['dst']}"
    end
    to_fix.each do |m|
      puts "  mount #{m['dst']}"
    end

    STDOUT.write("Continue? [y/N]: ")
    STDOUT.flush
    next if STDIN.readline.strip != 'y'
    
    puts "  roger"
    puts "  replacing #{path}"

    File.open("#{path}.new", 'w') do |f|
      f.puts("MOUNTS = #{PP.pp(new_mounts, '').strip}")
    end

    File.rename(path, "#{path}.udp")
    File.rename("#{path}.new", path)

    if status == 'running'
      mounter = VpsAdmind::Mounter.new(veid)

      to_fix.reverse_each do |m|
        puts "  remounting #{m['dst']}"
        
        begin
          syscmd("umount -fl #{File.join("/vz/root", veid, m["dst"])}")

        rescue VpsAdmind::CommandFailed => e
          raise e if e.rc != 1 || /not mounted/ !~ e.output
        end
      end
        
      to_fix.each do |m|
        dst, cmd = mounter.mount_cmd(m)
        syscmd(cmd)
      end
    end
  end

  ::Object.send(:remove_const, :MOUNTS)
  puts "  done"
end
