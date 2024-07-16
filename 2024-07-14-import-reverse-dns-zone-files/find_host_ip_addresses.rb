#!/run/current-system/sw/bin/vpsadmin-api-ruby
require 'vpsadmin'

if ARGV.length != 1
  fail "Usage: #{$0} <input json file>"
end

records = JSON.parse(File.read(ARGV[0]))['records']

records.each do |r|
  next if ::HostIpAddress.find_by(ip_addr: r['ip'])

  addr = IPAddress.parse(r['ip'])
  ip_v = addr.ipv4? ? 4 : 6

  network = ::Network.where(ip_version: ip_v).detect { |n| n.include?(r['ip']) }

  if network.nil?
    puts "WTF: network for #{r['ip']} not found"
    next
  end

  ip = network.ip_addresses.detect { |ip| ip.include?(r['ip']) }

  if ip
    puts "missing host IP: #{r['ip']} -- could be added"
  else
    puts "WTF: IP address for #{r['ip']} not found"
  end
end
