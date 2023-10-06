#!/run/nodectl/nodectl script
# Set cgroups v2 parameters on all VPS
require 'nodectld/standalone'

include OsCtl::Lib::Utils::Log
include NodeCtld::Utils::System
include NodeCtld::Utils::OsCtl

db = NodeCtld::Db.new
db.prepared("
  SELECT v.id, cr.name, cru.value
  FROM vpses v
  INNER JOIN cluster_resource_uses cru ON cru.row_id = v.id
  INNER JOIN user_cluster_resources ucr ON ucr.id = cru.user_cluster_resource_id
  INNER JOIN cluster_resources cr ON cr.id = ucr.cluster_resource_id
  WHERE
    cru.class_name = 'Vps'
    AND cr.name IN ('memory', 'cpu')
    AND v.object_state < 2
    AND v.node_id = ?
  ORDER BY v.id
", $CFG.get(:vpsadmin, :node_id)).each do |row|

  if row['name'] == 'cpu'
    cpu_max = "#{row['value'].to_i * 100000} 100000"
    puts "VPS #{row['id']}"
    puts "  cpu.max=#{cpu_max}"
    puts

    begin
      osctl(
        %i(ct cgparams set),
        [row['id'], 'cpu.max', "\"#{cpu_max}\""],
        {version: '2'},
      )
    rescue OsCtl::Lib::Exceptions::SystemCommandFailed
      puts "  -> failed, continue"
    end

  elsif row['name'] == 'memory'
    hard_limit_m = row['value'].to_i
    hard_limit_b = hard_limit_m * 1024 * 1024
    soft_limit = (hard_limit_m * 0.8 * 1024 * 1024).round

    puts "VPS #{row['id']}:"
    puts "  memory.max      = #{hard_limit_b} (#{hard_limit_m}M)"
    puts "  memory.swap.max = 0"
    puts "  memory.low      = #{soft_limit} (#{soft_limit / 1024 / 1024}M)"
    puts

    begin
      osctl(
        %i(ct cgparams set),
        [row['id'], 'memory.max', hard_limit_b],
        {version: '2'},
      )
    rescue OsCtl::Lib::Exceptions::SystemCommandFailed
      puts "  -> failed, continue"
    end

    begin
      osctl(
        %i(ct cgparams set),
        [row['id'], 'memory.swap.max', 0],
        {version: '2'},
      )
    rescue OsCtl::Lib::Exceptions::SystemCommandFailed
      puts "  -> failed, continue"
    end

    begin
      osctl(
        %i(ct cgparams set),
        [row['id'], 'memory.low', soft_limit],
        {version: '2'},
      )
    rescue OsCtl::Lib::Exceptions::SystemCommandFailed
      puts "  -> failed, continue"
    end
  end
end
