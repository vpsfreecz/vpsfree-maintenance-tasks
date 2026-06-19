#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Recalculate user IP address resource accounting after failed VPS chown.
#
# Background:
# Failed VPS chown transactions could leak an EnvironmentUserConfig
# ClusterResourceUse row for the destination user when the destination user had
# no previous IP resource-use row. The visible symptom is that a later chown
# attempt needs one extra IPv4 resource even though the VPS still has the same
# address.
#
# Usage:
#   ./fix_vps_chown_ip_accounting.rb --user 123 --user 456
#   ./fix_vps_chown_ip_accounting.rb --user 123 --environment 1
#   ./fix_vps_chown_ip_accounting.rb --user 123 --user 456 --execute
#   ./fix_vps_chown_ip_accounting.rb --all-users
#   ./fix_vps_chown_ip_accounting.rb --all-users --execute
#
require 'optparse'

RESOURCES = %i[ipv4 ipv6 ipv4_private].freeze

options = {
  all_users: false,
  environment_ids: [],
  execute: false,
  user_ids: [],
}

OptionParser.new do |opts|
  opts.banner = 'Usage: fix_vps_chown_ip_accounting.rb [options]'

  opts.on('--user ID', Integer, 'User to check; can be used repeatedly') do |id|
    options[:user_ids] << id
  end

  opts.on('--environment ID', Integer, 'Environment to check; can be used repeatedly') do |id|
    options[:environment_ids] << id
  end

  opts.on('--all-users', 'Check all users') do
    options[:all_users] = true
  end

  opts.on('--execute', 'Apply changes; default is dry-run') do
    options[:execute] = true
  end

  opts.on('-h', '--help', 'Show this help') do
    puts opts
    exit 0
  end
end.parse!

if options[:all_users] && options[:user_ids].any?
  fail '--all-users cannot be combined with --user'
end

if !options[:all_users] && options[:user_ids].empty?
  fail 'provide --user at least once, or use --all-users'
end

require 'vpsadmin'

def verify_selected_ids!(model, ids, label)
  return if ids.empty?

  found = model.where(id: ids).pluck(:id)
  missing = ids.uniq - found
  return if missing.empty?

  fail "unknown #{label} ID(s): #{missing.join(', ')}"
end

def wanted_users(options)
  scope = ::User.order(:id)

  unless options[:all_users]
    scope = scope.where(id: options[:user_ids])
  end

  scope
end

def wanted_user_envs(user, options)
  scope = user.environment_user_configs.includes(:environment).order(:environment_id)

  if options[:environment_ids].any?
    scope = scope.where(environment_id: options[:environment_ids])
  end

  scope
end

def resource_name(ip)
  if ip.network.ip_version == 6
    :ipv6
  elsif ip.network.role == 'public_access'
    :ipv4
  else
    :ipv4_private
  end
end

def expected_usage(user, environment)
  ret = RESOURCES.to_h { |r| [r, 0] }

  # Owned addresses. This covers standalone user-owned addresses and addresses
  # assigned in environments where IP ownership is tracked on ip_addresses.
  ::IpAddress
    .includes(:network)
    .where(
      user: user,
      charged_environment_id: environment.id,
    ).find_each do |ip|
    ret[resource_name(ip)] += ip.size
  end

  # Freely assigned addresses. In environments without IP ownership, VPS-routed
  # addresses remain user_id=NULL and are charged to the VPS owner.
  ::IpAddress
    .includes(:network)
    .joins(network_interface: :vps)
    .where(
      user: nil,
      charged_environment_id: environment.id,
      vpses: { user_id: user.id },
    ).find_each do |ip|
    ret[resource_name(ip)] += ip.size
  end

  ret
end

def current_usage(user_env)
  RESOURCES.to_h { |r| [r, user_env.public_send(r)] }
end

def print_change(user, environment, resource, current, expected)
  puts format(
    'user=%<login>s(#%<user_id>d) env=%<env>s(#%<env_id>d) %<resource>s: %<current>d -> %<expected>d',
    login: user.login,
    user_id: user.id,
    env: environment.label,
    env_id: environment.id,
    resource: resource,
    current: current,
    expected: expected,
  )
end

def apply_change(user_env, user, resource, expected)
  user_env.reallocate_resource!(
    resource,
    expected,
    user: user,
    save: true,
    confirmed: ::ClusterResourceUse.confirmed(:confirmed),
  )
end

verify_selected_ids!(::User, options[:user_ids], 'user')
verify_selected_ids!(::Environment, options[:environment_ids], 'environment')

changes = []

wanted_users(options).each do |user|
  wanted_user_envs(user, options).each do |user_env|
    current = current_usage(user_env)
    expected = expected_usage(user, user_env.environment)

    RESOURCES.each do |resource|
      next if current.fetch(resource) == expected.fetch(resource)

      changes << [user, user_env, resource, current.fetch(resource), expected.fetch(resource)]
    end
  end
end

if changes.empty?
  puts 'No IP resource accounting differences found'
  exit 0
end

puts options[:execute] ? 'Applying IP resource accounting repair' : 'Dry-run: IP resource accounting repair'

changes.each do |user, user_env, resource, current, expected|
  print_change(user, user_env.environment, resource, current, expected)
end

if options[:execute]
  ::ActiveRecord::Base.transaction do
    changes.each do |user, user_env, resource, _current, expected|
      apply_change(user_env, user, resource, expected)
    end
  end

  puts "Updated #{changes.length} resource counter(s)"
else
  puts "Would update #{changes.length} resource counter(s); rerun with --execute to apply"
end
