#!/usr/bin/env ruby
# Mark ::0 IPv6 addresses from selected network as not to be used automatically
# and add ::1 addresses instead.
#

Dir.chdir('/opt/vpsadmin/api')
require '/opt/vpsadmin/api/lib/vpsadmin'

NETWORK = 22

ActiveRecord::Base.transaction do
  ::HostIpAddress.joins(:ip_address).where(
    ip_addresses: {network_id: NETWORK}
  ).update_all(auto_add: false)

  ::IpAddress.where(network_id: NETWORK).each do |ip|
    addr = ip.to_ip.take(2).last.to_s
    puts "Add #{addr}"

    next

    ::HostIpAddress.create!(
      ip_address: ip,
      ip_addr: addr,
      order: nil,
    )
  end

  fail 'not yet!'
end
