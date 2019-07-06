#!/run/nodectl/nodectl script
# Set canmount=noauto for all hypervisor/backup pools on this node

require 'libosctl'
require 'nodectld/standalone'

include OsCtl::Lib::Utils::Log
include NodeCtld::Utils::System

db = NodeCtld::Db.new

db.prepared(
  'SELECT p.filesystem, ds.full_name,
          tr.index AS tree_index, br.name AS branch_name, br.index AS branch_index
  FROM dataset_in_pools dip
  INNER JOIN pools p ON p.id = dip.pool_id
  INNER JOIN datasets ds ON ds.id = dip.dataset_id
  LEFT JOIN dataset_trees tr ON tr.dataset_in_pool_id = dip.id
  LEFT JOIN branches br ON br.dataset_tree_id = tr.id
  WHERE p.node_id = ? AND p.role IN (0, 2)
  ORDER BY p.filesystem, ds.full_name',
  $CFG.get(:vpsadmin, :node_id)
).each do |row|
  ds = File.join(row['filesystem'], row['full_name'])
  ds = File.join(ds, "tree.#{row['tree_index']}") if row['tree_index']
  if row['branch_name']
    ds = File.join(ds, "branch-#{row['branch_name']}.#{row['branch_index']}")
  end

  rc = zfs(:set, 'canmount=noauto', ds, valid_rcs: [1])
  log("unable to set #{ds}") if rc.exitstatus != 0
end
