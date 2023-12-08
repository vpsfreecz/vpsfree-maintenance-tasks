#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Create backup datasets on a new pool, a copy of the source pool
#
# Usage: $0 <src pool id> <dst pool id> [execute]
#

require 'vpsadmin'

module TransactionChains
  module Maintenance
    remove_const(:Custom)

    class Custom < TransactionChain
      label 'Create backups'

      def link_chain(src_pool_id, dst_pool_id, execute)
        src_pool = ::Pool.find(src_pool_id)
        dst_pool = ::Pool.find(dst_pool_id)

        src_pool.dataset_in_pools.includes(:dataset).each do |src_dip|
          dst_dip = ::DatasetInPool.create!(
            dataset: src_dip.dataset,
            pool: dst_pool,
            label: src_dip.label,
            min_snapshots: src_dip.min_snapshots,
            max_snapshots: src_dip.max_snapshots,
            snapshot_max_age: src_dip.snapshot_max_age,
          )

          puts "Creating #{dst_pool.node.domain_name}:#{File.join(dst_pool.filesystem, dst_dip.dataset.full_name)}"

          append_t(Transactions::Storage::CreateDataset, args: dst_dip) do |t|
            t.create(dst_dip)
          end
        end

        fail 'done' unless execute
      end
    end
  end
end

unless [2, 3].include?(ARGV.length)
  warn "Usage: #{$0} <src pool id> <dst pool id> [execute]"
  exit(false)
end

TransactionChains::Maintenance::Custom.fire(ARGV[0].to_i, ARGV[1].to_i, ARGV[2] == 'execute')
