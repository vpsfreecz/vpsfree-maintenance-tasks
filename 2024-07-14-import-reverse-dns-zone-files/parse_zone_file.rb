#!/usr/bin/env ruby
require 'ipaddr'
require 'json'

# Function to parse the IP address from the zone file name and record name
def parse_ip(zone_file_name, record_name)
  base_name = File.basename(zone_file_name)

  base_name = base_name[5..] if base_name.start_with?('zone.')

  if base_name.include?('in-addr.arpa')
    # IPv4 reverse zone
    network_part = base_name.split('.')[0..-3].reverse.join('.')
    "#{network_part}.#{record_name}"
  elsif base_name.include?('ip6.arpa')
    # IPv6 reverse zone
    IPAddr.new("#{record_name}.#{base_name}".split('.')[0..-3].reverse.each_slice(4).map(&:join).join(':')).to_s
  else
    raise "Unknown zone file format"
  end
end

# Function to parse the zone file and extract reverse records
def parse_zone_file(zone_file_name)
  reverse_records = []

  File.open(zone_file_name, 'r') do |file|
    file.each_line do |line|
      next if line.strip.empty? || line.strip.start_with?(';')

      fields = line.strip.split(/\s+/)

      # Skip lines that don't have exactly four fields
      next unless fields.length == 4

      record_name = fields[0]
      record_class = fields[1]
      record_type = fields[2]
      record_value = fields[3]

      # We are interested in PTR records only
      next unless record_class == 'IN' && record_type == 'PTR'

      # Construct the IP address
      ip_address = parse_ip(zone_file_name, record_name)

      # Add the IP address and its corresponding PTR value to the list
      reverse_records << { ip: ip_address, ptr: record_value }
    end
  end

  reverse_records
end

# Main script execution
if ARGV.length != 2
  puts "Usage: #{$0} <zone_file_name> <output_file_name>"
  exit 1
end

zone_file_name = ARGV[0]
output_file_name = ARGV[1]

unless File.exist?(zone_file_name)
  puts "Error: File '#{zone_file_name}' not found."
  exit 1
end

reverse_records = parse_zone_file(zone_file_name)

puts "IP Addresses and Reverse Record Values:"
reverse_records.each do |record|
  puts "IP: #{record[:ip]}, PTR: #{record[:ptr]}"
end

File.write(output_file_name, JSON.pretty_generate(records: reverse_records))