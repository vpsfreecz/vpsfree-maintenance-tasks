#!/run/nodectl/nodectl script
# Remove AppArmor control directory mounts (apparmor_dirs feature)

require 'nodectld/standalone'

include OsCtl::Lib::Utils::Log
include NodeCtld::Utils::System
include NodeCtld::Utils::OsCtl

db = NodeCtld::Db.new
rs = db.prepared(
  "SELECT vpses.id
  FROM vpses INNER JOIN vps_features ON vpses.id = vps_features.vps_id
  WHERE
    vpses.node_id = ?
    AND vpses.object_state < 3
    AND vps_features.name = 'apparmor_dirs'
    AND vps_features.enabled = 0",
  $CFG.get(:vpsadmin, :node_id)
)

rs.each do |row|
  vps_id = row['vps_id']

  puts "VPS #{vps_id}"

  osctl(%i[ct mounts del], [vps_id, '/sys/kernel/security'], {}, {}, valid_rcs: [1])
  osctl(%i[ct mounts del], [vps_id, '/sys/module/apparmor'], {}, {}, valid_rcs: [1])
end