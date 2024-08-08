#!/run/nodectl/nodectl script
# Saves zones on this node to an updated location (zone_source in path is replace with zone_type)
require 'nodectld/standalone'
require 'json'
require 'libosctl'

include OsCtl::Lib::Utils::File

ZONE_SOURCES = %w[internal_source external_source]
ZONE_TYPES = %w[primary_type secondary_type]

config_root = $CFG.get(:dns_server, :config_root)
db_file = "#{config_root}.json"

zone_db = JSON.parse(File.read(db_file))['zones']

db = NodeCtld::Db.new
db.prepared('
  SELECT dns_zones.name, dns_zones.zone_source, dns_server_zones.zone_type
  FROM dns_server_zones
  INNER JOIN dns_servers ds ON dns_servers.id = dns_server_zones.dns_server_id
  INNER JOIN dns_zones ON dns_zones.id = dns_server_zones.dns_zone_id
  WHERE dns_servers.node_id = ?
', $CFG.get(:vpsadmin, :node_id)).each do |dsz|
  puts "DNS zone #{row['name']}"

  source = ZONE_SOURCES[row['zone_source']]
  type = ZONE_TYPES[row['zone_type']]

  puts "  -> #{type}"

  zone = NodeCtld::DnsServerZone.new(name: row['name'], source:, type:)
  zone.save

  zone_db[zone.name]['type'] = type
end

# Save updated db
regenerate_file(db_file, 0o644) do |f|
  f.puts(JSON.pretty_generate({ zones: zone_db }))
end

# Update named.conf from updated db
NodeCtld::DnsConfig.instance.send(:save)
