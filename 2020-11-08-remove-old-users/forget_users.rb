#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Remove personal information from hard_deleted users.
#
require 'vpsadmin'

VpsAdmin::API::Plugin::Loader.load('api')

users = []
fmt = '%6d %-12s %-20s %-60s %s'

puts sprintf(
  '%6s %-12s %-20s %-60s %s',
  'ID', 'STATE', 'LOGIN', 'NAME', 'EXPIRATION'
)

User.unscoped.where(
  object_state: ::User.object_states[:hard_delete],
).where(
  'expiration_date IS NOT NULL AND orig_login IS NOT NULL'
).where(
  'expiration_date < NOW()'
).order('id').each do |user|
  puts sprintf(
    fmt,
    user.id,
    user.object_state,
    user.login || user.orig_login,
    user.full_name,
    user.expiration_date,
  )
  users << user
end

STDOUT.write "Removing info about #{users.length} users, continue? [y/N] "
STDOUT.flush

if STDIN.readline.strip.downcase != 'y'
  puts "Aborting"
  exit(false)
end

puts
puts "Loosing memory..."
puts

users.each_with_index do |user, i|
  puts sprintf(
    "[%d/%d] #{fmt}",
    i+1,
    users.length,
    user.id,
    user.object_state,
    user.login || user.orig_login,
    user.full_name,
    user.expiration_date,
  )
  user.assign_attributes(
    login: nil,
    full_name: nil,
    password: '!',
    email: nil,
    address: nil,
    orig_login: nil,
  )
  user.save!(validate: false)

  PaperTrail::Version.where(item: user).delete_all
end

puts "Removed info from #{users.length} users"
