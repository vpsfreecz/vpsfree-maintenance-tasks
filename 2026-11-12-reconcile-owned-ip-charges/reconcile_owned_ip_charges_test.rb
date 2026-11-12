# frozen_string_literal: true

require 'minitest/test'
require 'ostruct'
require 'stringio'
require 'open3'
require 'rbconfig'
require_relative 'reconcile_owned_ip_charges_lib'

class ReconcilePlanTest < Minitest::Test
  Tool = ReconcileOwnedIpCharges
  S = 2**64
  L = 2**80

  class Record < OpenStruct
    def confirmed?
      confirmed == :confirmed
    end
  end

  def record(**attrs)
    Record.new(attrs)
  end

  def setup
    @data = {
      'version' => 1,
      'groups' => [{ 'owner_config_id' => 10, 'resource' => 'ipv6' }],
      'ips' => [{ 'id' => 51, 'owner_config_id' => 10, 'network_id' => 2,
                  'prefix' => 48, 'size' => L.to_s, 'from_environment_id' => nil, 'to_environment_id' => 1 }],
      'usage_changes' => [
        { 'id' => 40, 'config_id' => 10, 'environment_id' => 1, 'resource' => 'ipv6', 'from_value' => S.to_s, 'to_value' => (S + L).to_s },
        { 'id' => 41, 'config_id' => 11, 'environment_id' => 2, 'resource' => 'ipv6', 'from_value' => '7', 'to_value' => '0' }
      ]
    }
    @rows = { configs: [record(id: 10, user_id: 100, environment_id: 1), record(id: 11, user_id: 100, environment_id: 2)],
              environments: [record(id: 1), record(id: 2)],
              networks: [record(id: 1, ip_version: 6, role: 'public_access', purpose: 'vps'), record(id: 2, ip_version: 6, role: 'public_access', purpose: 'vps')],
              locations: [record(id: 5, environment_id: 1)], links: [record(id: 6, network_id: 2, location_id: 5)],
              resources: [record(id: 20, name: 'ipv6')],
              quotas: [record(id: 30, user_id: 100, environment_id: 1, cluster_resource_id: 20, value: 4 * L),
                       record(id: 31, user_id: 100, environment_id: 2, cluster_resource_id: 20, value: 4 * L)],
              uses: [record(id: 40, user_cluster_resource_id: 30, class_name: 'EnvironmentUserConfig', table_name: 'environment_user_configs', row_id: 10, value: S, enabled: true, confirmed: :confirmed, admin_lock_type: 'no_lock'),
                     record(id: 41, user_cluster_resource_id: 31, class_name: 'EnvironmentUserConfig', table_name: 'environment_user_configs', row_id: 11, value: 7, enabled: true, confirmed: :confirmed, admin_lock_type: 'no_lock')],
              interfaces: [], vpses: [], hosts: [],
              ips: [record(id: 50, user_id: 100, network_id: 1, prefix: 64, size: BigDecimal(S.to_s), charged_environment_id: 1),
                    record(id: 51, user_id: 100, network_id: 2, prefix: 48, size: BigDecimal(L.to_s))] }
  end

  def compare
    Tool::Comparison.new(Tool::Plan.parse(JSON.generate(@data)), @rows)
  end

  def test_exact_positive_negative_and_preserved_charge
    result = compare
    assert_equal [(S + L).to_s, '0'], result.changes.map { |r| r[:to_value] }
    assert_equal S + L, result.inventory[[100, 'ipv6', 1]]
    assert_equal 1, @rows[:ips].first.charged_environment_id
    assert_equal 4 * L, @rows[:quotas].first.value
  end

  def test_require_does_not_load_application
    refute defined?(ActiveRecord) unless ENV['RECONCILE_IP_DB_TEST'] == '1'
  end

  def test_unknown_duplicate_missing_and_wrong_numeric_plan_data
    mutations = [->(x) { x['extra'] = 1 }, ->(x) { x.delete('groups') },
                 ->(x) { x['ips'] << x['ips'].first.dup }, ->(x) { x['groups'] *= 2 },
                 ->(x) { x['usage_changes'] *= 2 }, ->(x) { x['version'] = 1.0 },
                 ->(x) { x['ips'][0]['size'] = 2.5 }, ->(x) { x['ips'][0]['size'] = '01' },
                 ->(x) { x['ips'][0]['id'] = '51' }, ->(x) { x['ips'][0]['from_environment_id'] = 1 },
                 ->(x) { x['usage_changes'][0]['to_value'] = '-1' }]
    mutations.each do |mutation|
      data = Marshal.load(Marshal.dump(@data)); mutation.call(data)
      assert_raises(Tool::Refused) { Tool::Plan.parse(JSON.generate(data)) }
    end
    assert_raises(Tool::Refused) { Tool::Plan.parse('{"version":1,"version":1}') }
  end

  def test_stale_mapping_and_unknown_id
    @data['ips'][0]['prefix'] = 49
    assert_raises(Tool::Refused) { compare }
    @data['ips'][0]['id'] = 999
    assert_raises(Tool::Refused) { compare }
  end

  def test_extra_computed_or_extra_supplied_change
    @data['usage_changes'].pop
    assert_raises(Tool::Refused) { compare }
    setup
    @data['usage_changes'][0]['to_value'] = (L + S + 1).to_s
    assert_raises(Tool::Refused) { compare }
  end

  def test_missing_required_use_and_unlisted_missing_pointer
    @rows[:uses].shift
    assert_raises(Tool::Refused) { compare }
    setup
    @data['ips'] = []
    assert_raises(Tool::Refused) { compare }
  end

  def test_group_with_no_mapping_and_zero_absent_use
    @data['ips'] = []
    @rows[:ips].pop
    @data['usage_changes'].shift
    compare
    @rows[:uses].pop
    @data['usage_changes'] = []
    compare
  end

  def test_ambiguous_group_alias_and_abnormal_use
    @data['groups'] << { 'owner_config_id' => 11, 'resource' => 'ipv6' }
    assert_raises(Tool::Refused) { compare }
    setup
    @rows[:uses][0].enabled = false
    assert_raises(Tool::Refused) { compare }
    setup
    @rows[:uses][0].admin_lock_type = 'absolute'
    assert_raises(Tool::Refused) { compare }
  end

  def test_unrelated_resource_preserved
    @rows[:resources] << record(id: 21, name: 'ipv4')
    @rows[:quotas] << record(id: 32, user_id: 100, environment_id: 1, cluster_resource_id: 21, value: 5)
    @rows[:uses] << record(id: 42, user_cluster_resource_id: 32, value: 999, class_name: 'Vps', row_id: 88)
    assert_equal 2, compare.changes.size
    assert_equal 999, @rows[:uses].last.value
  end

  def test_quota_excess_and_route_shape_fail_closed
    @rows[:quotas][0].value = S
    assert_raises(Tool::Refused) { compare }
    setup
    @rows[:ips][0].route_via_id = 999
    assert_raises(Tool::Refused) { compare }
  end

  def test_routed_prefix_and_disjoint_userless_vps_count_once
    @rows[:interfaces] << record(id: 60, vps_id: 70)
    @rows[:vpses] << record(id: 70, user_id: 100, object_state: 'active', confirmed: :confirmed)
    @rows[:ips] << record(id: 52, network_id: 1, prefix: 128, size: 1, charged_environment_id: 2, network_interface_id: 60)
    @rows[:ips][0].network_interface_id = 60
    @rows[:ips][0].route_via_id = 80
    @rows[:hosts] << record(id: 80, ip_address_id: 52, order: 1)
    @data['usage_changes'][1]['to_value'] = '1'
    result = compare
    assert_equal 3, result.contributing_ips.size
    assert_equal 1, result.inventory[[100, 'ipv6', 2]]
    assert_equal S + L, result.inventory[[100, 'ipv6', 1]]
    @rows[:vpses][0].confirmed = :confirm_create
    assert_raises(Tool::Refused) { compare }
  end

  def test_cli_help_and_apply_attestation_do_not_load_application
    assert_equal 0, Tool.run(['--help'], output: StringIO.new)
    assert_equal 1, Tool.run(['--plan', '/nonexistent', '--apply'], error: StringIO.new)
  end
  def receipt(status = 'preview')
    plan = Tool::Plan.parse(JSON.generate(@data))
    { status:, plan: plan.identity, ips: plan.ips, usage_changes: plan.usage_changes }
  end

  def render(payload, json: false)
    output = StringIO.new
    Tool::Printer.new(output, json:).emit(payload)
    output.string
  end

  def columns_for(output, id)
    output.lines.find { |line| line.match?(/\A\s*#{id}\s/) }.strip.split(/\s{2,}/)
  end

  def test_human_receipt_has_all_technical_fields_and_exact_values
    payload = receipt
    text = render(payload)
    assert_includes text, "Plan: #{payload[:plan]}"
    assert_includes text, 'IP environment changes: 1; resource usage changes: 2'
    assert_includes text, 'Amounts are exact address units; delta = after - before.'
    assert_equal ['51', '10', '2', '/48', '1,208,925,819,614,629,174,706,176', 'not recorded', '1'], columns_for(text, 51)
    positive = columns_for(text, 40)
    assert_equal ['40', '10', '1', 'ipv6'], positive[0, 4]
    assert_equal [S, S + L, L], positive[4, 3].map { |n| Integer(n.delete(','), 10) }
    assert positive.last.start_with?('+')
    assert_equal ['41', '11', '2', 'ipv6', '7', '0', '-7'], columns_for(text, 41)
  end

  def test_human_receipt_stage_meanings
    preview = render(receipt('preview'))
    assert_equal 'Preview: no database changes were made.', preview.lines.first.chomp
    refute_includes preview, 'Committed:'
    validated = render(receipt('validated_before_commit'))
    assert_equal 'Validated before commit: the transaction has not committed yet.', validated.lines.first.chomp
    refute_includes validated, 'Committed:'
    assert_equal 'Committed: database changes saved.', render(receipt('committed')).lines.first.chomp
  end

  def test_empty_sections_and_zero_delta_are_explicit
    payload = receipt
    payload[:ips] = []; payload[:usage_changes] = []
    text = render(payload)
    assert_includes text, 'IP environment changes: 0; resource usage changes: 0'
    assert_includes text, 'No IP environment changes.'
    assert_includes text, 'No resource usage changes.'
    payload[:usage_changes] = [{ id: 42, config_id: 10, environment_id: 1, resource: 'ipv4', from_value: '0', to_value: '0' }]
    assert_equal ['42', '10', '1', 'ipv4', '0', '0', '0'], columns_for(render(payload), 42)
  end

  def test_json_receipts_are_exact_legacy_lines_and_rendering_never_mutates_inputs
    %w[preview validated_before_commit committed].each do |stage|
      payload = receipt(stage)
      before = Marshal.dump(payload)
      assert_equal JSON.generate(payload) + "\n", render(payload, json: true)
      render(payload)
      assert_equal before, Marshal.dump(payload)
      assert_equal Tool::Plan.parse(JSON.generate(@data)).identity, payload[:plan]
    end
  end

  def test_large_low_bit_amounts_and_signed_delta_remain_exact
    payload = receipt
    payload[:usage_changes] = [
      { id: 140, config_id: 10, environment_id: 1, resource: 'ipv6', from_value: (S + 1).to_s, to_value: (L + S + 3).to_s },
      { id: 141, config_id: 11, environment_id: 2, resource: 'ipv6', from_value: (L + S + 3).to_s, to_value: (S + 1).to_s },
      { id: 142, config_id: 10, environment_id: 1, resource: 'ipv6', from_value: (S + 1).to_s, to_value: (S + 1).to_s }
    ]
    text = render(payload)
    assert_equal [S + 1, L + S + 3, L + 2], columns_for(text, 140)[4, 3].map { |v| Integer(v.delete(','), 10) }
    assert_equal [L + S + 3, S + 1, -L - 2], columns_for(text, 141)[4, 3].map { |v| Integer(v.delete(','), 10) }
    assert_equal '0', columns_for(text, 142).last
  end

  def test_json_flag_keeps_help_and_errors_plain_in_both_launchers
    %i[direct production_load].each do |mode|
      out, err, status = launch(mode, '--json', '--help')
      assert status.success?
      assert_includes out, 'Usage:'
      assert_includes out, '--json'
      assert_empty err
      [[], ['--plan', '/dev/stdin']].each do |args|
        out, err, status = launch(mode, '--json', *args, input: '{')
        assert_equal 1, status.exitstatus
        assert_empty out
        assert err.start_with?('refused: ')
        refute err.start_with?('{')
      end
    end
  end

  def launch(mode, *args, input: '')
    executable = File.expand_path('reconcile_owned_ip_charges.rb', __dir__)
    command = [RbConfig.ruby]
    command += ['-e', 'script = ARGV[0]; ARGV.shift; load script', '--'] if mode == :production_load
    Open3.capture3(*command, executable, *args, stdin_data: input, chdir: File.dirname(__dir__))
  end

  def test_real_executable_help_direct_and_production_loader
    %i[direct production_load].each do |mode|
      out, err, status = launch(mode, '--help')
      assert status.success?, mode.to_s
      assert_includes out, 'Usage: reconcile_owned_ip_charges.rb --plan PATH'
      assert_empty err
    end
  end

  def test_real_executable_refuses_missing_arguments_and_malformed_plan
    %i[direct production_load].each do |mode|
      [[], ['--plan', '/dev/stdin']].each do |args|
        out, err, status = launch(mode, *args, input: '{')
        assert_equal 1, status.exitstatus, "#{mode} #{args}"
        assert_empty out
        assert_includes err, args.empty? ? 'refused: plan required' : 'refused: invalid JSON'
      end
    end
  end

  def test_library_require_in_fresh_child_is_pure_and_preserves_arguments
    library = File.expand_path('reconcile_owned_ip_charges_lib.rb', __dir__)
    code = <<~'CHILD'
      path = ARGV.shift
      before = ARGV.dup
      require path
      raise 'arguments changed' unless ARGV == before
      raise 'helpers missing' unless defined?(ReconcileOwnedIpCharges::Plan)
      raise 'application loaded' if defined?(ActiveRecord) || defined?(VpsAdmin)
      puts 'pure library loaded'
    CHILD
    out, err, status = Open3.capture3(RbConfig.ruby, '-e', code, '--', library,
                                    'sentinel', '--untouched', chdir: File.dirname(__dir__))
    assert status.success?
    assert_equal "pure library loaded\n", out
    assert_empty err
  end

end

# Opt in only inside the API's isolated test shell/database, after final review.
if ENV['RECONCILE_IP_DB_TEST'] == '1'
  raise 'RACK_ENV=test and VPSADMIN_API_DIR required' unless ENV['RACK_ENV'] == 'test' && ENV['VPSADMIN_API_DIR']
  api = File.expand_path(ENV.fetch('VPSADMIN_API_DIR'))
  # Match spec_helper's dependency order before starting the disposable DB.
  require 'rspec'
  require File.join(api, 'spec/support/spec_plugins')
  require File.join(api, 'spec/support/spec_seed')
  require File.join(api, 'spec/support/db_setup')
  SpecDbSetup.establish_connection!
  dbname = ActiveRecord::Base.connection_db_config.database
  raise 'test database name required' unless dbname.include?('test')
  SpecDbSetup.ensure_database_exists!
  SpecDbSetup.load_schema!
  require File.join(api, 'lib/vpsadmin')
  SpecDbSetup.seed_minimal_sysconfig!
  SpecDbSetup.seed_minimal_cluster_resources!
  SpecSeed.bootstrap!

  class ReconcileDatabaseTest < Minitest::Test
    Tool = ReconcileOwnedIpCharges
    S = 2**64

    def setup
      User.current = nil
      [IpAddress, ClusterResourceUse, ResourceLock, TransactionConfirmation, Transaction, TransactionChain].each(&:delete_all)
      net = Network.find_or_initialize_by(address: '2001:db8:100::', prefix: 48)
      net.assign_attributes(ip_version: 6, role: 'public_access', purpose: 'vps', split_prefix: 64, split_access: 'no_access', managed: false, enabled: true)
      net.save!
      LocationNetwork.find_or_create_by!(network: net, location: SpecSeed.location)
      resource = ClusterResource.find_by!(name: 'ipv6')
      resource.update_columns(max: 4 * S)
      configs = SpecSeed.user.environment_user_configs.order(:environment_id).to_a
      cfg = configs.find { |c| c.environment_id == SpecSeed.environment.id }
      quotas = configs.to_h do |c|
        q = UserClusterResource.find_by!(user: SpecSeed.user, environment_id: c.environment_id, cluster_resource: resource)
        q.update_columns(value: 4 * S)
        [c.id, q]
      end
      @ip = IpAddress.create!(ip_addr: '2001:db8:100:1::', network: net, user: SpecSeed.user, prefix: 64, size: S)
      IpAddress.create!(ip_addr: '2001:db8:100:2::', network: net, user: SpecSeed.user, prefix: 64, size: S, charged_environment_id: cfg.environment_id)
      @use = ClusterResourceUse.create!(user_cluster_resource: quotas.fetch(cfg.id), class_name: 'EnvironmentUserConfig', table_name: 'environment_user_configs', row_id: cfg.id, value: S, enabled: true, confirmed: 1)
      @data = { 'version' => 1, 'groups' => [{ 'owner_config_id' => cfg.id, 'resource' => 'ipv6' }],
                'ips' => [{ 'id' => @ip.id, 'owner_config_id' => cfg.id, 'network_id' => net.id, 'prefix' => 64, 'size' => S.to_s, 'from_environment_id' => nil, 'to_environment_id' => cfg.environment_id }],
                'usage_changes' => [{ 'id' => @use.id, 'config_id' => cfg.id, 'environment_id' => cfg.environment_id, 'resource' => 'ipv6', 'from_value' => S.to_s, 'to_value' => (2 * S).to_s }] }
      @db = Tool::Database.new(Tool::Plan.parse(JSON.generate(@data)))
    end

    def state
      (Tool::Database::MODELS.values + ['ResourceLock', 'PaperTrail::Version', 'TransactionChain', 'Transaction', 'TransactionConfirmation']).to_h do |name|
        [name, Object.const_get(name).order(:id).map(&:attributes)]
      end
    end

    def test_preview_is_select_only
      before = state
      Tool::Comparison.new(Tool::Plan.parse(JSON.generate(@data)), @db.snapshot)
      assert_equal before, state
    end

    def test_success_preserves_other_rows_allowances_and_repeat_refuses
      before = @db.fingerprint(@db.snapshot)
      @db.apply(SpecSeed.admin.id, output: StringIO.new)
      assert_equal @data['ips'][0]['to_environment_id'], @ip.reload.charged_environment_id
      assert_equal 2 * S, @use.reload.value
      after = state
      assert_raises(Tool::Refused) { @db.apply(SpecSeed.admin.id, output: StringIO.new) }
      assert_equal after, state
      assert_equal before[:quotas], @db.fingerprint(@db.snapshot)[:quotas]
      assert_equal 0, ResourceLock.count
    end

    def test_existing_reservation_refuses_without_mutation
      @ip.acquire_lock
      before = state
      assert_raises(Tool::Refused) { @db.apply(SpecSeed.admin.id, output: StringIO.new) }
      assert_equal before, state
    end

    def test_undone_confirmation_refuses_without_mutation
      TransactionChain.insert_all!([{ id: 456, type: 'TransactionChain', name: 'synthetic_fatal', size: 0, state: 5 }])
      Transaction.insert_all!([{ id: 123, transaction_chain_id: 456, handle: 0, status: 0 }])
      TransactionConfirmation.create!(class_name: 'ClusterResourceUse', table_name: 'cluster_resource_uses', row_pks: { 'id' => @use.id }, confirm_type: 3, transaction_id: 123)
      before = state
      assert_raises(Tool::Refused) { @db.apply(SpecSeed.admin.id, output: StringIO.new) }
      assert_equal before, state
    end

    def test_unrelated_queued_chain_allows_repair_and_stays_unchanged
      TransactionChain.insert_all!([{ type: 'TransactionChain', name: 'synthetic_queued', size: 0, state: 1 }])
      pending = TransactionChain.order(:id).map(&:attributes)
      before = @db.fingerprint(@db.snapshot)
      @db.apply(SpecSeed.admin.id, output: StringIO.new)
      assert_equal @data['ips'][0]['to_environment_id'], @ip.reload.charged_environment_id
      assert_equal 2 * S, @use.reload.value
      assert_equal pending, TransactionChain.order(:id).map(&:attributes)
      assert_equal before[:quotas], @db.fingerprint(@db.snapshot)[:quotas]
      assert_equal 0, ResourceLock.count
    end

    def test_later_write_failure_rolls_back_metadata_usage_audit_and_reservations
      failure = -> { raise 'synthetic later-write failure' }
      ClusterResourceUse.set_callback(:update, :before, failure)
      before = state
      assert_raises(RuntimeError) { @db.apply(SpecSeed.admin.id, output: StringIO.new) }
      assert_equal before, state
    ensure
      ClusterResourceUse.skip_callback(:update, :before, failure)
    end
  end
end

# Install after TestDb's cleanup hook: Ruby runs exit handlers in reverse order.
Minitest.autorun
