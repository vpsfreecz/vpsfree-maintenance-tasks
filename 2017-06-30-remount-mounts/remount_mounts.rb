#!/usr/bin/env ruby
# Remounts all mounts on a single node. Prior to running this script, it is
# necessary to either edit /var/vpsadmin/mounts/*.mounts files to change
# selected parameters or patch vpsAdmind to add different mount options,
# e.g. -oproto=udp/tcp.
#
# Usage:
#   ruby remount_mounts.rb
#
# TODO:
#   - remount only remote mounts, currently bind mounts are remounted as well

require_relative '/opt/vpsadmind/lib/vpsadmind/standalone'

include VpsAdmind::Utils::System
include VpsAdmind::Utils::Vz
include VpsAdmind::Utils::Log

vpses = syscmd('vzlist -H -oveid')[:output].split.map(&:strip)

vpses.each do |vps|
  puts "VPS #{vps}"

  begin
    load "/var/vpsadmin/mounts/#{vps}.mounts"

  rescue LoadError
    puts "  skip"
    next
  end

  mounter = VpsAdmind::Mounter.new(vps)
  
  MOUNTS.each do |m|
    begin
      syscmd("umount -fl #{File.join("/vz/root", vps, m["dst"])}")

    rescue VpsAdmind::CommandFailed => e
      raise e if e.rc != 1 || /not mounted/ !~ e.output
    end

    dst, cmd = mounter.mount_cmd(m)
    
    syscmd(cmd)
  end
  
  puts "---\n"
  sleep(1)
end
