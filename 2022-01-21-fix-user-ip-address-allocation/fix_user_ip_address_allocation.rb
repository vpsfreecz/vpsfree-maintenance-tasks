#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Fix cluster resource allocation of all user's IP addresses by finding all
# assigned addresses and recalculating cluster resource use.
#
# Usage: $0 <user id>
#

require 'vpsadmin'

if ARGV.length != 1
  fail "usage: #{$0} <user id>"
end

ActiveRecord::Base.transaction do
  user = ::User.find(ARGV[0].to_i)
  puts "User #{user.id} - #{user.login}"

  user.environment_user_configs.each do |user_env|
    puts "  Environment #{user_env.environment.label}"

    ipv4 = 0
    ipv6 = 0
    ipv4_private = 0

    # Owned addresses
    ::IpAddress
      .where(
        user: user,
        charged_environment_id: user_env.environment,
      ).each do |ip|
      puts "    - owned #{ip}"
      case ip.network.ip_version
      when 4
        if ip.network.role == 'public_access'
          ipv4 += ip.size
        else
          ipv4_private += ip.size
        end
      when 6
        ipv6 += ip.size
      else
        fail "unknown IP version on #{ip}"
      end
    end

    # Freely assigned addresses
    ::IpAddress
      .joins(network_interface: :vps)
      .where(
        user: nil,
        charged_environment_id: user_env.environment,
        vpses: {user_id: user.id},
      ).each do |ip|
      puts "    - used #{ip}"
      case ip.network.ip_version
      when 4
        if ip.network.role == 'public_access'
          ipv4 += ip.size
        else
          ipv4_private += ip.size
        end
      when 6
        ipv6 += ip.size
      else
        fail "unknown IP version on #{ip}"
      end
    end

    puts "    IPv4:         #{user_env.ipv4} -> #{ipv4}"
    puts "    IPv6:         #{user_env.ipv6} -> #{ipv6}"
    puts "    IPv4 Private: #{user_env.ipv4_private} -> #{ipv4_private}"

    if user_env.ipv4 != ipv4
      puts "    Fixing IPv4"
      user_env.reallocate_resource!(
        :ipv4,
        ipv4,
        user: user,
        save: true,
        confirmed: ::ClusterResourceUse.confirmed(:confirmed),
      )
    end

    if user_env.ipv6 != ipv6
      puts "    Fixing IPv6"
      user_env.reallocate_resource!(
        :ipv6,
        ipv6,
        user: user,
        save: true,
        confirmed: ::ClusterResourceUse.confirmed(:confirmed),
      )
    end

    if user_env.ipv4_private != ipv4_private
      puts "    Fixing IPv4 private"
      user_env.reallocate_resource!(
        :ipv4_private,
        ipv4_private,
        user: user,
        save: true,
        confirmed: ::ClusterResourceUse.confirmed(:confirmed),
      )
    end

    puts "  ---"
  end
end
