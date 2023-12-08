#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Run backups for all VPS of selected user
#
require 'vpsadmin'

if ARGV.size != 1
  warn "Usage: #{$0} <user id>"
  exit(false)
end

user_id = ARGV[0].to_i

::Vps.where(object_state: 'active', user_id: user_id).each do |vps|
  puts "VPS #{vps.id} #{vps.hostname}"

  begin
    action = DatasetAction.find_by!(
      src_dataset_in_pool: vps.dataset_in_pool,
      action: DatasetAction.actions['backup'],
    )

    task = RepeatableTask.find_for!(action)

    puts "  running repeatable task #{task.id}"

    # vpsadmin-api-ruby shebang changes our pwd to vpsadmin/api
    res = system('./bin/vpsadmin-run-task', '/var/lib/vpsadmin/api/scheduler.sock', task.id.to_s)
    
    unless res
      puts "  failed to run task"
    end

  rescue ActiveRecord::RecordNotFound
    puts "  backup action not found"
    next
  end
end
