#!/run/nodectl/nodectl script

require 'nodectld/standalone'

include OsCtl::Lib::Utils::Log
include NodeCtld::Utils::System
include NodeCtld::Utils::OsCtl

FILES = {
  'alpine' => '/etc/init.d/cgroups-mount',
  'devuan' => '/etc/init.d/cgroups-mount',
  'slackware' => '/etc/rc.d/rc.vpsadminos.cgroups',
  'void' => '/etc/runit/core-services/10-vpsadminos-cgroups.sh',
}.map do |k, v|
  [k, v, File.read(File.join(__dir__, 'scripts', k))]
end

db = NodeCtld::Db.new

db.prepared(
  "SELECT vpses.id, tpl.distribution, p.filesystem, ds.full_name
  FROM vpses
  INNER JOIN os_templates tpl ON tpl.id = vpses.os_template_id
  INNER JOIN dataset_in_pools dips ON dips.id = vpses.dataset_in_pool_id
  INNER JOIN datasets ds ON ds.id = dips.dataset_id
  INNER JOIN pools p ON p.id = dips.pool_id
  WHERE vpses.object_state < 2 AND vpses.node_id = ? AND vpses.allow_admin_modifications = 1
  AND tpl.distribution IN ('alpine', 'devuan', 'slackware', 'void')",
  $CFG.get(:vpsadmin, :node_id)
).each do |row|
  puts "VPS #{row['id']} - #{row['distribution']}"

  begin
    osctl(%i(ct mount), [row['id']])
  rescue OsCtl::Lib::Exceptions::SystemCommandFailed
    puts "  -> failed to mount"
    next
  end

  script = FILES.detect { |dist, _, _| dist == row['distribution'] }

  if script.nil?
    puts "  -> script not found for #{row['distribution'].inspect}"
    next
  end

  _, path, content = script

  rootfs = File.join('/', row['filesystem'], row['full_name'], 'private')

  pid = Process.fork do
    sys = OsCtl::Lib::Sys.new
    sys.chroot(rootfs)

    File.open(path, 'w') do |f|
      f.write(content)
    end
  end

  Process.wait(pid)

  if $?.exitstatus != 0
    puts "  -> failed with exit status #{$?.exitstatus}"
    next
  end
end
