#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Remove old registration requests
#
require 'vpsadmin'

VpsAdmin::API::Plugin::Loader.load('api')

remove = []
keep = []
fmt = '%8d %-20s %-25s %s'

puts sprintf(
  '%8s %-20s %-25s %s',
  'ID', 'STATE', 'LOGIN', 'CREATED AT'
)

RegistrationRequest
  .where('DATE_ADD(created_at, INTERVAL 3 YEAR) < NOW()')
  .order('id')
  .each do |req|
  # Try to find an existing user that the requests belongs to
  if (req.user_id && ::User.find(req.user_id)) \
     || (req.user_id.nil? && ::User.where(
           'login = ? OR orig_login = ? OR email = ?',
           req.login, req.login, req.email,
        ).any?)
    #puts "Keep #{req.id} #{req.login} #{req.created_at}"
    keep << req
    next
  end

  puts sprintf(fmt, req.id, req.state, req.login, req.created_at)
  remove << req
end

STDOUT.write "Removing #{remove.length} requests, #{keep.length} preserved, continue? [y/N] "
STDOUT.flush

if STDIN.readline.strip.downcase != 'y'
  puts "Aborting"
  exit(false)
end

puts
puts "Loosing memory..."
puts

remove.each_with_index do |req, i|
  puts sprintf(fmt, req.id, req.state, req.login, req.created_at)
  PaperTrail::Version.where(item: req).delete_all
  req.destroy!
end

puts "Removed #{remove.length} registration requests"
