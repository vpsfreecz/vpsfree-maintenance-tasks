#!/usr/bin/env ruby
# Remove network with all dependencies

Dir.chdir('/opt/vpsadmin/api')
require '/opt/vpsadmin/api/lib/vpsadmin'

NET_ID = ARGV[0].to_i


ActiveRecord::Base.transaction do
  net = ::Network.find(NET_ID)

  net.ip_addresses.each do |ip|
    if ip.network_interface_id
      fail "route #{ip.ip_addr} assigned to interface"
    elsif ip.user_id
      fail "route #{ip.ip_addr} belongs to a user"
    end

    ip.host_ip_addresses.each do |host|
      fail "host IP #{host.ip_addr} assigned to interface" if host.assigned?

      host.routed_via_addresses.each do |routed_via_host|
        if routed_via_host.network_id != net.id
          fail "route #{routed_via_host.ip_addr} routed via #{host.ip_addr}"
        end
      end

      puts "host #{host.ip_addr}"
      host.destroy!
    end

    ip.ip_recent_traffics.delete_all(:delete_all)
    ip.ip_traffics.delete_all(:delete_all)

    puts "route #{ip.ip_addr}"
    ip.destroy!
  end

  net.location_networks.each do |ln|
    puts "from location #{ln.location.label}"
    ln.destroy!
  end

  net.destroy!

  fail 'not yet bro'
end
