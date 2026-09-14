# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require_relative '../runner'
require_relative '../node_repair'
require_relative 'helpers'

RSpec.describe KernelHistoryBoundsRepair::NodeRepair do
  include KernelHistoryBoundsFixtures

  let(:node) { SpecSeed.node }
  let(:io) { StringIO.new }
  let!(:baseline) { event(report, t0, type: :boot) }
  let!(:confirmation) { event(report(modules: ['kvm']), t0 + 20.days) }
  let!(:target) { event(report(release: '6.12.94'), t0 + 30.days, type: :reported_release_change, after: t0) }

  def repair(**options)
    described_class.run(node:, io:, batch_size: 1, **options)
  end

  it 'previews a tighter interval from an internal immutable event without writing' do
    before = target.attributes
    result = repair
    expect(result).to eq(candidates: 2, proposed: 1, applied: 0, skipped: 1)
    expect(target.reload.attributes).to eq(before)
    expect(io.string).to include('dry-run', "event=#{target.id}", "evidence=#{confirmation.node_kernel_evidence_id}",
                                 (t0 + 20.days).iso8601(6), 'skip: boot event', 'would tighten')
  end

  it 'applies only the lower bound, invalidates the public revision, and is idempotent' do
    before = target.attributes
    target.update_columns(updated_at: t0)
    revision = VpsAdmin::API::KernelEvidence::Revision.event(target)
    expect(repair(apply: true)[:applied]).to eq(1)
    expect(target.reload.observed_after).to eq(confirmation.observed_before)
    expect(target.attributes.except('observed_after', 'updated_at'))
      .to eq(before.except('observed_after', 'updated_at'))
    expect(VpsAdmin::API::KernelEvidence::Revision.event(target)).not_to eq(revision)
    after = target.attributes
    expect(repair(apply: true)[:applied]).to eq(0)
    expect(target.reload.attributes).to eq(after)
  end

  it 'chooses the latest positive confirmation, excluding transitioning and incomplete samples' do
    latest = event(report(modules: ['latest']), t0 + 25.days)
    event(report(patches: [{ 'enabled' => false, 'transition' => true }]), t0 + 27.days)
    event(report(errors: [{ 'component' => 'livepatches', 'reason' => 'unavailable' }]), t0 + 29.days)
    repair(apply: true)
    expect(target.reload.observed_after).to eq(latest.observed_before)
    expect(io.string).to include("evidence=#{latest.node_kernel_evidence_id}")
  end

  it 'ignores mutable snapshots, checkpoints, raw samples, and snapshots outside the open interval' do
    confirmation.destroy!
    snapshot(report, t0 + 25.days, type: :current)
    NodeKernelEvidenceCheckpoint.create!(node:, report: report.to_h, observed_at: t0 + 25.days)
    event(report, t0 - 60)
    event(report, target.observed_before)
    event(report, target.observed_before + 60)
    expect(repair(apply: true)[:applied]).to eq(0)
    expect(target.reload.observed_after).to eq(t0)
    expect(io.string).to include('no retained stable confirmation')
  end

  it 'rejects evidence and targets from another boot' do
    confirmation.update!(kernel_evidence: snapshot(report(boot: 'boot-b'), confirmation.observed_before))
    expect(repair(apply: true)[:applied]).to eq(0)
    target.update!(kernel_evidence: snapshot(report(release: '6.12.94', boot: 'boot-b'), target.observed_before))
    expect(repair(apply: true)[:applied]).to eq(0)
    expect(io.string).to include('different or unknown boot')
  end

  it 'uses the immediate public predecessor rather than an older matching baseline' do
    event(report(release: '6.12.95'), t0 + 10.days, type: :reported_release_change, after: t0)
    repair(apply: true)
    expect(target.reload.observed_after).to eq(t0 + 10.days)
  end

  %i[applied removed].each do |action|
    it "repairs an explicitly classified livepatch #{action} event" do
      old = report(patches: action == :removed ? [{}] : [])
      new = report(patches: action == :applied ? [{}] : [])
      baseline.update!(kernel_evidence: snapshot(old, t0))
      confirmation.update!(kernel_evidence: snapshot(old, confirmation.observed_before))
      target.update!(event_type: :livepatch_change, livepatch_action: action,
                     reported_release: new.kernel.reported_release,
                     kernel_evidence: snapshot(new, target.observed_before))
      expect(repair(apply: true)[:applied]).to eq(1)
      expect(target.reload.observed_after).to eq(confirmation.observed_before)
    end
  end

  it 'does not treat a legacy inventory hiding the active patch as confirmation' do
    old = report(patches: [{}])
    baseline.update!(kernel_evidence: snapshot(old, t0))
    hidden = report(patches: [{ 'id' => 'other', 'loaded' => false, 'enabled' => false }])
    confirmation.update!(kernel_evidence: snapshot(hidden, confirmation.observed_before))
    target.update!(event_type: :livepatch_change, livepatch_action: :removed,
                   kernel_evidence: snapshot(report, target.observed_before))
    expect(repair(apply: true)[:applied]).to eq(0)
  end

  [%i[source reconstructed_node_status], %i[confidence exact], [:observed_after, nil],
   %i[event_type livepatch_change]].each do |attribute, value|
    it "skips ineligible #{attribute}=#{value.inspect}" do
      target.update!(attribute => value)
      expect(repair(apply: true)[:applied]).to eq(0)
    end
  end

  %i[target predecessor evidence evidence_contents].each do |changed|
    it "skips a concurrent change to #{changed}" do
      operation = described_class.new
      allow(operation).to receive(:apply_proposal).and_wrap_original do |original, proposal|
        case changed
        when :target then target.update!(observed_after: t0 + 60)
        when :predecessor then baseline.update!(confidence: :incomplete)
        when :evidence then confirmation.destroy!
        when :evidence_contents
          confirmation.kernel_evidence.kernel_modules.create!(name: 'concurrent')
        end
        original.call(proposal)
      end
      expect(operation.run(node:, io:, apply: true, batch_size: 1)[:applied]).to eq(0)
      expect(io.string).to include('skip: concurrent change')
    end
  end

  %i[baseline target].each do |changed|
    it "rejects preexisting integrity drift in the #{changed} snapshot" do
      event = changed == :baseline ? baseline : target
      event.kernel_evidence.kernel_modules.create!(name: 'altered-before-repair')
      expect(repair(apply: true)[:applied]).to eq(0)
      expect(target.reload.observed_after).to eq(t0)
      expect(io.string).to include('altered immutable baseline/target evidence')
    end
  end

  it 'skips a changed supporting snapshot and uses the latest intact proof' do
    intact = event(report(modules: ['intact']), t0 + 10.days)
    confirmation.kernel_evidence.kernel_modules.create!(name: 'altered-before-repair')
    expect(repair(apply: true)[:applied]).to eq(1)
    expect(target.reload.observed_after).to eq(intact.observed_before)
  end

  it 'leaves history unchanged if the only newer confirmation fails its stored digest' do
    confirmation.kernel_evidence.kernel_modules.create!(name: 'altered-before-repair')
    expect(repair(apply: true)[:applied]).to eq(0)
    expect(target.reload.observed_after).to eq(t0)
  end

  it 'keeps a fixed candidate set when history is appended during a batch' do
    operation = described_class.new
    appended = nil
    allow(operation).to receive(:apply_proposal).and_wrap_original do |original, proposal|
      appended = event(report(release: '6.12.95'), t0 + 40.days,
                       type: :reported_release_change, after: target.observed_before)
      original.call(proposal)
    end
    expect(operation.run(node:, io:, apply: true, batch_size: 1)[:candidates]).to eq(2)
    expect(io.string).not_to include("event=#{appended.id} ")
  end
end
