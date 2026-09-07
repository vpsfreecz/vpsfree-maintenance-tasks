#!/run/current-system/sw/bin/vpsadmin-api-ruby
# frozen_string_literal: true

# Restore missing charging environments on owned IP addresses intended for VPS
# use.
#
# The task derives the environment from the assigned VPS or, for an unassigned
# address, from the network's primary location. Existing IP resource usage must
# already agree with every proposed assignment. The task never changes cluster
# resource limits or usage.
#
# Usage:
#   ./fix_ip_charged_environments.rb --admin-login LOGIN
#
# A hard-killed process can leave ownerless ResourceLock rows. Before retrying,
# confirm that no copy of this task is running, then inspect and remove only the
# ResourceLock IDs printed by this task after confirmation.

require 'bigdecimal'
require 'digest'
require 'json'
require 'optparse'
require 'vpsadmin'

module FixIpChargedEnvironments
  RESOURCE_NAMES = %i[ipv4 ipv4_private ipv6].freeze
  TARGET_NETWORK_PURPOSES = %w[any vps].freeze

  class StalePlan < StandardError; end

  # A snapshot of safe and blocked owner/resource groups.
  class Plan
    attr_reader :groups

    def initialize(groups)
      @groups = groups.sort_by { |group| [group.fetch(:user_id), group.fetch(:resource)] }
    end

    def safe_groups
      groups.reject { |group| group.fetch(:blocked) }
    end

    def blocked_groups
      groups.select { |group| group.fetch(:blocked) }
    end

    def changes
      safe_groups.flat_map { |group| group.fetch(:items) }.sort_by { |item| item.fetch(:ip_id) }
    end

    def signature
      Digest::SHA256.hexdigest(JSON.generate(groups))
    end
  end

  # Builds UserClusterResource scopes for the exact owner/resource groups in a
  # plan, without locking unrelated combinations.
  module ResourceQueries
    module_function

    def user_resources(groups)
      pairs = groups.map do |group|
        [group.fetch(:user_id), group.fetch(:resource)]
      end.uniq
      return UserClusterResource.none if pairs.empty?

      user_resources = UserClusterResource.arel_table
      cluster_resources = ClusterResource.arel_table
      conditions = pairs.map do |user_id, resource|
        user_resources[:user_id].eq(user_id).and(
          cluster_resources[:name].eq(resource)
        )
      end

      UserClusterResource
        .joins(:cluster_resource)
        .where(conditions.reduce { |left, right| left.or(right) })
    end
  end

  # Finds affected IP addresses and validates the inferred environment against
  # the user's recorded cluster resource use.
  class PlanBuilder
    def build
      uncharged = uncharged_addresses
      targets = uncharged.select { |ip| ip.user_id && target?(ip) }
      groups = targets.group_by { |ip| [ip.user_id, resource_for(ip)] }

      Plan.new(
        groups.map do |(user_id, resource), ips|
          build_group(user_id, resource, ips, uncharged)
        end
      )
    end

    def accounting_for(user_id, resource, proposed_items)
      expected = Hash.new { |hash, key| hash[key] = BigDecimal('0') }
      reasons = []

      owned_addresses(user_id).each do |ip|
        next unless resource_for(ip) == resource

        expected[ip.charged_environment_id] += decimal(ip.size)
      end

      freely_assigned_addresses(user_id).each do |ip|
        next unless resource_for(ip) == resource

        expected[ip.charged_environment_id] += decimal(ip.size)
      end

      proposed_items.each do |item|
        environment_id = item[:target_environment_id]
        next if environment_id.nil?

        expected[environment_id] += decimal(item.fetch(:size))
      end

      configs = EnvironmentUserConfig
                .where(user_id:)
                .includes(:environment)
                .order(:environment_id, :id)
                .to_a
      configs_by_id = configs.to_h { |config| [config.id, config] }
      configs_by_environment = configs.group_by(&:environment_id)

      configs.each do |config|
        next if config.environment

        reasons << "EnvironmentUserConfig ##{config.id} points to missing " \
                   "environment ##{config.environment_id}"
      end

      uses = resource_uses(user_id, resource, configs.map(&:id))
      uses_by_config = uses.group_by(&:row_id)

      uses_by_config.each do |config_id, rows|
        config = configs_by_id[config_id]
        if config.nil?
          reasons << "resource use #{rows.map(&:id).join(',')} points to missing " \
                     "EnvironmentUserConfig ##{config_id}"
          next
        end

        rows.each do |use|
          user_resource = use.user_cluster_resource
          next if user_resource.user_id == user_id &&
                  user_resource.environment_id == config.environment_id

          reasons << "resource use ##{use.id} belongs to UserClusterResource " \
                     "##{user_resource.id} for another user or environment"
        end
      end

      environment_ids = (
        configs.map(&:environment_id) +
        expected.keys.compact +
        uses.map { |use| use.user_cluster_resource.environment_id }
      ).uniq.sort

      usage = environment_ids.map do |environment_id|
        environment_configs = configs_by_environment.fetch(environment_id, [])
        if environment_configs.length != 1
          reasons << "environment ##{environment_id} has " \
                     "#{environment_configs.length} EnvironmentUserConfig rows for user ##{user_id}"
        end

        config = environment_configs.first
        rows = config ? uses_by_config.fetch(config.id, []) : []

        if rows.length > 1
          reasons << "EnvironmentUserConfig ##{config.id} has multiple #{resource} " \
                     "resource uses: #{rows.map(&:id).join(',')}"
        end

        rows.each do |use|
          unless use.enabled && use.confirmed?
            reasons << "resource use ##{use.id} is enabled=#{use.enabled.inspect}, " \
                       "confirmed=#{use.confirmed}"
          end
        end

        actual = rows.sum(BigDecimal('0')) { |use| decimal(use.value) }
        expected_value = expected[environment_id]
        environment = config&.environment || Environment.find_by(id: environment_id)
        reasons << "environment ##{environment_id} is missing" if environment.nil?

        if actual != expected_value
          reasons << "#{environment_label(environment_id, environment)} has recorded " \
                     "#{resource}=#{amount(actual)}, expected #{amount(expected_value)}"
        end

        {
          environment_id:,
          environment_label: environment&.label,
          actual: amount(actual),
          expected: amount(expected_value),
          resource_use_ids: rows.map(&:id)
        }
      end

      [usage, reasons.uniq.sort]
    end

    def resource_for(ip)
      network = ip.network
      return nil if network.nil?
      return nil unless [4, 6].include?(network.ip_version)
      return nil unless %w[public_access private_access].include?(network.role)

      resource = ip.cluster_resource
      RESOURCE_NAMES.include?(resource) ? resource : nil
    end

    def relevant_uncharged_addresses(user_id, resource)
      select_relevant_uncharged(uncharged_addresses, user_id, resource)
    end

    protected

    def uncharged_addresses
      base = IpAddress.where(charged_environment_id: nil)
      owned = preload_addresses(base.where.not(user_id: nil))
      userless_assigned = preload_addresses(
        base
          .joins(network_interface: :vps)
          .where(user_id: nil)
      )

      (owned + userless_assigned).uniq(&:id).sort_by(&:id)
    end

    def owned_addresses(user_id)
      IpAddress
        .where(user_id:)
        .where.not(charged_environment_id: nil)
        .includes(:network)
        .order(:id)
        .to_a
    end

    def freely_assigned_addresses(user_id)
      IpAddress
        .joins(network_interface: :vps)
        .where(user_id: nil, vpses: { user_id: })
        .where.not(charged_environment_id: nil)
        .includes(:network)
        .order(:id)
        .to_a
    end

    def target?(ip)
      network = ip.network
      return false unless network && TARGET_NETWORK_PURPOSES.include?(network.purpose)
      return true if ip.network_interface_id.nil?

      interface = ip.network_interface
      interface&.vps_id && interface.export_id.nil?
    end

    def preload_addresses(scope)
      scope
        .includes(
          :user,
          {
            network: [
              :primary_location,
              { location_networks: { location: :environment } }
            ]
          },
          {
            network_interface: {
              vps: { node: { location: :environment } }
            }
          }
        )
        .order(:id)
        .to_a
    end

    def select_relevant_uncharged(addresses, user_id, resource)
      addresses.select do |ip|
        next false unless effective_user_id(ip) == user_id

        ip_resource = resource_for(ip)
        ip_resource.nil? || ip_resource == resource
      end
    end

    def effective_user_id(ip)
      ip.user_id || ip.network_interface&.vps&.user_id
    end

    def build_group(user_id, resource, ips, all_uncharged)
      items = ips.map { |ip| build_item(ip, resource) }
      user = ips.first.user
      reasons = items.flat_map { |item| item.fetch(:errors) }

      if user.nil?
        reasons << "owner ##{user_id} is not available through the User model"
      end

      item_ids = ips.map(&:id)
      out_of_scope = select_relevant_uncharged(
        all_uncharged,
        user_id,
        resource
      ).reject { |ip| item_ids.include?(ip.id) }

      out_of_scope.each do |ip|
        reasons << "uncharged out-of-scope IP #{ip_label(ip)} " \
                   "(#{out_of_scope_reason(ip)}) prevents complete accounting"
      end

      usage = []
      if reasons.empty?
        usage, accounting_reasons = accounting_for(user_id, resource, items)
        reasons.concat(accounting_reasons)
      end

      {
        user_id:,
        user_login: user&.login,
        resource: resource ? resource.to_s : 'unknown',
        items: items.sort_by { |item| item.fetch(:ip_id) },
        usage:,
        blocked: reasons.any?,
        reasons: reasons.uniq.sort
      }
    end

    def build_item(ip, resource)
      network = ip.network
      errors = []
      target_environment = nil
      selected_location = nil
      selection_reason = nil
      assignment = assignment_for(ip)

      if resource.nil? || !RESOURCE_NAMES.include?(resource)
        errors << "#{ip_label(ip)} has unsupported network version or role"
      end

      if ip.network_interface_id
        interface = ip.network_interface
        vps = interface&.vps
        node = vps&.node
        location = node&.location
        target_environment = location&.environment
        selected_location = location
        selection_reason = vps ? "current VPS ##{vps.id}" : 'current VPS'

        errors << "#{ip_label(ip)} points to a missing network interface" if interface.nil?
        errors << "#{ip_label(ip)} is not attached to a VPS" if interface && vps.nil?
        errors << "#{ip_label(ip)} has a VPS without a node location" if vps && location.nil?

        if vps && vps.user_id != ip.user_id
          errors << "#{ip_label(ip)} owner ##{ip.user_id} differs from VPS " \
                    "##{vps.id} owner ##{vps.user_id}"
        end

        if network && location &&
           network.location_networks.none? { |link| link.location_id == location.id }
          errors << "#{ip_label(ip)} network ##{network.id} is not available at " \
                    "VPS location ##{location.id}"
        end
      else
        primary_links = network.location_networks.select { |link| link.primary == true }
        selected_location = network.primary_location
        target_environment = selected_location&.environment
        selection_reason = 'network primary location'

        if selected_location.nil?
          errors << "#{ip_label(ip)} network ##{network.id} has no primary location"
        end

        if primary_links.length != 1
          errors << "#{ip_label(ip)} network ##{network.id} has " \
                    "#{primary_links.length} primary LocationNetwork rows"
        elsif selected_location && primary_links.first.location_id != selected_location.id
          errors << "#{ip_label(ip)} network ##{network.id} primary location " \
                    "disagrees with LocationNetwork ##{primary_links.first.id}"
        end
      end

      if target_environment && ip.user
        config_count = EnvironmentUserConfig.where(
          user_id: ip.user_id,
          environment_id: target_environment.id
        ).count

        if config_count != 1
          errors << "#{ip_label(ip)} owner ##{ip.user_id} has #{config_count} " \
                    "EnvironmentUserConfig rows in environment ##{target_environment.id}"
        end
      elsif target_environment.nil?
        errors << "#{ip_label(ip)} has no target environment"
      end

      {
        ip_id: ip.id,
        ip_addr: ip.ip_addr,
        prefix: ip.prefix,
        size: amount(ip.size),
        owner_id: ip.user_id,
        owner_login: ip.user&.login,
        network_id: network&.id,
        network_addr: network && "#{network.address}/#{network.prefix}",
        network_purpose: network&.purpose,
        network_interface_id: ip.network_interface_id,
        assignment:,
        target_environment_id: target_environment&.id,
        target_environment_label: target_environment&.label,
        selected_location_id: selected_location&.id,
        selected_location_label: selected_location&.label,
        selection_reason:,
        resource: resource&.to_s,
        errors: errors.uniq.sort
      }
    end

    def assignment_for(ip)
      return { type: 'unassigned' } if ip.network_interface_id.nil?

      interface = ip.network_interface
      vps = interface&.vps
      node = vps&.node
      location = node&.location
      environment = location&.environment

      {
        type: 'vps',
        network_interface_id: interface&.id,
        vps_id: vps&.id,
        vps_hostname: vps&.hostname,
        node_id: node&.id,
        node_name: node&.name,
        location_id: location&.id,
        location_label: location&.label,
        environment_id: environment&.id,
        environment_label: environment&.label
      }
    end

    def out_of_scope_reason(ip)
      network = ip.network
      return 'missing network' if network.nil?
      return "network purpose #{network.purpose}" unless TARGET_NETWORK_PURPOSES.include?(network.purpose)
      return 'unsupported network version or role' if resource_for(ip).nil?
      return 'unassigned' if ip.network_interface_id.nil?

      interface = ip.network_interface
      return 'missing network interface' if interface.nil?
      return "export interface ##{interface.id}" if interface.export_id
      return "userless address assigned to VPS ##{interface.vps_id}" if ip.user_id.nil?

      "interface ##{interface.id} has no VPS"
    end

    def resource_uses(user_id, resource, config_ids)
      base = ClusterResourceUse
             .includes(user_cluster_resource: :cluster_resource)
             .joins(user_cluster_resource: :cluster_resource)
             .where(
               class_name: 'EnvironmentUserConfig',
               table_name: 'environment_user_configs',
               cluster_resources: { name: resource.to_s }
             )
      owner_uses = base.where(user_cluster_resources: { user_id: }).to_a
      config_uses = base.where(row_id: config_ids).to_a

      (owner_uses + config_uses).uniq(&:id).sort_by(&:id)
    end

    def ip_label(ip)
      "##{ip.id} #{ip.ip_addr}/#{ip.prefix}"
    end

    def environment_label(id, environment)
      environment ? "#{environment.label} (##{id})" : "environment ##{id}"
    end

    def decimal(value)
      value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
    end

    def amount(value)
      number = decimal(value)
      number.frac.zero? ? number.to_i.to_s : number.to_s('F')
    end
  end

  # Formats the complete operator preview.
  class Printer
    def initialize(output)
      @output = output
    end

    def print(plan)
      output.puts 'Proposed changes'
      output.puts '================'
      output.puts 'Only charged_environment_id will be changed for the IPs below.'

      if plan.changes.empty?
        output.puts 'None.'
      else
        plan.safe_groups.each do |group|
          print_group_header(group)
          group.fetch(:items).each { |item| print_item(item, change: true) }
          print_usage(group)
        end
      end

      output.puts
      output.puts 'Blocked groups'
      output.puts '=============='
      output.puts 'The groups below will not be changed.'

      if plan.blocked_groups.empty?
        output.puts 'None.'
      else
        plan.blocked_groups.each do |group|
          print_group_header(group)
          group.fetch(:items).each { |item| print_item(item, change: false) }
          print_usage(group)
          group.fetch(:reasons).each { |reason| output.puts "  BLOCKED: #{reason}" }
        end
      end

      output.puts
      output.puts "#{plan.changes.length} IP addresses ready to update"
      output.puts "#{plan.blocked_groups.length} owner/resource groups blocked"
    end

    protected

    attr_reader :output

    def print_group_header(group)
      login = group[:user_login] || 'unknown login'
      output.puts
      output.puts "User ##{group.fetch(:user_id)} #{login}, resource #{group.fetch(:resource)}"
    end

    def print_item(item, change:)
      output.puts "  IP ##{item.fetch(:ip_id)} #{item.fetch(:ip_addr)}/#{item.fetch(:prefix)}"
      output.puts "    owner: ##{item.fetch(:owner_id)} #{item[:owner_login] || 'unknown login'}"
      output.puts "    network: ##{item.fetch(:network_id)} #{item.fetch(:network_addr)} " \
                  "(purpose #{item.fetch(:network_purpose)})"
      output.puts "    assignment: #{assignment(item.fetch(:assignment))}"

      if item[:target_environment_id]
        label = change ? 'change: charged environment NULL -> ' : 'inferred target: '
        output.puts "    #{label}" \
                    "#{item.fetch(:target_environment_label)} " \
                    "(##{item.fetch(:target_environment_id)})"
        output.puts "    selected by: #{item.fetch(:selection_reason)}, location " \
                    "#{item.fetch(:selected_location_label)} " \
                    "(##{item.fetch(:selected_location_id)})"
      else
        output.puts change ? '    change: no target environment' : '    inferred target: none'
      end

      item.fetch(:errors).each { |error| output.puts "    error: #{error}" }
    end

    def print_usage(group)
      group.fetch(:usage).each do |row|
        label = row[:environment_label] || 'unknown environment'
        output.puts "  accounting #{label} (##{row.fetch(:environment_id)}): " \
                    "recorded #{row.fetch(:actual)}, expected #{row.fetch(:expected)}"
      end
    end

    def assignment(data)
      return 'unassigned' if data.fetch(:type) == 'unassigned'

      "VPS ##{data[:vps_id]} #{data[:vps_hostname] || 'unknown hostname'}, " \
        "interface ##{data[:network_interface_id]}, node ##{data[:node_id]} " \
        "#{data[:node_name] || 'unknown node'}, location ##{data[:location_id]} " \
        "#{data[:location_label] || 'unknown location'}, environment " \
        "##{data[:environment_id]} #{data[:environment_label] || 'unknown environment'}"
    end
  end

  # Holds vpsAdmin application locks while the approved plan is applied.
  class ApplicationLocks
    def initialize(plan, output: $stdout)
      @plan = plan
      @output = output
      @locks = []
    end

    def synchronize
      output.puts 'Acquiring application locks:'

      lockable_objects.each do |object|
        lock = object.acquire_lock
        @locks << lock
        output.puts "  ResourceLock ##{lock.id}: #{object.class.name} ##{object.id}"
        output.flush
      end

      yield
    ensure
      @locks.reverse_each do |lock|
        lock.release if lock.persisted?
      rescue ActiveRecord::RecordNotFound
        nil
      end
    end

    protected

    attr_reader :output, :plan

    def lockable_objects
      changes = plan.changes
      ip_ids = changes.map { |item| item.fetch(:ip_id) }
      user_ids = plan.safe_groups.map { |group| group.fetch(:user_id) }.uniq
      ips = IpAddress.where(id: ip_ids).includes(:network, network_interface: :vps).to_a
      interfaces = ips.filter_map(&:network_interface)
      vpses = interfaces.filter_map(&:vps)

      user_resources = ResourceQueries.user_resources(plan.safe_groups).to_a

      (
        User.unscoped.where(id: user_ids).to_a +
        ips +
        ips.map(&:network) +
        interfaces +
        vpses +
        user_resources
      ).compact.uniq { |object| [object.class.name, object.id] }
       .sort_by { |object| [object.class.name, object.id] }
    end
  end

  # Revalidates and applies an approved plan in one database transaction.
  class Applier
    def initialize(plan, output: $stdout)
      @plan = plan
      @output = output
    end

    def apply
      ApplicationLocks.new(plan, output:).synchronize do
        ActiveRecord::Base.transaction(isolation: :serializable) do
          lock_database_rows
          fresh_plan = PlanBuilder.new.build

          unless fresh_plan.signature == plan.signature
            raise StalePlan,
                  'data changed after confirmation; review a newly generated plan'
          end

          resource_snapshot = current_resource_snapshot

          plan.changes.each do |item|
            IpAddress.find(item.fetch(:ip_id)).update!(
              charged_environment_id: item.fetch(:target_environment_id)
            )
          end

          verify_changes!
          verify_accounting!

          unless current_resource_snapshot == resource_snapshot
            raise 'cluster resource usage changed while applying the repair'
          end
        end
      end
    end

    protected

    attr_reader :output, :plan

    def lock_database_rows
      user_ids = plan.safe_groups.map { |group| group.fetch(:user_id) }.uniq
      change_ids = plan.changes.map { |item| item.fetch(:ip_id) }

      User.unscoped.where(id: user_ids).order(:id).lock.load
      EnvironmentUserConfig.where(user_id: user_ids).order(:id).lock.load

      owned_ids = IpAddress.where(user_id: user_ids).order(:id).lock.pluck(:id)
      free_ids = IpAddress
                 .joins(network_interface: :vps)
                 .where(user_id: nil, vpses: { user_id: user_ids })
                 .order(:id)
                 .lock
                 .pluck(:id)
      ips = IpAddress.where(id: (owned_ids + free_ids + change_ids).uniq)
                     .order(:id)
                     .lock
                     .to_a

      network_ids = ips.map(&:network_id).compact.uniq
      interface_ids = ips.map(&:network_interface_id).compact.uniq
      Network.where(id: network_ids).order(:id).lock.load
      LocationNetwork.where(network_id: network_ids).order(:id).lock.load

      location_ids = LocationNetwork.where(network_id: network_ids).pluck(:location_id)
      Location.where(id: location_ids).order(:id).lock.load

      interfaces = NetworkInterface.where(id: interface_ids).order(:id).lock.to_a
      vps_ids = interfaces.map(&:vps_id).compact.uniq
      vpses = Vps.including_deleted.where(id: vps_ids).order(:id).lock.to_a
      Vps.unscoped.where(id: vps_ids).order(:id).lock.load if vpses.length != vps_ids.length

      node_ids = Vps.unscoped.where(id: vps_ids).pluck(:node_id)
      Node.where(id: node_ids).order(:id).lock.load

      user_resources = ResourceQueries
                       .user_resources(plan.safe_groups)
                       .order(:id)
                       .lock
                       .to_a
      ClusterResourceUse.where(user_cluster_resource_id: user_resources.map(&:id))
                        .order(:id)
                        .lock
                        .load
    end

    def current_resource_snapshot
      user_resources = ResourceQueries.user_resources(plan.safe_groups)

      ClusterResourceUse
        .where(
          class_name: 'EnvironmentUserConfig',
          table_name: 'environment_user_configs',
          user_cluster_resource_id: user_resources.select(:id)
        )
        .order(:id)
        .pluck(
          'cluster_resource_uses.id',
          'cluster_resource_uses.user_cluster_resource_id',
          'cluster_resource_uses.row_id',
          'cluster_resource_uses.value',
          'cluster_resource_uses.confirmed',
          'cluster_resource_uses.enabled'
        )
        .map { |row| row.map(&:to_s) }
    end

    def verify_changes!
      plan.changes.each do |item|
        ip = IpAddress.find(item.fetch(:ip_id))
        next if ip.charged_environment_id == item.fetch(:target_environment_id)

        raise "IP ##{ip.id} verification failed"
      end
    end

    def verify_accounting!
      builder = PlanBuilder.new

      plan.safe_groups.each do |group|
        user_id = group.fetch(:user_id)
        resource = group.fetch(:resource).to_sym
        remaining = builder.relevant_uncharged_addresses(user_id, resource)

        unless remaining.empty?
          raise(
            "user ##{user_id} still has uncharged addresses affecting " \
            "#{resource}: " \
            "#{remaining.map(&:id).join(',')}"
          )
        end

        _usage, reasons = builder.accounting_for(user_id, resource, [])
        next if reasons.empty?

        raise(
          "user ##{user_id} #{resource} accounting verification failed: " \
          "#{reasons.join('; ')}"
        )
      end
    end
  end

  # Provides the interactive command-line workflow.
  class Runner
    def initialize(admin_login:, input: $stdin, output: $stdout)
      @admin_login = admin_login
      @input = input
      @output = output
    end

    def run
      admin = User.find_by!(login: admin_login)
      raise "#{admin.login} is not an administrator" unless admin.role == :admin

      previous_user = User.current
      previous_whodunnit = PaperTrail.request.whodunnit
      User.current = admin
      PaperTrail.request.whodunnit = admin.id.to_s

      plan = PlanBuilder.new.build
      Printer.new(output).print(plan)

      if plan.changes.empty?
        output.puts
        output.puts 'No safe changes to apply.'
        return plan.blocked_groups.empty? ? 0 : 2
      end

      unless input.tty?
        raise 'interactive input is required; run the task from a terminal'
      end

      output.puts
      output.print "Type yes to set charged_environment_id on these " \
                   "#{plan.changes.length} IP addresses: "
      output.flush

      unless input.gets&.chomp == 'yes'
        output.puts 'Cancelled; no changes made.'
        return 1
      end

      Applier.new(plan, output:).apply
      output.puts "Updated and verified #{plan.changes.length} IP addresses."

      if plan.blocked_groups.any?
        output.puts 'Some owner/resource groups remain blocked.'
        2
      else
        0
      end
    ensure
      User.current = previous_user if defined?(previous_user)
      PaperTrail.request.whodunnit = previous_whodunnit if defined?(previous_whodunnit)
    end

    protected

    attr_reader :admin_login, :input, :output
  end
end

options = {}
parser = OptionParser.new do |opts|
  opts.banner = "Usage: #{File.basename(__FILE__)} --admin-login LOGIN"

  opts.on('--admin-login LOGIN', 'Administrator recorded in the audit history') do |value|
    options[:admin_login] = value
  end

  opts.on('-h', '--help', 'Show this help') do
    puts opts
    exit 0
  end
end

parser.parse!

if options[:admin_login].nil? || options[:admin_login].empty?
  warn '--admin-login is required'
  warn parser
  exit 1
end

exit FixIpChargedEnvironments::Runner.new(
  admin_login: options.fetch(:admin_login)
).run
