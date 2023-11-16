#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Switch backup datasets actions to a new backup pool
#
# Usage: $0 <src pool id> <dst pool id> [execute]
#

require 'vpsadmin'

src_pool_id = ARGV[0].to_i
dst_pool_id = ARGV[1].to_i
execute = ARGV[2] == 'execute'

ActiveRecord::Base.transaction do
  ::DatasetAction
    .joins(:dst_dataset_in_pool)
    .where(action: 'backup')
    .where(dataset_in_pools: {pool_id: src_pool_id})
    .each do |action|
    new_dst_dip = action
      .dst_dataset_in_pool
      .dataset
      .dataset_in_pools
      .where(pool_id: dst_pool_id)
      .take!

    puts "Action ##{action.id}: #{action.dst_dataset_in_pool_id} => #{new_dst_dip.id}"

    if execute
      action.update!(dst_dataset_in_pool: new_dst_dip)
    end
  end
end
