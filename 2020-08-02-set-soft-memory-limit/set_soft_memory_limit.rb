#!/run/nodectl/nodectl script
# Set memory.soft_limit_in_bytes on all VPS to 80% of configured memory limit
require 'nodectld/standalone'

include OsCtl::Lib::Utils::Log
include NodeCtld::Utils::System
include NodeCtld::Utils::OsCtl

db = NodeCtld::Db.new
db.prepared("
  SELECT v.id, cru.value AS memory
  FROM vpses v
  INNER JOIN cluster_resource_uses cru ON cru.row_id = v.id
  INNER JOIN user_cluster_resources ucr ON ucr.id = cru.user_cluster_resource_id
  INNER JOIN cluster_resources cr ON cr.id = ucr.cluster_resource_id
  WHERE
    cru.class_name = 'Vps'
    AND cr.name = 'Memory'
    AND v.object_state < 2
    AND v.node_id = ?
", $CFG.get(:vpsadmin, :node_id)).each do |row|
  hard_limit_m = row['memory'].to_i
  hard_limit_b = hard_limit_m * 1024 * 1024
  soft_limit = (hard_limit_m * 0.8 * 1024 * 1024).round

  puts "VPS #{row['id']}"
  puts "  hard = #{hard_limit_m}M #{hard_limit_b}"
  puts "  soft = #{soft_limit / 1024 / 1024}M #{soft_limit}"
  puts
  #next

  begin
    osctl(
      %i(ct cgparams set),
      [row['id'], 'memory.soft_limit_in_bytes', soft_limit]
    )
  rescue OsCtl::Lib::Exceptions::SystemCommandFailed
    puts "  -> failed, continue"
  end
end
