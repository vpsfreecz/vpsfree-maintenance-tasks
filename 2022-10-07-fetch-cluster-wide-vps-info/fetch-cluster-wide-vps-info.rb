#!/usr/bin/env ruby
# Fetch information about VPS on all nodes
#
# Run from confctl cluster configuration directory
require 'fileutils'
require 'json'

self_root = File.realpath(File.dirname(__FILE__))

if ARGV.length != 1
  warn "Usage: #{$0} <output directory>"
  exit(false)
end

output = File.absolute_path(ARGV[0])
puts "Saving output to #{output}"
FileUtils.mkdir_p(output)

os_nodes = `confctl ls -a node.role=hypervisor --managed y -H -o host.fqdn`.strip.split("\n")

vz_nodes = `confctl ls -a node.role=hypervisor --managed n -H -o host.fqdn`.strip.split("\n")

failed_nodes = []

{
  os_node: os_nodes,
  vz_node: vz_nodes,
}.each do |node_type, nodes|
  nodes.each_with_index do |n, i|
    puts "[#{i+1}/#{nodes.length}] Fetching info from #{n}"
    vpses = nil

    json = `cat #{File.join(self_root, "#{node_type}.rb")} | ssh -T -l root #{n} ruby`
    if $?.exitstatus != 0
      puts "  ! failed to fetch VPS info"
      failed_nodes << n
      next
    end

    vpses = JSON.parse(json)

    vpses.each do |vps|
      puts "  > Processed VPS #{vps['id']}"
      vps_out = File.join(output, vps['id'])
      FileUtils.mkdir_p(vps_out)

      %w(platform distribution version os_release).each do |v|
        next if vps[v].nil?

        File.write(File.join(vps_out, v), vps[v])
      end
    end
  end
end

if failed_nodes.any?
  puts "Unable to fetch info from the following nodes:"
  failed_nodes.each do |n|
    puts "  #{n}"
  end
end
