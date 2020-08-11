#!/run/nodectl/nodectl script
# Set memlock prlimit to unlimited
require 'nodectld/standalone'

include OsCtl::Lib::Utils::Log
include NodeCtld::Utils::System
include NodeCtld::Utils::OsCtl

db = NodeCtld::Db.new
db.prepared("
  SELECT v.id
  FROM vpses v
  WHERE
    v.object_state < 2
    AND v.node_id = ?
", $CFG.get(:vpsadmin, :node_id)).each do |row|
  puts "VPS #{row['id']}"
  #next

  begin
    osctl(
      %i(ct prlimits set),
      [row['id'], 'memlock', '65536', '9223372036854775807']
    )
  rescue OsCtl::Lib::Exceptions::SystemCommandFailed
    puts "  -> failed, continue"
  end
end
