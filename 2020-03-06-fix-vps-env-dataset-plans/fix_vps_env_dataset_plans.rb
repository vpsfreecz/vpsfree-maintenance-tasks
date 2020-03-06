#!/usr/bin/env ruby
# Fix incorrect assignments of dataset in pool plans from mismatching
# environments, which was caused by a vpsAdmin bug, it should be fixed
# by deaa68638848734103c64ca83ec610141ea6d29f.
#
# Usage:
#  ruby fix_vps_env_dataset_plans.rb
#  the script generates two files: upgrade.sql and rollback.sql, use
#  those to make changes in the database

pwd = Dir.pwd
Dir.chdir('/opt/vpsadmin/api')
require '/opt/vpsadmin/api/lib/vpsadmin'

vps_broken = 0
vps_ok = 0

env_plans = {}
::EnvironmentDatasetPlan.all.each do |edp|
  if env_plans.has_key?(edp.environment_id)
    fail "env #{edp.environment_id} has multiple plans, not supported"
  end

  env_plans[edp.environment_id] = edp
end

if File.exist?("#{pwd}/upgrade.sql") || File.exist?("#{pwd}/rollback.sql")
  fail 'sql file exist'
end

upgrade = File.open("#{pwd}/upgrade.sql", 'w')
rollback = File.open("#{pwd}/rollback.sql", 'w')

::Vps.where(object_state: [
  Vps.object_states[:active],
  Vps.object_states[:suspended],
  Vps.object_states[:soft_delete],
]).each do |vps|
  vps_env = vps.node.location.environment
  dips = []
  broken_dip_plans = []

  vps.dataset_in_pool.dataset.subtree.each do |ds|
    begin
      dips << ds.primary_dataset_in_pool!
    rescue ActiveRecord::RecordNotFound
      next
    end
  end

  dips.each do |dip|
    dip.dataset_in_pool_plans.each do |dip_plan|
      if dip_plan.environment_dataset_plan.environment_id != vps_env.id
        broken_dip_plans << [dip, dip_plan]
      end
    end
  end

  if broken_dip_plans.empty?
    vps_ok += 1
    next
  end

  puts "VPS #{vps.id}:"
  broken_dip_plans.each do |dip, dip_plan|
    puts "  dataset=#{dip.dataset.full_name},dip=#{dip.id},dip_plan=#{dip_plan.id}"
    puts "    expected env=#{vps_env.id} (edp=#{env_plans[vps_env.id].id})"
    puts "    detected env=#{dip_plan.environment_dataset_plan.environment_id} (edp=#{dip_plan.environment_dataset_plan_id})"
    puts "    set edp to #{env_plans[vps_env.id].id}"
    upgrade.puts "UPDATE dataset_in_pool_plans SET environment_dataset_plan_id = #{env_plans[vps_env.id].id} WHERE id = #{dip_plan.id};"
    rollback.puts "UPDATE dataset_in_pool_plans SET environment_dataset_plan_id = #{dip_plan.environment_dataset_plan_id} WHERE id = #{dip_plan.id};"
  end
  vps_broken += 1
end

upgrade.close
rollback.close

puts "Broken VPS: #{vps_broken}"
puts "OK VPS: #{vps_ok}"
