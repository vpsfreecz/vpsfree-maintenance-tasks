#!/run/current-system/sw/bin/vpsadmin-api-ruby
require 'vpsadmin'

cnt = 0
limit = 100

::Vps.unscoped.where(object_state: 'hard_delete').each do |vps|
  next if vps.user.nil?

  ds = ::Dataset.find_by(full_name: vps.id.to_s, expiration_date: nil, object_state: 'active')
  next if ds.nil?

  next if ds.dataset_in_pools.count != 1

  dip = ds.dataset_in_pools.first
  next if dip.pool_id != 14 # backuper

  puts "Dataset ##{ds.id} (#{ds.full_name}) of VPS #{vps.id} (#{vps.object_state})"
  #puts File.join(dip.pool.filesystem, ds.full_name)

  ds.set_expiration(
    Time.new(2023, 07, 12, 9, 16, 0),
    reason: 'Fix vpsAdmin bug which left datasets of deleted VPS',
  )

  cnt += 1
  break if cnt >= limit
end

puts "#{cnt} datasets"
