#!/run/current-system/sw/bin/vpsadmin-api-ruby
require 'vpsadmin'

class DeleteBackupPool
  POOL_ID = 14
  EXECUTE = false

  class Node < ::ActiveRecord::Base
    has_many :pools
  end

  class Dataset < ::ActiveRecord::Base
    has_many :dataset_in_pools
    has_many :snapshots
  end
  
  class Pool < ::ActiveRecord::Base
    belongs_to :node
    has_many :dataset_in_pools
  end

  class DatasetInPool < ::ActiveRecord::Base
    belongs_to :dataset
    belongs_to :pool
    has_many :dataset_trees
    has_many :snapshot_in_pools
  end

  class SnapshotInPool < ::ActiveRecord::Base
    belongs_to :dataset_in_pool
    belongs_to :snapshot
    has_many :snapshot_in_pool_in_branches
  end

  class Snapshot < ::ActiveRecord::Base
    has_many :snapshot_in_pools
  end

  class DatasetTree < ::ActiveRecord::Base
    belongs_to :dataset_in_pool
    has_many :branches
  end

  class Branch < ::ActiveRecord::Base
    belongs_to :dataset_tree
    has_many :snapshot_in_pool_in_branches
  end

  class SnapshotInPoolInBranch < ::ActiveRecord::Base
    belongs_to :snapshot_in_pool
    belongs_to :branch
  end

  def run
    q = DatasetInPool.where(pool_id: POOL_ID)

    # q = q.where(dataset_id: 123)

    q.each do |dip|
      puts "dip id=#{dip.id} name=#{dip.dataset.full_name} on #{dip.pool.node.name}"

      dip.dataset_trees.each do |tree|
        puts "  tree #{tree.id}"

        tree.branches.each do |branch|
          puts "  branch #{branch.id}"
          
          branch.snapshot_in_pool_in_branches.each do |sipb|
            puts "    sipb #{sipb.id}"
            sipb.destroy! if EXECUTE
          end
          
          branch.destroy! if EXECUTE
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

      dip.destroy!

      puts
    end
  end
end

DeleteBackupPool.new.run
