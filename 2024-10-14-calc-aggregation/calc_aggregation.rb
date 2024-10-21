#!/run/current-system/sw/bin/vpsadmin-api-ruby
require 'vpsadmin'

include ActiveSupport::NumberHelper

puts format('%15s %15s %20s %20s %20s', 'NODE', 'RESOURCE', 'TOTAL', 'ALLOCATED', 'RATIO')

::Node.where(role: 'node', active: true).each do |n|
  sums = {
    cpu: 0,
    memory: 0,
    diskspace: 0
  }

  n.vpses.where(object_state: 'active').each do |vps|
    %i[cpu memory].each do |r|
      sums[r] += vps.send(r)
    end

    sums[:diskspace] += vps.dataset_in_pool.refquota
  end

  sums.each do |r, allocated|
    total =
      case r
      when :cpu
        n.cpus
      when :memory
        n.total_memory
      when :diskspace
        0
      end

    total_formatted = r == :cpu ? total.to_s : number_to_human_size(total * 1024 * 1024)

    allocated_formatted = r == :cpu ? sums[r].to_s : number_to_human_size(sums[r] * 1024 * 1024)

    puts format(
      '%15s %15s %20s %20s %20s',
      n.domain_name,
      r.to_s.upcase,
      total_formatted,
      allocated_formatted,
      total > 0 ? (sums[r] / total.to_f).round(2) : '-'
    )
  end
  
  puts
end
