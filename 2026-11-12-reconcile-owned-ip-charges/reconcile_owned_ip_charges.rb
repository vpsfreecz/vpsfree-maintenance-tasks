#!/run/current-system/sw/bin/vpsadmin-api-ruby
# frozen_string_literal: true

require 'json'
require 'digest'
require 'optparse'
require 'bigdecimal'

module ReconcileOwnedIpCharges
  RESOURCES = %w[ipv4 ipv4_private ipv6].freeze
  class Refused < StandardError; end

  class UniqueObject < Hash
    def []=(key, value)
      raise Refused, 'duplicate JSON key' if key?(key)

      super
    end
  end

  class Plan
    attr_reader :groups, :ips, :usage_changes, :identity

    def self.parse(text)
      new(JSON.parse(text, object_class: UniqueObject))
    rescue JSON::ParserError
      raise Refused, 'invalid JSON'
    end

    def initialize(data)
      keys!(data, %w[version groups ips usage_changes])
      check(data['version'].instance_of?(Integer) && data['version'] == 1, 'unsupported version')
      %w[groups ips usage_changes].each { |key| check(data[key].is_a?(Array), "#{key} must be an array") }
      @groups = data['groups'].map do |row|
        keys!(row, %w[owner_config_id resource])
        id!(row['owner_config_id']); resource!(row['resource'])
        row.transform_keys(&:to_sym)
      end
      check(!groups.empty?, 'groups must not be empty')
      @ips = data['ips'].map do |row|
        keys!(row, %w[id owner_config_id network_id prefix size from_environment_id to_environment_id])
        %w[id owner_config_id network_id to_environment_id].each { |key| id!(row[key]) }
        check(row['prefix'].instance_of?(Integer) && row['prefix'].between?(0, 128), 'invalid prefix')
        amount!(row['size']); check(row['size'] != '0', 'size must be positive')
        check(row['from_environment_id'].nil?, 'from_environment_id must be null')
        row.transform_keys(&:to_sym)
      end
      @usage_changes = data['usage_changes'].map do |row|
        keys!(row, %w[id config_id environment_id resource from_value to_value])
        %w[id config_id environment_id].each { |key| id!(row[key]) }
        resource!(row['resource']); amount!(row['from_value']); amount!(row['to_value'])
        row.transform_keys(&:to_sym)
      end
      unique!(groups.map { |row| row.values_at(:owner_config_id, :resource) })
      unique!(ips.map { |row| row[:id] }); unique!(usage_changes.map { |row| row[:id] })
      @identity = Digest::SHA256.hexdigest(JSON.generate(data))
    end

    private

    def check(ok, message)
      raise Refused, message unless ok
    end

    def keys!(row, expected)
      check(row.is_a?(Hash) && row.keys.sort == expected.sort, 'unexpected or missing plan keys')
    end

    def id!(value)
      check(value.instance_of?(Integer) && value.positive? && value <= (2**63 - 1), 'invalid ID')
    end

    def amount!(value)
      check(value.is_a?(String) && /\A(?:0|[1-9][0-9]{0,39})\z/.match?(value), 'invalid integer string')
    end

    def resource!(value)
      check(RESOURCES.include?(value), 'unsupported resource')
    end

    def unique!(values)
      check(values.uniq.length == values.length, 'duplicate plan identity')
    end
  end

  # Comparison is independent of ActiveRecord; inputs are records from one snapshot.
  class Comparison
    attr_reader :changes, :inventory, :contributing_ips, :groups

    def initialize(plan, rows)
      @plan = plan
      @rows = rows
      @maps = rows.transform_values { |records| records.to_h { |record| [record.id, record] } }
      @groups = plan.groups.map { |g| [find(:configs, g[:owner_config_id]).user_id, g[:resource]] }
      refuse('ambiguous owner/resource groups') unless groups.uniq == groups
      @inventory = Hash.new(0)
      @contributing_ips = []
      @mapped = {}
      plan.ips.each do |input|
        anchor = find(:configs, input[:owner_config_id])
        ip = find(:ips, input[:id])
        net = find(:networks, ip.network_id)
        key = [anchor.user_id, resource(net)]
        refuse("IP #{ip.id} is outside groups") unless groups.include?(key)
        expected = [anchor.user_id, input[:network_id], input[:prefix], Integer(input[:size]), nil, nil, nil]
        actual = [ip.user_id, ip.network_id, ip.prefix, integer(ip.size), ip.charged_environment_id,
                  ip.network_interface_id, ip.route_via_id]
        refuse("stale IP #{ip.id}") unless actual == expected
        env = input[:to_environment_id]
        find(:environments, env)
        config!(anchor.user_id, env)
        available = rows[:links].any? do |link|
          link.network_id == net.id && find(:locations, link.location_id).environment_id == env
        end
        refuse("IP #{ip.id} destination unavailable") unless available
        @mapped[ip.id] = env
      end
      rows[:ips].each { |ip| add_ip(ip) }
      @changes = compare_uses
      refuse('computed usage changes differ from explicit plan') unless sorted(changes) == sorted(plan.usage_changes)
    end

    def resource(net)
      return 'ipv6' if net.ip_version == 6
      return 'ipv4' if net.ip_version == 4 && net.role == 'public_access'
      return 'ipv4_private' if net.ip_version == 4 && net.role == 'private_access'

      refuse("unsupported network #{net.id}")
    end

    def integer(value)
      text = value.is_a?(BigDecimal) ? value.to_s('F') : value.to_s
      refuse('nonintegral database amount') unless /\A(?:0|[1-9][0-9]*)(?:\.0+)?\z/.match?(text)
      Integer(text.split('.').first, 10)
    end

    def find(kind, id)
      @maps.fetch(kind)[id] || refuse("missing #{kind} #{id}")
    end

    private

    def refuse(message)
      raise Refused, message
    end

    def sorted(changes)
      changes.sort_by { |change| change.fetch(:id) }
    end

    def config!(user, env)
      candidates = @rows[:configs].select { |cfg| cfg.user_id == user && cfg.environment_id == env }
      refuse("config cardinality in environment #{env}") unless candidates.one?
      find(:environments, env)
      candidates.first
    end

    def add_ip(ip)
      net = find(:networks, ip.network_id)
      res = resource(net)
      interface = ip.network_interface_id && find(:interfaces, ip.network_interface_id)
      vps = interface&.vps_id && find(:vpses, interface.vps_id)
      owner = ip.user_id || vps&.user_id
      return unless groups.include?([owner, res])

      refuse("unsupported network purpose #{net.id}") unless %w[any vps].include?(net.purpose)
      size = integer(ip.size)
      bits = net.ip_version == 4 ? 32 : 128
      refuse("invalid size IP #{ip.id}") unless ip.prefix.between?(0, bits) && size == 2**(bits - ip.prefix)
      if interface
        refuse("unsupported interface #{interface.id}") if interface.export_id || !vps
        refuse("owner/state VPS #{vps.id}") unless vps.user_id == owner &&
          %w[active suspended].include?(vps.object_state) && vps.confirmed?
      end
      if ip.route_via_id
        host = find(:hosts, ip.route_via_id)
        parent = find(:ips, host.ip_address_id)
        refuse("invalid route IP #{ip.id}") unless interface && !host.order.nil? &&
          parent.network_interface_id == interface.id && resource(find(:networks, parent.network_id)) == res &&
          (parent.user_id || vps&.user_id) == owner
      end
      env = @mapped.fetch(ip.id, ip.charged_environment_id)
      refuse("unlisted missing charge IP #{ip.id}") unless env
      config!(owner, env)
      @inventory[[owner, res, env]] += size
      @contributing_ips << ip
    end

    def compare_uses
      changes = []
      groups.each do |owner, res|
        configs = @rows[:configs].select { |cfg| cfg.user_id == owner }
        quotas = @rows[:quotas].select do |q|
          q.user_id == owner && find(:resources, q.cluster_resource_id).name == res
        end
        config_ids = configs.map(&:id)
        uses = @rows[:uses].select do |use|
          quotas.any? { |q| q.id == use.user_cluster_resource_id } ||
            (use.class_name == 'EnvironmentUserConfig' && use.table_name == 'environment_user_configs' &&
             config_ids.include?(use.row_id) &&
             find(:resources, find(:quotas, use.user_cluster_resource_id).cluster_resource_id).name == res)
        end
        uses.each do |use|
          cfg = find(:configs, use.row_id)
          q = find(:quotas, use.user_cluster_resource_id)
          refuse("unexpected usage #{use.id}") unless use.class_name == 'EnvironmentUserConfig' &&
            use.table_name == 'environment_user_configs' && cfg.user_id == owner && q.user_id == owner &&
            cfg.environment_id == q.environment_id && find(:resources, q.cluster_resource_id).name == res &&
            use.enabled && use.confirmed? && use.admin_lock_type == 'no_lock' && use.admin_limit.nil?
          integer(use.value)
        end
        envs = (configs.map(&:environment_id) + quotas.map(&:environment_id) +
                inventory.keys.select { |k| k[0, 2] == [owner, res] }.map(&:last)).uniq.sort
        envs.each do |env|
          cfg = config!(owner, env)
          qs = quotas.select { |q| q.environment_id == env }
          refuse("allowance cardinality config #{cfg.id}") unless qs.one?
          q = qs.first
          matching = uses.select { |use| use.row_id == cfg.id }
          refuse("usage cardinality config #{cfg.id}") if matching.length > 1
          value = inventory[[owner, res, env]]
          use = matching.first
          refuse("missing required usage config #{cfg.id}") if !use && value != 0
          next unless use && integer(use.value) != value
          refuse("quota exceeded config #{cfg.id}") if value > integer(q.value)
          changes << { id: use.id, config_id: cfg.id, environment_id: env, resource: res,
                       from_value: integer(use.value).to_s, to_value: value.to_s }
        end
      end
      changes
    end
  end

  class Database
    MODELS = { configs: 'EnvironmentUserConfig', environments: 'Environment', ips: 'IpAddress',
               networks: 'Network', links: 'LocationNetwork', locations: 'Location', interfaces: 'NetworkInterface',
               vpses: 'Vps', hosts: 'HostIpAddress', quotas: 'UserClusterResource',
               uses: 'ClusterResourceUse', resources: 'ClusterResource' }.freeze

    def initialize(plan)
      @plan = plan
      MODELS.each_value { |name| Object.const_get(name) }
      raise Refused, 'unsupported reservation API' unless IpAddress.method_defined?(:lock_current!) &&
        UserClusterResource.method_defined?(:acquire_lock) && Vps.method_defined?(:acquire_lock) &&
        ClusterResourceUse.method_defined?(:confirmed?) && TransactionConfirmation.column_names.include?('done')
    end

    def snapshot(lock: false)
      anchors = EnvironmentUserConfig.where(id: @plan.groups.map { |g| g[:owner_config_id] }).to_a
      owners = anchors.map(&:user_id).uniq
      raise Refused, 'missing accounting owner' unless User.unscoped.where(id: owners).pluck(:id).sort == owners.sort
      owned = IpAddress.where(user_id: owners)
      free = IpAddress.joins('JOIN network_interfaces ri ON ri.id = ip_addresses.network_interface_id ' \
                            'JOIN vpses rv ON rv.id = ri.vps_id').where(user_id: nil).where('rv.user_id IN (?)', owners)
      ids = (owned.pluck(:id) + free.pluck(:id) + @plan.ips.map { |ip| ip[:id] }).uniq
      network_ids = IpAddress.where(id: ids).pluck(:network_id).uniq
      if lock
        User.unscoped.where(id: owners).order(:id).lock.load
        Network.where(id: network_ids).order(:id).lock.load
      end
      rows = {}
      fetch = lambda do |scope|
        scope = scope.order(:id)
        scope = scope.lock if lock
        scope.to_a
      end
      rows[:ips] = fetch.call(IpAddress.where(id: ids))
      rows[:networks] = fetch.call(Network.where(id: network_ids))
      rows[:configs] = fetch.call(EnvironmentUserConfig.where(user_id: owners))
      rows[:environments] = fetch.call(Environment.where(id: rows[:configs].map(&:environment_id) +
        @plan.ips.map { |ip| ip[:to_environment_id] }))
      rows[:links] = fetch.call(LocationNetwork.where(network_id: network_ids))
      rows[:locations] = fetch.call(Location.where(id: rows[:links].map(&:location_id)))
      rows[:interfaces] = fetch.call(NetworkInterface.where(id: rows[:ips].filter_map(&:network_interface_id)))
      rows[:vpses] = fetch.call(Vps.unscoped.where(id: rows[:interfaces].filter_map(&:vps_id)))
      rows[:hosts] = fetch.call(HostIpAddress.where(id: rows[:ips].filter_map(&:route_via_id)))
      rows[:resources] = fetch.call(ClusterResource.where(name: RESOURCES))
      rows[:quotas] = fetch.call(UserClusterResource.where(user_id: owners, cluster_resource_id: rows[:resources].map(&:id)))
      rows[:uses] = fetch.call(ClusterResourceUse.where(user_cluster_resource_id: rows[:quotas].map(&:id)).or(
        ClusterResourceUse.where(class_name: 'EnvironmentUserConfig', table_name: 'environment_user_configs',
                                 row_id: rows[:configs].map(&:id))))
      rows
    end

    def targets(comparison, rows)
      selected_owners = comparison.groups.map(&:first)
      selected_quotas = rows[:quotas].select do |q|
        res = rows[:resources].find { |r| r.id == q.cluster_resource_id }
        comparison.groups.include?([q.user_id, res.name])
      end
      { 'IpAddress' => comparison.contributing_ips.map(&:id),
        'Vps' => comparison.contributing_ips.filter_map(&:network_interface_id).filter_map do |id|
          rows[:interfaces].find { |ni| ni.id == id }&.vps_id
        end,
        'UserClusterResource' => selected_quotas.map(&:id),
        'ClusterResourceUse' => rows[:uses].select { |u| selected_quotas.any? { |q| q.id == u.user_cluster_resource_id } }.map(&:id),
        'EnvironmentUserConfig' => rows[:configs].select { |c| selected_owners.include?(c.user_id) }.map(&:id),
        'NetworkInterface' => comparison.contributing_ips.filter_map(&:network_interface_id),
        'HostIpAddress' => comparison.contributing_ips.filter_map(&:route_via_id),
        'Network' => comparison.contributing_ips.map(&:network_id),
        'User' => selected_owners }.transform_values(&:uniq)
    end

    def blockers!(targets)
      active = TransactionChain.where(state: %i[staged queued rollbacking]).order(:id).pluck(:id)
      raise Refused, "active chains #{active.join(',')}" unless active.empty?
      targets.each do |name, ids|
        locks = ResourceLock.where(resource: name, row_id: ids).order(:id).pluck(:id)
        raise Refused, "existing reservations #{locks.join(',')}" unless locks.empty?
      end
      selected = targets
      # row_pks is the existing serialized scalar key map; never read attr_changes.
      TransactionConfirmation.where.not(done: 1).where(class_name: selected.keys)
                             .select(:id, :class_name, :table_name, :row_pks).order(:id).each do |confirmation|
        keys = confirmation.row_pks
        unless keys.is_a?(Hash) && keys.keys == ['id'] && keys['id'].is_a?(Integer)
          raise Refused, "unsupported confirmation keys #{confirmation.id}"
        end
        if selected.fetch(confirmation.class_name).include?(keys['id'])
          raise Refused, "pending confirmation #{confirmation.id}"
        end
      end
    end

    def apply(admin_id, output: $stdout)
      previous_user = User.current
      previous_audit = PaperTrail.request.whodunnit
      admin = User.unscoped.find_by(id: admin_id)
      raise Refused, 'administrator required' unless admin && admin.role == :admin
      User.current = admin
      PaperTrail.request.whodunnit = admin.id.to_s
      ActiveRecord::Base.transaction(isolation: :serializable) do
        rows = snapshot(lock: true)
        comparison = Comparison.new(@plan, rows)
        selection = targets(comparison, rows)
        blockers!(selection)
        reservations = %w[IpAddress Vps UserClusterResource].flat_map do |name|
          selection.fetch(name).sort.map { |id| Object.const_get(name).find(id).acquire_lock }
        end
        before = fingerprint(rows)
        output.puts JSON.generate(status: 'validated_before_commit', plan: @plan.identity,
                                  ips: @plan.ips, usage_changes: @plan.usage_changes)
        output.flush
        @plan.ips.each do |input|
          IpAddress.find(input[:id]).update!(charged_environment_id: input[:to_environment_id])
        end
        @plan.usage_changes.each do |input|
          use = ClusterResourceUse.find(input[:id])
          use.update!(value: Integer(input[:to_value]))
        end
        verify_post!(before, snapshot(lock: true))
        reservations.reverse_each(&:destroy!)
      end
      output.puts JSON.generate(status: 'committed', plan: @plan.identity,
                                ips: @plan.ips, usage_changes: @plan.usage_changes)
      output.flush
    ensure
      User.current = previous_user if defined?(previous_user)
      PaperTrail.request.whodunnit = previous_audit if defined?(previous_audit)
    end

    def fingerprint(rows)
      # Includes unrelated owner resources/allocations so callbacks cannot silently
      # modify them. Timestamps are retained; expected writes are removed below.
      rows.transform_values { |records| records.to_h { |r| [r.id, r.attributes] } }
    end

    def verify_post!(before, rows)
      expected = Marshal.load(Marshal.dump(before))
      @plan.ips.each { |ip| expected[:ips].fetch(ip[:id])['charged_environment_id'] = ip[:to_environment_id] }
      @plan.usage_changes.each do |change|
        expected[:uses].fetch(change[:id])['value'] = BigDecimal(change[:to_value])
      end
      raise Refused, 'unexpected post-state' unless fingerprint(rows) == expected
      post = Plan.new('version' => 1, 'groups' => @plan.groups.map { |g| g.transform_keys(&:to_s) },
                      'ips' => [], 'usage_changes' => [])
      Comparison.new(post, rows)
    end
  end

  def self.run(argv, output: $stdout, error: $stderr)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: reconcile_owned_ip_charges.rb --plan PATH [--apply --writers-quiesced --admin-id ID]'
      opts.on('--plan PATH', 'Explicit JSON plan; preview is read-only') { |v| options[:path] = v }
      opts.on('--apply', 'Apply the exact plan atomically during maintenance') { options[:apply] = true }
      opts.on('--writers-quiesced', 'Attest all writers stopped and older work drained') { options[:quiesced] = true }
      opts.on('--admin-id ID', Integer, 'Administrator audit identity') { |v| options[:admin] = v }
      opts.on('-h', '--help', 'Show help') { output.puts opts; return 0 }
    end
    parser.parse!(argv)
    raise Refused, 'plan required; unexpected arguments' unless options[:path] && argv.empty?
    if options[:apply]
      raise Refused, 'apply requires quiesced writers and positive admin ID' unless options[:quiesced] && options[:admin]&.positive?
    elsif options[:admin] || options[:quiesced]
      raise Refused, 'maintenance options require --apply'
    end
    plan = Plan.parse(File.read(options[:path]))
    require 'vpsadmin'
    database = Database.new(plan)
    if options[:apply]
      database.apply(options[:admin], output:)
    else
      comparison = Comparison.new(plan, database.snapshot)
      output.puts JSON.generate(status: 'preview', plan: plan.identity, ips: plan.ips,
                                usage_changes: comparison.changes)
    end
    0
  rescue Refused, OptionParser::ParseError, SystemCallError => e
    error.puts "refused: #{e.message}"
    1
  rescue StandardError => e
    # Adapter/model errors can contain SQL values or personal validation text.
    error.puts "operation failed (#{e.class}); inspect pre/post state before retrying"
    1
  end
end

exit ReconcileOwnedIpCharges.run(ARGV) if $PROGRAM_NAME == __FILE__
