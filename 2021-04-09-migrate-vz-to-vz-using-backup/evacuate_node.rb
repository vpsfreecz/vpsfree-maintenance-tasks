#!/usr/bin/env ruby
# <description>
#
# Usage:
#

ENV['RACK_ENV'] = 'production'

orig_pwd = Dir.pwd
Dir.chdir('/opt/vpsadmin/api')

require '/opt/vpsadmin/api/lib/vpsadmin'
require 'thread'

if ARGV.length != 2
  fail "usage: #{$0} src_node_id dst_node_id"
end

src_node = ::Node.find(ARGV[0].to_i)
dst_node = ::Node.find(ARGV[1].to_i)

puts "ok so migrating #{src_node.domain_name} -> #{dst_node.domain_name}"
puts
puts "continue? [y/N]"
fail 'abort!' if STDIN.readline.strip.downcase != 'y'

num_threads = 6
queue = Queue.new
vpses = []

::Vps.where(object_state: ::Vps.object_states[:active], node: src_node).each do |vps|
  vpses << vps
end

vpses.sort! { |a, b| a.used_diskspace <=> b.used_diskspace }

vpses.each_with_index do |vps, i|
  puts "enqueueing vps #{vps.id} #{vps.hostname} (#{vps.used_diskspace}MB) from #{vps.node.domain_name}"

  queue << [i+1, vps]
end

vps_count = queue.size

puts "thats #{vps_count} vpses all in all, starting in.."
puts
puts "continue? [y/N]"
fail 'abort!' if STDIN.readline.strip.downcase != 'y'

threads = []

num_threads.times do
  threads << Thread.new do
    loop do
      begin
        j, vps = queue.pop(true)
      rescue ThreadError
        break
      end

      puts "[#{j}/#{vps_count}] ok so scheduling vps #{vps.id} to #{dst_node.domain_name}"

      5.times do |i|
        puts "#{5-i}..."
        sleep(1)
      end

      sleep(Random.rand(15))
      
      okay = Kernel.system("ruby #{orig_pwd}/migrate_vz_to_vz_using_backup.rb #{vps.id} #{dst_node.id}")
      #okay = true
      #sleep(3)

      if okay
        puts "[#{j}/#{vps_count}] ok so vps #{vps.id} is there mate"
      else
        puts "[#{j}/#{vps_count}] well vps #{vps.id} didn't make it"
      end
    end
  end
end

threads.each(&:join)
puts "we done my man"
