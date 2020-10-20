#!/run/nodectl/nodectl script
# Ensure /var/log/journal exists
#
require 'nodectld/standalone'

include OsCtl::Lib::Utils::Log
include NodeCtld::Utils::System
include NodeCtld::Utils::OsCtl

cts = osctl_parse(%i(ct ls))
distros = %w(arch centos debian fedora opensuse ubuntu)
error = skipped = fixed = ok = 0

db = NodeCtld::Db.new
db.prepared("
  SELECT v.id
  FROM vpses v
  WHERE
    v.object_state < 3
    AND v.node_id = ?
", $CFG.get(:vpsadmin, :node_id)).each do |row|
  ct = cts.detect { |v| v[:id].to_i == row['id'] }
  if ct.nil?
    puts "VPS #{row['id']}: container not found"
    error += 1
    next
  end

  unless distros.include?(ct[:distribution])
    puts "VPS #{row['id']}: not affected"
    skipped += 1
    next
  end

  if ct[:state] != 'running'
    osctl(%i(ct mount), row['id'])
  end

  rootfs = ct[:rootfs]
  unless Dir.exist?(rootfs)
    puts "VPS #{row['id']}: rootfs not found"
    error += 1
    next
  end

  journal = File.join(rootfs, 'var/log/journal')
  
  if Dir.exist?(journal)
    puts "VPS #{row['id']}: ok"
    ok += 1
  else
    puts "VPS #{row['id']}: fixing"
    Dir.mkdir(journal)
    fixed += 1
  end
end

puts "ok #{ok}"
puts "fixed #{fixed}"
puts "skipped #{skipped}"
puts "error #{error}"
