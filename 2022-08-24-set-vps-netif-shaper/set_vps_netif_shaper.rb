#!/run/nodectl/nodectl script
# Set shaper on VPS network interfaces

require 'nodectld/standalone'

include OsCtl::Lib::Utils::Log
include NodeCtld::Utils::System
include NodeCtld::Utils::OsCtl

db = NodeCtld::Db.new

db.prepared(
  "SELECT v.id, netif.name, netif.max_tx, netif.max_rx
  FROM vpses v
  INNER JOIN network_interfaces netif ON v.id = netif.vps_id
  WHERE v.object_state < 2 AND v.node_id = ?",
  $CFG.get(:vpsadmin, :node_id)
).each do |row|
  puts "VPS #{row['id']}"

  begin
    osctl(
      %i(ct netif set),
      [row['id'], row['name']],
      {max_tx: row['max_tx'], max_rx: row['max_rx']}
    )
  rescue OsCtl::Lib::Exceptions::SystemCommandFailed
    puts "  -> failed, continue"
  end
end
