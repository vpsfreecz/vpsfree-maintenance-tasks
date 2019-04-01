#!/run/nodectl/nodectl script
# Add IP addresses to all local VPS configs on the current node.

require 'nodectld/standalone'
require 'ipaddress'

db = NodeCtld::Db.new
cfg = nil
vps_id = nil

db.prepared(
  'SELECT vpses.id AS vps_id, pools.filesystem, netifs.name AS netif,
          ips.ip_addr AS route_addr, ips.prefix AS route_prefix,
          ips.class_id, ips.max_tx, ips.max_rx,
          host.ip_addr AS route_via_addr
  FROM vpses
  INNER JOIN network_interfaces netifs ON netifs.vps_id = vpses.id
  LEFT JOIN ip_addresses ips ON ips.network_interface_id = netifs.id
  LEFT JOIN networks nets ON nets.id = ips.network_id
  LEFT JOIN host_ip_addresses host ON host.id = ips.route_via_id
  INNER JOIN dataset_in_pools dips ON dips.id = vpses.dataset_in_pool_id
  INNER JOIN pools ON pools.id = dips.pool_id
  WHERE vpses.object_state < 3 AND vpses.node_id = ?
  ORDER BY vpses.id, netifs.id, nets.ip_version, ips.order',
  $CFG.get(:vpsadmin, :node_id)
).each do |row|
  if cfg.nil? || vps_id != row['vps_id']
    cfg.save if cfg
    cfg = NodeCtld::VpsConfig.open(row['filesystem'], row['vps_id'])
    vps_id = row['vps_id']
    puts "VPS #{vps_id}"
  end

  unless cfg.network_interfaces.detect { |n| n.name == row['netif'] }
    puts " > #{row['netif']}"
    cfg.network_interfaces << NodeCtld::VpsConfig::NetworkInterface.new(row['netif'])
  end

  # The VPS may not have any IP addresses
  next unless row['route_addr']

  netif = cfg.network_interfaces[row['netif']]
  addr = IPAddress.parse("#{row['route_addr']}/#{row['route_prefix']}")

  if netif.has_route_for?(addr)
    puts " found #{row['route_addr']}/#{row['route_prefix']}"
  else
    puts " added #{row['route_addr']}/#{row['route_prefix']}"
    netif.add_route(NodeCtld::VpsConfig::Route.new(
      addr,
      row['route_via_addr'],
      row['class_id'],
      row['max_tx'],
      row['max_rx'],
    ))
  end
end

cfg.save if cfg
