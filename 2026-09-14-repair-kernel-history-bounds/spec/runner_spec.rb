# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'open3'
require_relative '../runner'
require_relative '../node_repair'
require_relative 'helpers'

RSpec.describe KernelHistoryBoundsRepair::Runner do
  include KernelHistoryBoundsFixtures

  let(:node) { SpecSeed.node }
  let(:other_node) { SpecSeed.other_node }
  let(:io) { StringIO.new }

  def history(owner)
    [event(report, t0, type: :boot, owner:),
     event(report(modules: ['kvm']), t0 + 20.days, owner:),
     event(report(release: '6.12.94'), t0 + 30.days, type: :reported_release_change, after: t0, owner:)]
  end

  it 'previews all eligible nodes including inactive storage hosts, then applies and reruns' do
    other_node.update!(role: :storage, active: false)
    histories = [history(node), history(other_node)]
    before = histories.flatten.map(&:attributes)
    result = described_class.run(io:, batch_size: 1)
    expect(result).to include(proposed: 2, applied: 0)
    expect(histories.flatten.map { |row| row.reload.attributes }).to eq(before)
    expect(io.string).to include("node=#{node.id}", "node=#{other_node.id}", 'All nodes totals:')
    expect(described_class.run(io:, apply: true)[:applied]).to eq(2)
    expect(io.string).to include('batch size 1000')
    histories.each { |rows| expect(rows.last.reload.observed_after).to eq(t0 + 20.days) }
    expect(described_class.run(io:, apply: true)[:applied]).to eq(0)
  end

  it 'limits processing to explicit nodes, deduplicating IDs' do
    first = history(node).last
    second = history(other_node).last
    result = described_class.run(io:, apply: true, node_ids: [node.id, node.id])
    expect(result).to include(nodes: 1, applied: 1)
    expect(first.reload.observed_after).to eq(t0 + 20.days)
    expect(second.reload.observed_after).to eq(t0)
  end

  it 'rejects unknown and service-only explicit nodes before writing anything' do
    target = history(node).last
    other_node.update!(role: :mailer)
    [other_node.id, 999_999_999].each do |id|
      expect { described_class.run(io:, apply: true, node_ids: [node.id, id]) }
        .to raise_error(ArgumentError, /Unknown or ineligible/)
    end
    expect(target.reload.observed_after).to eq(t0)
  end

  it 'freezes all node candidates before processing the first node' do
    history(node)
    appended = nil
    allow(KernelHistoryBoundsRepair::NodeRepair).to receive(:run).and_wrap_original do |original, **options|
      appended ||= history(other_node).last
      original.call(**options)
    end
    result = described_class.run(io:, apply: true, batch_size: 1)
    expect(result).to include(candidates: 2, applied: 1)
    expect(appended.reload.observed_after).to eq(t0)
    expect(io.string).not_to include("event=#{appended.id} ")
  end

  it 'reports a changed node role as concurrent skips without aborting other nodes' do
    history(node)
    history(other_node)
    allow(KernelHistoryBoundsRepair::NodeRepair).to receive(:run).and_wrap_original do |original, **options|
      options[:node].update!(role: :mailer) if options[:node].id == node.id
      original.call(**options)
    end
    # Eligibility is checked again under the lock; the initial selection must
    # not turn a later role change into an operational failure.
    result = described_class.run(io:, apply: true)
    expect(result).to include(applied: 1)
    expect(io.string).to include('skip: concurrent change')
  end

  it 'supports help and rejects malformed command arguments' do
    expect(KernelHistoryBoundsRepair.cli(['--help'], io:)).to eq(0)
    expect(io.string).to include('--node', '--apply', '1000', 'inactive')
    [%w[--node 0], %w[--node -1], %w[--node all], %w[--node 1,2],
     %w[--batch-size 0], %w[--batch-size nope], %w[--apply=1], ['unexpected']].each do |args|
      expect(KernelHistoryBoundsRepair.cli(args, io:, error: io)).to eq(2)
    end
  end

  describe 'standalone command on a disposable database', :no_transaction do
    let(:histories) { [history(node), history(other_node)] }
    let(:targets) { histories.map(&:last) }

    around do |example|
      rows = histories.flatten
      evidence_ids = rows.map(&:node_kernel_evidence_id)
      example.run
    ensure
      NodeKernelEvent.where(id: rows.map(&:id)).destroy_all if rows
      NodeKernelEvidence.where(id: evidence_ids).destroy_all if evidence_ids
    end

    def command(*args)
      path = File.expand_path('../repair_kernel_history_bounds.rb', __dir__)
      Open3.capture3({ 'RACK_ENV' => 'test', 'DATABASE_URL' => ENV.fetch('DATABASE_URL') },
                     RbConfig.ruby, '-Ilib', '-e', 'load ARGV.shift', path, *args)
    end

    it 'runs help, preview, subset apply, all-node apply and rerun through the installed loader semantics' do
      output, error, status = command('--help')
      expect(status.success?).to be(true), error
      expect(output).to include('Usage:', '--apply', '--node', '1000')

      output, error, status = command
      expect(status.success?).to be(true), error
      expect(output).to include('proposed=2', 'applied=0')
      expect(targets.map { |target| target.reload.observed_after }).to eq([t0, t0])

      output, error, status = command('--apply', '--node', node.id.to_s, '--batch-size', '1')
      expect(status.success?).to be(true), error
      expect(output).to include('nodes=1', 'applied=1')
      expect(targets.map { |target| target.reload.observed_after }).to eq([t0 + 20.days, t0])

      output, error, status = command('--apply')
      expect(status.success?).to be(true), error
      expect(output).to include('applied=1')
      output, error, status = command('--apply')
      expect(status.success?).to be(true), error
      expect(output).to include('applied=0')
    end
  end
end
