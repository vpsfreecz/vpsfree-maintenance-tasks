#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Give resources to users to enable replacement IP addresses to be assigned to
# them.
#
# Usage:
#   EXECUTE=yes $0 $(pwd)/given-resources.json
#
require 'vpsadmin'
require_relative 'common'

include ReplaceIspIps

def give_users_resources(users_ips)
  users_resources = {}

  users_ips.each do |user, ips|
    puts "User #{user.login}"

    users_resources[user.id] = []
    
    envs = ips.map(&:charged_environment).uniq
    env_changes = {}

    envs.each do |env|
      %i(ipv4 ipv4_private ipv6).each do |r|
        env_ips = ips.select { |ip| ip.charged_environment == env }

        add_resource = Proc.new do |ip|
          env_changes[env] ||= {}
          env_changes[env][r] ||= 0
          env_changes[env][r] += r == :ipv6 ? [ip.size, 2**64].max : ip.size
        end

        case r
        when :ipv4
          env_ips.select do |ip|
            ip.network.role == 'public_access' && ip.network.ip_version == 4
          end.each(&add_resource)

        when :ipv4_private
          env_ips.select do |ip|
            ip.network.role == 'private_access' && ip.network.ip_version == 4
          end.each(&add_resource)

        when :ipv6
          env_ips.select { |ip| ip.network.ip_version == 6 }.each(&add_resource)
        end
      end
    end

    env_changes.each do |env, resources|
      resources.each do |r, v|
        item = ::ClusterResourcePackageItem
          .joins(:cluster_resource, :cluster_resource_package)
          .find_by(
            cluster_resources: {name: r},
            cluster_resource_packages: {
              user_id: user.id,
              environment_id: env.id,
            },
          )

        if item.nil?
          warn "  unable to handle user id=#{user.id} env=#{env.label} resource=#{r} (db inconsistent)"
          next
        end

        users_resources[user.id] << {
          item_id: item.id,
          original_value: item.value,
          added: v,
          new_value: item.value + v,
        }

        puts "  cluster resource item id=#{item.id} resource=#{r} value+=#{v}"

        item.cluster_resource_package.update_item(item, item.value + v)
      end
    end
  end

  users_resources
end

def save_users_resources(users_resources, file)
  File.write(
    file,
    JSON.pretty_generate({user_resources: users_resources}),
  )
end

if ARGV.length != 1
  fail "Usage: #{$0} <resource save file>"
end

ActiveRecord::Base.transaction do
  # Find networks
  networks = get_networks

  # Find all users and their IPs
  users_ips = get_users_ips(networks)

  # Give user additional resources
  users_resources = give_users_resources(users_ips)

  # Save given resources
  save_users_resources(users_resources, ARGV[0])

  fail 'set EXECUTE=yes' if ENV['EXECUTE'] != 'yes'
end
