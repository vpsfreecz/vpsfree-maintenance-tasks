#!/usr/bin/env ruby

require 'json'

def check_reverse_record(ip, expected_ptr, dns_server)
  # Execute the dig command
  dig_command = "dig -x #{ip} @#{dns_server} +short"
  actual_ptr = `#{dig_command}`.strip
  exit_status = $?.exitstatus

  if exit_status == 0
    # Compare the dig output with the expected PTR record
    if actual_ptr == expected_ptr
      puts "IP: #{ip}, Expected PTR: #{expected_ptr}, Actual PTR: #{actual_ptr} - SUCCESS"
      return true
    else
      puts "IP: #{ip}, Expected PTR: #{expected_ptr}, Actual PTR: #{actual_ptr} - FAILURE"
      return false
    end
  else
    puts "IP: #{ip}, Error executing dig command: #{actual_ptr}"
    return false
  end
end

# Main script execution
if ARGV.length != 2
  puts "Usage: #{$0} <json_file> <dns_server>"
  exit 1
end

json_file = ARGV[0]
dns_server = ARGV[1]

unless File.exist?(json_file)
  puts "Error: File '#{json_file}' not found."
  exit 1
end

# Read and parse the JSON file
file_content = File.read(json_file)
data = JSON.parse(file_content)

# Counters for success and failure
success_count = 0
failure_count = 0

# Iterate over the records and check reverse records
data['records'].each do |record|
  ip = record['ip']
  expected_ptr = record['ptr']

  if record['imported'] === false
    puts "IP: #{ip}, not imported, skipping"
    next
  end

  if check_reverse_record(ip, expected_ptr, dns_server)
    success_count += 1
  else
    failure_count += 1
  end
end

# Report the totals
puts "\nTotal records checked: #{success_count + failure_count}"
puts "Successful records: #{success_count}"
puts "Failed records: #{failure_count}"

exit(failure_count == 0)