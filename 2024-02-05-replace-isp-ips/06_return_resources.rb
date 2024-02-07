#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Return users' resources to their previous value when the IP address replacement
# process is complete.
#
# TODO: properly decide what to do if the values have changed in between.
#
# Usage:
#   EXECUTE=yes $0 $(pwd)/given-resources.json
#
require 'vpsadmin'
require_relative 'common'

include ReplaceIspIps

def return_users_resources(users_resources)
  users_resources.each do |user_id, items|
    puts "User #{user_id}"

    items.each do |item|
      begin
        crpi = ::ClusterResourcePackageItem.find(item[:item_id])
      rescue ActiveRecord::RecordNotFound
        warn "  item #{item.inspect} not found"
        next
      end
      
      puts "  cluster resource item id=#{crpi.id} resource=#{crpi.cluster_resource.name} value-=#{item[:added]}"

      if crpi.value - item[:added] != item[:original_value]
        warn "  original value mismatch in item #{item.inspect}"
      end

      new_value = crpi.value - item[:added]

      if new_value <= 0
        warn "  new value is less or equal to zero in item #{item.inspect}"
      end

      crpi.cluster_resource_package.update_item(crpi, new_value)
    end
  end
end

def load_users_resources(file)
  JSON.parse(File.read(file), symbolize_names: true)[:user_resources]
end

if ARGV.length != 1
  fail "Usage: #{$0} <resource save file>"
end

ActiveRecord::Base.transaction do
  # Load given resources
  users_resources = load_users_resources(ARGV[0])
  
  # Return additional resources
  return_users_resources(users_resources)

  fail 'set EXECUTE=yes' if ENV['EXECUTE'] != 'yes'
end
