# frozen_string_literal: true

require 'optparse'

module KernelHistoryBoundsRepair
  DEFAULT_BATCH_SIZE = 1000

  class Runner
    def self.run(node_ids: [], apply: false, batch_size: nil, io: $stdout)
      require_relative 'node_repair'

      batch_size ||= DEFAULT_BATCH_SIZE
      unless batch_size.is_a?(Integer) && batch_size > 0
        raise ArgumentError, 'Batch size must be a positive integer'
      end
      unless node_ids.all? { |id| id.is_a?(Integer) && id > 0 }
        raise ArgumentError, 'Node IDs must be positive integers'
      end

      selected = ::Node.where(role: %i[node storage])
      if node_ids.any?
        selected = selected.where(id: node_ids)
        missing = node_ids.uniq - selected.pluck(:id)
        raise ArgumentError, "Unknown or ineligible node IDs: #{missing.sort.join(', ')}" if missing.any?
      end
      nodes = selected.order(:id).to_a
      # Capture every node's candidates before the first write. Neither new
      # nodes nor events appended to a later node can extend this invocation.
      candidates = ::NodeKernelEvent.kernel_history.where(node_id: nodes.map(&:id))
                                    .order(:node_id, :id).pluck(:node_id, :id).group_by(&:first)
      totals = { nodes: nodes.length, candidates: 0, proposed: 0, applied: 0, skipped: 0 }
      io.puts "#{apply ? 'Apply' : 'Dry-run'}: #{nodes.length} eligible nodes"
      nodes.each do |node|
        io.puts "Node #{node.id} (#{node.name})"
        counts = NodeRepair.run(node:, ids: candidates.fetch(node.id, []).map(&:last), apply:, batch_size:, io:)
        counts.each { |key, count| totals[key] += count }
      end
      io.puts "All nodes totals: #{totals.map { |key, value| "#{key}=#{value}" }.join(' ')}"
      totals
    end
  end

  def self.cli(args, io: $stdout, error: $stderr)
    options = { node_ids: [], apply: false }
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: repair_kernel_history_bounds.rb [--apply] [--node ID] [--batch-size N]'
      opts.separator ''
      opts.separator 'Preview kernel history repairs for all node/storage hosts, including inactive hosts.'
      opts.on('--apply', 'Write the proposed lower bounds after reviewing a dry-run') { options[:apply] = true }
      opts.on('--node ID', 'Restrict to this node; repeat to select several nodes') do |value|
        options[:node_ids] << positive_integer(value, '--node')
      end
      opts.on('--batch-size N', "Process batches of N events (default: #{DEFAULT_BATCH_SIZE})") do |value|
        options[:batch_size] = positive_integer(value, '--batch-size')
      end
      opts.on('-h', '--help', 'Show this help') do
        io.puts opts
        return 0
      end
    end
    parser.parse!(args)
    raise OptionParser::InvalidArgument, "Unexpected arguments: #{args.join(' ')}" unless args.empty?

    require 'vpsadmin'
    Runner.run(**options, io:)
    0
  rescue OptionParser::ParseError, ArgumentError => e
    error.puts e.message
    2
  rescue StandardError => e
    error.puts "Repair stopped: #{e.class}: #{e.message}. Earlier applied repairs remain committed."
    1
  end

  def self.positive_integer(value, option)
    unless value.match?(/\A[1-9][0-9]*\z/)
      raise OptionParser::InvalidArgument, "#{option} must be a positive integer"
    end

    Integer(value, 10)
  end
end
