#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Walk through all backup actions and detach heads where the history flow is broken.

require 'vpsadmin'

to_detach = []

::DatasetAction.where(action: 'backup').each do |action|
  if action.src_dataset_in_pool.nil? || action.dst_dataset_in_pool.nil?
    puts "Skipping invalid action #{action.id}"
    next
  end

  puts "Action #{action.id} " \
        "#{action.src_dataset_in_pool.pool.node.domain_name}:#{action.src_dataset_in_pool.pool.filesystem}/#{action.src_dataset_in_pool.dataset.full_name}" \
        " -> " \
        "#{action.dst_dataset_in_pool.pool.node.domain_name}:#{action.dst_dataset_in_pool.pool.filesystem}/#{action.dst_dataset_in_pool.dataset.full_name}"

  has_shared_snapshot = false

  action.src_dataset_in_pool.snapshot_in_pools.each do |src_sip|
    if action.dst_dataset_in_pool.snapshot_in_pools.where(snapshot_id: src_sip.snapshot_id).any?
      has_shared_snapshot = true
      break
    end
  end

  if has_shared_snapshot
    puts '  shared snapshot found'
    next
  end

  puts '  detach needed'
  to_detach << action
end

if to_detach.empty?
  puts 'Nothing to detach'
  exit
end

puts "#{to_detach.length} heads to detach"
puts
to_detach.each do |action|
  puts File.join(action.dst_dataset_in_pool.pool.filesystem, action.dst_dataset_in_pool.dataset.full_name)

  action.dst_dataset_in_pool.dataset_trees.where(head: true).each do |tree|
    puts "  tree.#{tree.index}"

    tree.branches.where(head: true).each do |branch|
      puts "    branch-#{branch.name}.#{branch.index}"
    end
  end
end

puts
STDOUT.write "Detach all? [y/N] "
raise 'abort' if STDIN.readline.strip != 'y'

to_detach.each do |action|
  puts action.dst_dataset_in_pool.dataset.full_name

  action.dst_dataset_in_pool.dataset_trees.where(head: true).each do |tree|
    puts "  tree.#{tree.index}"
    tree.update!(head: false)

    tree.branches.where(head: true).each do |branch|
      puts "    branch-#{branch.name}.#{branch.index}"
      branch.update!(head: false)
    end
  end

  ::Dataset.increment_counter(:current_history_id, action.dst_dataset_in_pool.dataset_id)
end
