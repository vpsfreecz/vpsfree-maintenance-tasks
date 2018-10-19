#!/usr/bin/env ruby
# Enable dataset plan on datasets on selected pool.

POOL_ID = 26
PLAN = :daily_backup

Dir.chdir('/opt/vpsadmin/api')
require '/opt/vpsadmin/api/lib/vpsadmin'

::DatasetInPool.where(pool_id: POOL_ID).each do |dip|
  plan = dip.dataset_in_pool_plans.joins(environment_dataset_plan: :dataset_plan).where(
    dataset_plans: {name: PLAN.to_s},
  )
  
  if plan.exists?
    puts "Exists #{dip.pool.node.domain_name}:#{dip.pool.filesystem}/#{dip.dataset.full_name}"
    next
  end

  puts "Register #{dip.pool.node.domain_name}:#{dip.pool.filesystem}/#{dip.dataset.full_name}"
  VpsAdmin::API::DatasetPlans.plans[PLAN].register(dip)
end
