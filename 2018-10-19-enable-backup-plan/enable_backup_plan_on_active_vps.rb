#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Enable dataset plan on datasets of active VPS on the selected pool.

POOL_ID = 13
PLAN = :daily_backup

require 'vpsadmin'

::DatasetInPool.where(pool_id: POOL_ID).each do |dip|
  dip_fs = "#{dip.pool.filesystem}/#{dip.dataset.full_name}"

  begin
    root_dip = dip.dataset.root.dataset_in_pools.find_by!(pool_id: POOL_ID)
  rescue ActiveRecord::RecordNotFound
    puts "Unable to find root dataset in pool for #{dip_fs}"
    next
  end

  begin
    vps = ::Vps.find_by!(dataset_in_pool: root_dip)
  rescue ActiveRecord::RecordNotFound
    puts "Unable to find VPS for root dataset in pool #{root_dip.id}"
    next
  end

  unless %w(active suspended).include?(vps.object_state)
    puts "Ignoring dataset ##{dip.id} of soft-deleted VPS #{vps.id}"
    next
  end

  plan = dip.dataset_in_pool_plans.joins(environment_dataset_plan: :dataset_plan).where(
    dataset_plans: {name: PLAN.to_s},
  )
  
  if plan.exists?
    puts "Exists #{dip.pool.node.domain_name}:#{dip_fs}"
    next
  end

  puts "Register #{dip.pool.node.domain_name}:#{dip_fs}"
  VpsAdmin::API::DatasetPlans.plans[PLAN].register(dip)
end
