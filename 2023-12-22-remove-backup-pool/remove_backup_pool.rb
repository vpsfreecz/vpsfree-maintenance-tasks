#!/run/current-system/sw/bin/vpsadmin-api-ruby
require 'vpsadmin'

POOL_ID = 14
EXECUTE = false

q = ::DatasetInPool.where(pool_id: POOL_ID)

# q = q.where(id: 123)

q.each do |dip|
  puts "dip id=#{dip.id} name=#{dip.dataset.full_name} on #{dip.pool.node.domain_name}"

  dip.dataset_trees.each do |tree|
    puts "  tree #{tree.id}"

    tree.branches.each do |branch|
      puts "  branch #{branch.id}"
      
      if EXECUTE
        branch.snapshot_in_pool_in_branches.delete_all
        branch.destroy!
      end
    end

    tree.destroy! if EXECUTE
  end

  dip.snapshot_in_pools.each do |sip|
    snap = sip.snapshot

    puts "  sip id=#{sip.id} name=#{sip.snapshot.name}"
    sip.destroy! if EXECUTE

    if snap.snapshot_in_pools.count <= 0
      puts "  snap id=#{snap.id}"
      snap.destroy! if EXECUTE
    end
  end

  puts
end
