#!/usr/bin/env ruby
# <description>
#
# Usage:
#

ENV['RACK_ENV'] = 'production'

orig_pwd = Dir.pwd
Dir.chdir('/opt/vpsadmin/api')

require '/opt/vpsadmin/api/lib/vpsadmin'

if ARGV.length != 3
  fail "usage: #{$0} vz_to_vz|os_to_os src_node_id dst_node_id"
end

type = ARGV[0]
src_node = ::Node.find(ARGV[1].to_i)
dst_node = ::Node.find(ARGV[2].to_i)

puts "ok so #{type} migrating #{src_node.domain_name} -> #{dst_node.domain_name}"
puts
puts "continue? [y/N]"
fail 'abort!' if STDIN.readline.strip.downcase != 'y'

vpses = []

::Vps.where(object_state: [
  ::Vps.object_states[:active],
  ::Vps.object_states[:suspended],
], node: src_node).each do |vps|
  vpses << vps
end

vps_count = vpses.count

puts "thats #{vps_count} vpses all in all, starting in.."
puts
puts "continue? [y/N]"
fail 'abort!' if STDIN.readline.strip.downcase != 'y'

vpses.each_with_index do |vps, j|
  puts "[#{j}/#{vps_count}] ok so scheduling vps #{vps.id} to #{dst_node.domain_name}"
 
  okay = Kernel.system("ruby #{orig_pwd}/migrate_#{type}_using_backup.rb #{vps.id} #{dst_node.id}")

  if okay
    puts "[#{j}/#{vps_count}] ok so vps #{vps.id} is on the way"
  else
    puts "[#{j}/#{vps_count}] well vps #{vps.id} didn't make it"
  end

  loop do
    puts "write y to migrate another one!"
    break if STDIN.readline.strip.downcase == 'y'
  end
end

puts "we done my man"
