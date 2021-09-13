#!/usr/bin/env ruby
#
# List all VPS that have symlinks anywhere in the mountpoint path.
#
require_relative '/opt/vpsadmin/vpsadmind/lib/vpsadmind/standalone'
require 'pathname'

include VpsAdmind::Utils::System
include VpsAdmind::Utils::Vz
include VpsAdmind::Utils::Vps
include VpsAdmind::Utils::Log

vpses = syscmd('vzlist -aH -oveid')[:output].split.map(&:strip)

vpses.each do |vps|
  begin
    load "/var/vpsadmin/mounts/#{vps}.mounts"
  rescue LoadError
    next
  end

  links = {}

  MOUNTS.each do |m|
    root = ve_private(vps)
    tmp = []

    Pathname.new(m['dst']).each_filename do |fn|
      tmp << fn
      abs = File.join(root, *tmp)

      if File.symlink?(abs)
        links[m['dst']] ||= []
        links[m['dst']] << File.join('/', abs)
      end
    end
  end
  
  if links.any?
    puts "VPS #{vps}"
    
    links.each do |dst, links|
      puts "  mountpoint '#{m['dst']}':"
      links.each do |link|
        puts "    symlink '#{link}'"
      end
    end

    puts "---\n\n"
  end

  Object.send(:remove_const, :MOUNTS)
end
