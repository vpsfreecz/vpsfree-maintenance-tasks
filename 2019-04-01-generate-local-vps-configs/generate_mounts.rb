#!/run/nodectl/nodectl script
# Add mounts to all local VPS configs on the current node.

require 'nodectld/standalone'
require 'yaml'

db = NodeCtld::Db.new
db.prepared(
  'SELECT filesystem FROM pools WHERE role = 0 AND node_id = ?',
  $CFG.get(:vpsadmin, :node_id)
).each do |row|
  pool_fs = row['filesystem']

  Dir.glob(File.join('/', pool_fs, 'vpsadmin', 'config', 'mounts', '*.yml')).each do |f|
    next if /\/(\d+)\.yml$/ !~ f
    vps_id = $1.to_i
    mounts = YAML.load_file(f)

    puts "VPS #{vps_id}"

    NodeCtld::VpsConfig.edit(pool_fs, vps_id) do |cfg|
      cfg.mounts = mounts.map do |v|
        puts " > #{v['dst']}"
        NodeCtld::VpsConfig::Mount.load(v)
      end
    end
  end
end
