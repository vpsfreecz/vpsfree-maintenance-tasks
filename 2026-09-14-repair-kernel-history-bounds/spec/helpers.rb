# frozen_string_literal: true

module KernelHistoryBoundsFixtures
  def t0 = Time.utc(2026, 8, 1, 12)

  def report(release: '6.12.93', patches: [], boot: 'boot-a', errors: [], modules: [])
    VpsAdmin::API::KernelEvidence::Report.from_hash(
      'schema_version' => 1,
      'kernel' => {
        'boot_id' => boot, 'booted_at' => t0.iso8601,
        'booted_release' => '6.12.93', 'reported_release' => release,
        'kernel_source_revision' => nil, 'config_digest' => nil,
        'booted_params' => [], 'command_line' => ''
      },
      'livepatches' => patches.map do |patch|
        { 'id' => 'patch', 'loaded' => true, 'enabled' => true, 'transition' => false,
          'kernel_version' => '6.12.93', 'patch_version' => 1, 'patches' => [] }.merge(patch)
      end,
      'ebpf_programs' => [], 'loaded_modules' => modules, 'software_versions' => [], 'sysctls' => {},
      'deployment' => { 'booted_system' => nil, 'current_system' => nil }, 'errors' => errors
    )
  end

  def snapshot(value, at, type: :event, owner: node)
    NodeKernelEvidence.new(node: owner, snapshot_type: type).tap do |evidence|
      VpsAdmin::API::KernelEvidence::SnapshotWriter.call(
        snapshot: evidence, report: value, observed_at: at, received_at: at
      )
    end
  end

  def event(value, at, type: :module_change, after: nil, action: nil, source: :node_report, confidence: :inferred, owner: node)
    NodeKernelEvent.create!(
      node: owner, event_type: type, livepatch_action: action, source:, confidence:,
      boot_id: value.kernel.boot_id, booted_at: t0,
      booted_release: value.kernel.booted_release, reported_release: value.kernel.reported_release,
      observed_after: after, observed_before: at, kernel_evidence: snapshot(value, at, owner:)
    )
  end
end
