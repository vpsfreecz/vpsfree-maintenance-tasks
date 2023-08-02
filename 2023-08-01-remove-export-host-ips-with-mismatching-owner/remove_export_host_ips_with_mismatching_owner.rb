#!/run/current-system/sw/bin/vpsadmin-api-ruby
require 'vpsadmin'

export_hosts = []

# IPs with owner
export_hosts.concat(
  ::ExportHost
    .joins(:export, :ip_address)
    .where('ip_addresses.user_id IS NOT NULL AND ip_addresses.user_id != exports.user_id')
)

# IPs assigned to VPS
export_hosts.concat(
  ::ExportHost
    .joins(:export, ip_address: {network_interface: :vps})
    .where('vpses.user_id != exports.user_id')
)

export_hosts.uniq! { |host| host.id }

export_hosts.each do |host|
  puts "Export #{host.export_id} user=#{host.export.user_id} host=#{host.id} ip=#{host.ip_address}"
end

STDOUT.write "Continue? [y/N]: "
STDOUT.flush

exit if STDIN.readline.strip.downcase != 'y'

hosts_per_export = {}

export_hosts.each do |host|
  hosts_per_export[ host.export ] ||= []
  hosts_per_export[ host.export ] << host
end

hosts_per_export.each do |export, hosts|
  TransactionChains::Export::DelHosts.fire(export, hosts)
end
