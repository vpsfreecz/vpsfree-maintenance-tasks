#!/run/current-system/sw/bin/vpsadmin-api-ruby
# frozen_string_literal: true

# Restore missing charging environments on owned IP addresses intended for VPS
# use.
#
# The task derives the environment from the assigned VPS or, for an unassigned
# address, from the network's primary location. It reconciles numerical IP
# resource use with the resulting IP inventory. User resource limits are not
# changed, so free capacity can become negative.
#
# Before running the task, stop every API, scheduler and other process that can
# change IP assignments or IP resource uses. Drain queued transaction chains,
# then stop the supervisor. Keep all writers stopped until the task exits.
#
# Usage:
#   ./fix_ip_charged_environments.rb --admin-login LOGIN --writers-quiesced
#
# A hard-killed process can leave ownerless ResourceLock rows. Before retrying,
# confirm that no copy of this task is running. Inspect locks for the exact lock
# targets printed by this task, and remove only rows proven to be orphaned.

require 'bigdecimal'
require 'digest'
require 'json'
require 'optparse'
require 'vpsadmin'

module FixIpChargedEnvironments
  RESOURCE_NAMES = %i[ipv4 ipv4_private ipv6].freeze
  TARGET_NETWORK_PURPOSES = %w[any vps].freeze
  RESOURCE_USE_CLASS = 'EnvironmentUserConfig'
  RESOURCE_USE_TABLE = 'environment_user_configs'

  class StalePlan < StandardError; end
  class LockCleanupFailed < StandardError; end

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

    def accounting_changes
      safe_groups.flat_map do |group|
        group.fetch(:usage).select { |row| row.fetch(:change) }
      end.sort_by do |row|
        [row.fetch(:user_id), row.fetch(:resource), row.fetch(:environment_id)]
      end
    end

    def signature
      Digest::SHA256.hexdigest(JSON.generate(groups))
    end
  end

  # Builds UserClusterResource scopes for the exact owner/resource groups in a
  # plan, without locking unrelated combinations.
  module ResourceQueries
    module_function

    def userless_vps_addresses(scope, user_ids: nil)
      ret = scope
            .joins(
              'INNER JOIN network_interfaces repair_interfaces ' \
              'ON repair_interfaces.id = ip_addresses.network_interface_id'
            )
            .joins(
              'INNER JOIN vpses repair_vpses ' \
              'ON repair_vpses.id = repair_interfaces.vps_id'
            )
            .where(ip_addresses: { user_id: nil })

      if user_ids
        ret = ret.where('repair_vpses.user_id IN (?)', Array(user_ids))
      end

      ret
    end

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

  # Verifies the database-visible part of the required maintenance window.
  module Quiescence
    ACTIVE_CHAIN_STATES = %i[staged queued rollbacking].freeze

    module_function

    def verify!
      rows = TransactionChain
             .where(state: ACTIVE_CHAIN_STATES)
             .order(:id)
             .pluck(:id, :state)
      return if rows.empty?

      chains = rows.map { |id, state| "##{id} (#{state})" }.join(', ')
      raise "transaction chains are still active: #{chains}; stop API writers, " \
            'drain all chains, then stop the supervisor before retrying'
    end
  end

  # Finds affected IP addresses, infers their charging environments and builds
  # the matching IP resource-use corrections.
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
      contributors = Hash.new { |hash, key| hash[key] = [] }
      reasons = []

      add_existing_contributors(
        user_id,
        resource,
        owned_addresses(user_id),
        'owned, already charged',
        expected,
        contributors,
        reasons
      )
      add_existing_contributors(
        user_id,
        resource,
        freely_assigned_addresses(user_id),
        'assigned through VPS, already charged',
        expected,
        contributors,
        reasons
      )

      proposed_items.each do |item|
        environment_id = item[:target_environment_id]
        next if environment_id.nil?

        add_contributor(
          expected,
          contributors,
          environment_id,
          accounting_contributor_from_item(item, 'proposed IP repair')
        )
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

      cluster_resource = ClusterResource.find_by(name: resource.to_s)
      user_resources = if cluster_resource
                         UserClusterResource
                           .where(user_id:, cluster_resource:)
                           .includes(:environment)
                           .order(:environment_id, :id)
                           .to_a
                       else
                         []
                       end
      user_resources_by_environment = user_resources.group_by(&:environment_id)

      reasons << "cluster resource #{resource} is missing" unless cluster_resource

      uses = resource_uses(resource, configs.map(&:id), user_resources.map(&:id))
      intended_uses = uses.select { |use| intended_resource_use?(use) }
      uses_by_config = intended_uses.group_by(&:row_id)
      validate_resource_uses(uses, configs_by_id, user_id, resource, reasons)

      environment_ids = (
        configs.map(&:environment_id) +
        expected.keys.compact +
        uses.filter_map { |use| use.user_cluster_resource&.environment_id } +
        user_resources.map(&:environment_id)
      ).uniq.sort_by { |id| [id.nil? ? 0 : 1, id.to_i] }

      usage = environment_ids.map do |environment_id|
        environment_configs = configs_by_environment.fetch(environment_id, [])
        if environment_configs.length != 1
          reasons << "environment ##{environment_id} has " \
                     "#{environment_configs.length} EnvironmentUserConfig rows for user ##{user_id}"
        end

        config = environment_configs.first
        rows = config ? uses_by_config.fetch(config.id, []) : []
        environment_resources = user_resources_by_environment.fetch(environment_id, [])

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

        if environment_resources.length > 1
          reasons << "environment ##{environment_id} has multiple UserClusterResource " \
                     "rows for user ##{user_id} and #{resource}: " \
                     "#{environment_resources.map(&:id).join(',')}"
        end

        user_resource = environment_resources.first
        changing = actual != expected_value

        if changing && config.nil?
          reasons << "cannot reconcile #{resource} in environment ##{environment_id} " \
                     'without one EnvironmentUserConfig row'
        end

        if changing && user_resource.nil?
          reasons << "cannot reconcile #{resource} in environment ##{environment_id}: " \
                     "user ##{user_id} has no UserClusterResource"
        end

        rows.each do |use|
          next if use.admin_lock_type == 'no_lock' && use.admin_limit.nil?

          reasons << "resource use ##{use.id} is admin-locked " \
                     "(#{use.admin_lock_type}, limit #{use.admin_limit.inspect})"
        end

        valid_existing_use = rows.one? && user_resource &&
                             rows.first.user_cluster_resource_id == user_resource.id &&
                             rows.first.enabled && rows.first.confirmed?
        reconcilable_shape = rows.empty? || valid_existing_use
        used_before = user_resource && decimal(user_resource.used)
        used_after = if used_before && !changing
                       used_before
                     elsif used_before && reconcilable_shape
                       replaced_value = rows.empty? ? BigDecimal('0') : decimal(rows.first.value)
                       used_before - replaced_value + expected_value
                     end
        quota = user_resource&.value

        {
          user_id:,
          resource: resource.to_s,
          environment_id:,
          environment_label: environment&.label,
          environment_user_config_id: config&.id,
          user_cluster_resource_id: user_resource&.id,
          resource_use_id: rows.one? ? rows.first.id : nil,
          resource_use_ids: rows.map(&:id),
          recorded: amount(actual),
          expected: amount(expected_value),
          quota: quota && amount(quota),
          total_used_before: used_before && amount(used_before),
          total_used_after: used_after && amount(used_after),
          free_before: user_resource && amount(user_resource.free),
          free_after: quota && used_after && amount(decimal(quota) - used_after),
          change: changing,
          operation: changing && (rows.empty? ? 'create' : 'update'),
          contributors: contributors[environment_id].sort_by { |item| item.fetch(:ip_id) }
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
        ResourceQueries.userless_vps_addresses(base)
      )

      (owned + userless_assigned).uniq(&:id).sort_by(&:id)
    end

    def owned_addresses(user_id)
      preload_addresses(
        IpAddress
          .where(user_id:)
          .where.not(charged_environment_id: nil)
      )
    end

    def freely_assigned_addresses(user_id)
      preload_addresses(
        ResourceQueries.userless_vps_addresses(
          IpAddress.where.not(charged_environment_id: nil),
          user_ids: user_id
        )
      )
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
            network_interface: [
              :export,
              { vps: { node: { location: :environment } } }
            ]
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
      ip.user_id || vps_for(ip.network_interface)&.user_id
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
      ip_inventory_errors(ip).each do |error|
        errors << "#{ip_label(ip)} #{error}"
      end

      if ip.network_interface_id
        interface = ip.network_interface
        vps = vps_for(interface)
        node = vps&.node
        location = node&.location
        target_environment = location&.environment
        selected_location = location
        selection_reason = vps ? "current VPS ##{vps.id}" : 'current VPS'

        errors << "#{ip_label(ip)} points to a missing network interface" if interface.nil?
        errors << "#{ip_label(ip)} is not attached to a VPS" if interface && vps.nil?
        errors << "#{ip_label(ip)} has a VPS without a node location" if vps && location.nil?

        if vps&.object_state == 'hard_delete'
          errors << "#{ip_label(ip)} is attached to hard-deleted VPS ##{vps.id}"
        end

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
      if interface.nil?
        return {
          type: 'invalid',
          network_interface_id: ip.network_interface_id,
          error: "points to missing network interface ##{ip.network_interface_id}"
        }
      end

      vps = vps_for(interface)
      export = interface.export

      if interface.vps_id && interface.export_id
        return {
          type: 'invalid',
          network_interface_id: interface.id,
          error: "interface ##{interface.id} references both VPS " \
                 "##{interface.vps_id} and Export ##{interface.export_id}"
        }
      elsif interface.export_id
        if export.nil?
          return {
            type: 'invalid',
            network_interface_id: interface.id,
            error: "interface ##{interface.id} points to missing Export " \
                   "##{interface.export_id}"
          }
        end

        return {
          type: 'export',
          network_interface_id: interface.id,
          export_id: export.id,
          export_user_id: export.user_id
        }
      elsif interface.vps_id.nil?
        return {
          type: 'invalid',
          network_interface_id: interface.id,
          error: "interface ##{interface.id} belongs to neither a VPS nor an export"
        }
      elsif vps.nil?
        return {
          type: 'invalid',
          network_interface_id: interface.id,
          error: "interface ##{interface.id} points to missing VPS ##{interface.vps_id}"
        }
      end

      node = vps&.node
      location = node&.location
      environment = location&.environment

      {
        type: 'vps',
        network_interface_id: interface&.id,
        vps_id: vps&.id,
        vps_user_id: vps&.user_id,
        vps_object_state: vps&.object_state,
        vps_hostname: vps&.hostname,
        node_id: node&.id,
        node_name: node&.name,
        location_id: location&.id,
        location_label: location&.label,
        environment_id: environment&.id,
        environment_label: environment&.label
      }
    end

    def vps_for(interface)
      return if interface&.vps_id.nil?

      scoped_vps = interface.vps
      return scoped_vps if scoped_vps

      @unscoped_vps ||= {}
      return @unscoped_vps[interface.vps_id] if @unscoped_vps.key?(interface.vps_id)

      @unscoped_vps[interface.vps_id] = Vps
                                          .unscoped
                                          .includes(node: { location: :environment })
                                          .find_by(id: interface.vps_id)
    end

    def ip_inventory_errors(ip)
      errors = []
      size = decimal(ip.size)
      errors << "has non-positive size #{amount(size)}" unless size.positive?

      if ip.network
        ip.valid?
        ip.errors.where(:ip_addr).each do |error|
          errors << "has invalid address data: #{error.full_message}"
        end
      end

      errors
    rescue ArgumentError
      ["has invalid size #{ip.size.inspect}"]
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

    def resource_uses(resource, config_ids, user_resource_ids)
      owner_uses = ClusterResourceUse
                   .where(user_cluster_resource_id: user_resource_ids)
                   .includes(user_cluster_resource: :cluster_resource)
                   .to_a
      config_uses = ClusterResourceUse
                    .where(
                      class_name: RESOURCE_USE_CLASS,
                      table_name: RESOURCE_USE_TABLE,
                      row_id: config_ids
                    )
                    .includes(user_cluster_resource: :cluster_resource)
                    .to_a
                    .select do |use|
        use_resource = use.user_cluster_resource&.cluster_resource
        use_resource.nil? || use_resource.name == resource.to_s
      end

      (owner_uses + config_uses).uniq(&:id).sort_by(&:id)
    end

    def intended_resource_use?(use)
      use.class_name == RESOURCE_USE_CLASS && use.table_name == RESOURCE_USE_TABLE
    end

    def validate_resource_uses(uses, configs_by_id, user_id, resource, reasons)
      uses.each do |use|
        unless intended_resource_use?(use)
          reasons << "resource use ##{use.id} has unexpected target " \
                     "#{use.class_name.inspect}/#{use.table_name.inspect}/##{use.row_id}"
          next
        end

        config = configs_by_id[use.row_id]
        if config.nil?
          reasons << "resource use ##{use.id} points to missing or foreign " \
                     "EnvironmentUserConfig ##{use.row_id}"
          next
        end

        user_resource = use.user_cluster_resource
        if user_resource.nil?
          reasons << "resource use ##{use.id} points to missing " \
                     "UserClusterResource ##{use.user_cluster_resource_id}"
          next
        end

        use_resource = user_resource.cluster_resource
        if use_resource.nil?
          reasons << "resource use ##{use.id} points through UserClusterResource " \
                     "##{user_resource.id} to missing ClusterResource " \
                     "##{user_resource.cluster_resource_id}"
          next
        end

        if use_resource.name != resource.to_s
          reasons << "resource use ##{use.id} uses #{use_resource.name}, expected #{resource}"
          next
        end

        next if user_resource.user_id == user_id &&
                user_resource.environment_id == config.environment_id

        reasons << "resource use ##{use.id} belongs to UserClusterResource " \
                   "##{user_resource.id} for another user or environment"
      end
    end

    def add_existing_contributors(user_id, resource, addresses, source,
                                  expected, contributors, reasons)
      addresses.each do |ip|
        ip_resource = resource_for(ip)
        if ip_resource.nil?
          reasons << "already charged IP #{ip_label(ip)} has a missing or unsupported " \
                     "network, so the #{resource} inventory may be incomplete"
          next
        end
        next unless ip_resource == resource

        contributor = accounting_contributor(ip, source)
        contributor_errors = accounting_contributor_errors(
          ip,
          contributor.fetch(:assignment),
          user_id
        )
        contributor_errors.each do |error|
          reasons << "already charged IP #{ip_label(ip)} #{error}"
        end
        add_contributor(expected, contributors, ip.charged_environment_id, contributor)
      end
    end

    def accounting_contributor_errors(ip, assignment, user_id)
      errors = ip_inventory_errors(ip)
      if assignment.fetch(:type) == 'invalid'
        errors << assignment.fetch(:error)
        return errors
      end

      unless ip.network.location_networks.any? do |link|
        link.location&.environment_id == ip.charged_environment_id
      end
        errors << "network ##{ip.network_id} is not available in charged " \
                  "Environment ##{ip.charged_environment_id}"
      end

      case assignment.fetch(:type)
      when 'unassigned'
        nil
      when 'export'
        if assignment.fetch(:export_user_id) != user_id
          errors << "owner ##{ip.user_id} differs from Export " \
                    "##{assignment.fetch(:export_id)} owner " \
                    "##{assignment.fetch(:export_user_id)}"
        end
      when 'vps'
        if assignment.fetch(:vps_object_state) == 'hard_delete'
          errors << "is attached to hard-deleted VPS ##{assignment.fetch(:vps_id)}"
        end

        if assignment[:location_id].nil?
          errors << 'has a VPS without a node location'
          return errors
        elsif assignment[:environment_id].nil?
          errors << 'has a VPS location without an environment'
          return errors
        end

        if assignment.fetch(:vps_user_id) != user_id
          errors << "owner ##{ip.user_id || 'none'} differs from VPS " \
                    "##{assignment.fetch(:vps_id)} owner " \
                    "##{assignment.fetch(:vps_user_id)}"
        elsif ip.charged_environment_id != assignment.fetch(:environment_id)
          errors << "is charged to Environment ##{ip.charged_environment_id}, " \
                    "but VPS ##{assignment.fetch(:vps_id)} is in Environment " \
                    "##{assignment.fetch(:environment_id)}"
        elsif ip.network.location_networks.none? do |link|
          link.location_id == assignment.fetch(:location_id)
        end
          errors << "network ##{ip.network_id} is not available at VPS location " \
                    "##{assignment.fetch(:location_id)}"
        end
      end

      errors
    end

    def add_contributor(expected, contributors, environment_id, contributor)
      expected[environment_id] += decimal(contributor.fetch(:size))
      contributors[environment_id] << contributor
    end

    def accounting_contributor(ip, source)
      {
        ip_id: ip.id,
        ip_addr: ip.ip_addr,
        prefix: ip.prefix,
        size: amount(ip.size),
        source:,
        network_id: ip.network_id,
        network_purpose: ip.network&.purpose,
        charged_environment_id: ip.charged_environment_id,
        assignment: assignment_for(ip)
      }
    end

    def accounting_contributor_from_item(item, source)
      {
        ip_id: item.fetch(:ip_id),
        ip_addr: item.fetch(:ip_addr),
        prefix: item.fetch(:prefix),
        size: item.fetch(:size),
        source:,
        network_id: item.fetch(:network_id),
        network_purpose: item.fetch(:network_purpose),
        charged_environment_id: nil,
        assignment: item.fetch(:assignment)
      }
    end

    def ip_label(ip)
      "##{ip.id} #{ip.ip_addr}/#{ip.prefix}"
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
      output.puts 'The task will set charged_environment_id and reconcile the matching IP resource uses.'
      output.puts 'User resource allocations will not change; free capacity may become negative.'
      output.puts 'User logins are omitted from this output.'
      output.puts 'All IP/accounting writers must remain stopped until this task exits.'

      if plan.changes.empty?
        output.puts 'None.'
      else
        plan.safe_groups.each do |group|
          print_group_header(group)
          group.fetch(:items).each { |item| print_item(item, change: true) }
          print_usage(group, apply: true)
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
          print_usage(group, apply: false)
          group.fetch(:reasons).each { |reason| output.puts "  BLOCKED: #{reason}" }
        end
      end

      output.puts
      output.puts "#{plan.changes.length} IP addresses ready to update"
      output.puts "#{plan.accounting_changes.length} resource-use rows ready to reconcile"
      output.puts "#{plan.blocked_groups.length} owner/resource groups blocked"
    end

    protected

    attr_reader :output

    def print_group_header(group)
      output.puts
      output.puts "User ##{group.fetch(:user_id)}, resource #{group.fetch(:resource)}"
    end

    def print_item(item, change:)
      output.puts "  IP ##{item.fetch(:ip_id)} #{item.fetch(:ip_addr)}/#{item.fetch(:prefix)}"
      output.puts "    owner: User ##{item.fetch(:owner_id)}"
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

    def print_usage(group, apply:)
      rows = group.fetch(:usage).select do |row|
        row.fetch(:change) || row.fetch(:contributors).any? || row.fetch(:recorded) != '0'
      end
      return if rows.empty?

      output.puts '  IP resource accounting:'
      rows.each do |row|
        label = row[:environment_label] || 'unknown environment'
        output.puts "    #{label} (Environment ##{row.fetch(:environment_id)})"
        output.puts "      EnvironmentUserConfig: #{id_or_missing(row[:environment_user_config_id])}"
        output.puts "      UserClusterResource: #{id_or_missing(row[:user_cluster_resource_id])}"
        output.puts "      ClusterResourceUse: #{resource_use_label(row)}"

        if row[:quota]
          output.puts "      allocation: #{row.fetch(:quota)}"
          output.puts "      total used now: #{row.fetch(:total_used_before)}"
          output.puts "      free now: #{row.fetch(:free_before)}"

          if row[:total_used_after]
            output.puts "      total used after: #{row.fetch(:total_used_after)}"
            output.puts "      free after: #{row.fetch(:free_after)}"
          elsif row.fetch(:change)
            output.puts '      totals after: unavailable until the structural errors are fixed'
          end
        end

        print_contributors(row)
        print_accounting_change(row, apply:)
      end
    end

    def print_contributors(row)
      output.puts '      expected value contributors:'

      if row.fetch(:contributors).empty?
        output.puts '        none'
        return
      end

      row.fetch(:contributors).each do |item|
        output.puts "        IP ##{item.fetch(:ip_id)} " \
                    "#{item.fetch(:ip_addr)}/#{item.fetch(:prefix)}, " \
                    "size #{item.fetch(:size)}, #{item.fetch(:source)}"
        output.puts "          network ##{item.fetch(:network_id)}, " \
                    "purpose #{item.fetch(:network_purpose)}"
        output.puts "          assignment: #{assignment(item.fetch(:assignment))}"
      end
    end

    def print_accounting_change(row, apply:)
      unless row.fetch(:change)
        output.puts '      accounting value already matches the IP inventory'
        return
      end

      prefix = apply ? 'planned change' : 'required correction, not applied'
      use_ids = row.fetch(:resource_use_ids)
      target = if use_ids.empty?
                 'new ClusterResourceUse'
               elsif use_ids.one?
                 "ClusterResourceUse ##{use_ids.first}"
               else
                 "ClusterResourceUse rows #{use_ids.map { |id| "##{id}" }.join(', ')}"
               end
      output.puts "      #{prefix}: #{target} #{row.fetch(:recorded)} -> " \
                  "#{row.fetch(:expected)}"
      if apply
        output.puts '      admin override: yes; the user allocation stays unchanged'
      else
        output.puts '      no accounting change will be made while this group is blocked'
      end

      if row[:free_after] && BigDecimal(row.fetch(:free_after)).negative?
        output.puts "      WARNING: free capacity will be #{row.fetch(:free_after)}"
      end
    end

    def id_or_missing(id)
      id ? "##{id}" : 'missing'
    end

    def resource_use_label(row)
      ids = row.fetch(:resource_use_ids)
      label = ids.empty? ? 'missing' : ids.map { |id| "##{id}" }.join(', ')
      "#{label}, recorded #{row.fetch(:recorded)}, expected #{row.fetch(:expected)}"
    end

    def assignment(data)
      case data.fetch(:type)
      when 'unassigned'
        'unassigned'
      when 'export'
        "Export ##{data.fetch(:export_id)}, interface " \
          "##{data.fetch(:network_interface_id)}"
      when 'invalid'
        "invalid: #{data.fetch(:error)}"
      when 'vps'
        "VPS ##{data[:vps_id]} #{data[:vps_hostname] || 'unknown hostname'}, " \
          "interface ##{data[:network_interface_id]}, node ##{data[:node_id]} " \
          "#{data[:node_name] || 'unknown node'}, location ##{data[:location_id]} " \
          "#{data[:location_label] || 'unknown location'}, environment " \
          "##{data[:environment_id]} #{data[:environment_label] || 'unknown environment'}"
      else
        "unknown assignment type #{data.fetch(:type).inspect}"
      end
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
        output.puts "  Lock target: #{object.class.name} ##{object.id}"
        output.flush
        lock = object.acquire_lock
        @locks << [lock, object]
        output.puts "    acquired ResourceLock ##{lock.id}"
        output.flush
      end

      yield
    ensure
      active_error = $!
      cleanup_errors = []

      @locks.reverse_each do |lock, object|
        begin
          lock.release if lock.persisted?
        rescue ActiveRecord::RecordNotFound
          nil
        rescue StandardError => e
          cleanup_errors << [lock, object, e]
        end
      end

      cleanup_errors.each do |lock, object, error|
        output.puts "WARNING: could not release ResourceLock ##{lock.id} for " \
                    "#{object.class.name} ##{object.id}: " \
                    "#{error.class}: #{error.message}"
      end
      output.flush if cleanup_errors.any?

      if active_error.nil? && cleanup_errors.any?
        ids = cleanup_errors.map { |lock, _object, _error| "##{lock.id}" }.join(', ')
        raise LockCleanupFailed,
              "database work completed, but application locks #{ids} could not be released; " \
              'inspect the preceding commit result and cleanup warnings before retrying'
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
      @applied_accounting = []
    end

    def apply
      ApplicationLocks.new(plan, output:).synchronize do
        ActiveRecord::Base.transaction(isolation: :serializable) do
          lock_database_rows
          Quiescence.verify!
          fresh_plan = PlanBuilder.new.build

          unless fresh_plan.signature == plan.signature
            raise StalePlan,
                  'data changed after confirmation; review a newly generated plan'
          end

          allocation_snapshot = current_allocation_snapshot

          plan.changes.each do |item|
            IpAddress.find(item.fetch(:ip_id)).update!(
              charged_environment_id: item.fetch(:target_environment_id)
            )
          end
          apply_accounting_changes!

          verify_changes!
          verify_accounting!

          unless current_allocation_snapshot == allocation_snapshot
            raise 'user cluster resource allocations changed while applying the repair'
          end
        end

        print_commit_result
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
      free_ids = ResourceQueries
                 .userless_vps_addresses(IpAddress.all, user_ids:)
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

    def current_allocation_snapshot
      ResourceQueries
        .user_resources(plan.safe_groups)
        .order(:id)
        .pluck('user_cluster_resources.id', 'user_cluster_resources.value')
        .map { |row| row.map(&:to_s) }
    end

    def apply_accounting_changes!
      plan.accounting_changes.each do |change|
        expected = BigDecimal(change.fetch(:expected))

        if change[:resource_use_id]
          use = ClusterResourceUse.find(change.fetch(:resource_use_id))
          verify_resource_use_target!(use, change)
          use.admin_override = true
          use.update!(value: expected)
        else
          config = EnvironmentUserConfig.find(change.fetch(:environment_user_config_id))
          user = User.unscoped.find(change.fetch(:user_id))
          use = config.allocate_resource!(
            change.fetch(:resource).to_sym,
            expected,
            user:,
            confirmed: ClusterResourceUse.confirmed(:confirmed),
            admin_override: true
          )
          verify_resource_use_target!(use, change)
        end

        @applied_accounting << {
          id: use.id,
          operation: change.fetch(:operation),
          user_id: change.fetch(:user_id),
          resource: change.fetch(:resource),
          environment_id: change.fetch(:environment_id),
          environment_user_config_id: change.fetch(:environment_user_config_id),
          user_cluster_resource_id: change.fetch(:user_cluster_resource_id),
          value: change.fetch(:expected)
        }
      end
    end

    def print_commit_result
      output.puts "Database commit completed for #{plan.changes.length} IP addresses."

      if @applied_accounting.empty?
        output.flush
        return
      end

      output.puts 'Reconciled resource-use rows:'
      @applied_accounting.each do |row|
        output.puts "  #{row.fetch(:operation)}d ClusterResourceUse ##{row.fetch(:id)}: " \
                    "User ##{row.fetch(:user_id)}, resource #{row.fetch(:resource)}, " \
                    "Environment ##{row.fetch(:environment_id)}, " \
                    "EnvironmentUserConfig ##{row.fetch(:environment_user_config_id)}, " \
                    "UserClusterResource ##{row.fetch(:user_cluster_resource_id)}, " \
                    "value #{row.fetch(:value)}"
      end
      output.flush
    end

    def verify_resource_use_target!(use, change)
      expected = [
        change.fetch(:user_cluster_resource_id),
        'EnvironmentUserConfig',
        'environment_user_configs',
        change.fetch(:environment_user_config_id)
      ]
      actual = [
        use.user_cluster_resource_id,
        use.class_name,
        use.table_name,
        use.row_id
      ]
      return if actual == expected

      raise "ClusterResourceUse ##{use.id} target changed: #{actual.inspect}"
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

        usage, reasons = builder.accounting_for(user_id, resource, [])
        corrections = usage.select { |row| row.fetch(:change) }
        next if reasons.empty? && corrections.empty?

        raise(
          "user ##{user_id} #{resource} accounting verification failed: " \
          "#{(reasons + corrections.map { |row| accounting_difference(row) }).join('; ')}"
        )
      end
    end

    def accounting_difference(row)
      "environment ##{row.fetch(:environment_id)} recorded " \
        "#{row.fetch(:recorded)}, expected #{row.fetch(:expected)}"
    end
  end

  # Provides the interactive command-line workflow.
  class Runner
    def initialize(admin_login:, writers_quiesced:, input: $stdin, output: $stdout)
      @admin_login = admin_login
      @writers_quiesced = writers_quiesced
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

      raise 'refusing to run without --writers-quiesced' unless writers_quiesced

      Quiescence.verify!
      output.puts 'Writer quiescence check: no active transaction chains found.'

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
      output.print "Type yes to update #{plan.changes.length} IP addresses and " \
                   "reconcile #{plan.accounting_changes.length} resource-use rows: "
      output.flush

      unless input.gets&.chomp == 'yes'
        output.puts 'Cancelled; no changes made.'
        return 1
      end

      Applier.new(plan, output:).apply
      output.puts "Updated and verified #{plan.changes.length} IP addresses and " \
                  "#{plan.accounting_changes.length} resource-use rows."

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

    attr_reader :admin_login, :writers_quiesced, :input, :output
  end
end

options = {}
parser = OptionParser.new do |opts|
  opts.banner = "Usage: #{File.basename(__FILE__)} --admin-login LOGIN --writers-quiesced"

  opts.on('--admin-login LOGIN', 'Administrator recorded in the audit history') do |value|
    options[:admin_login] = value
  end

  opts.on(
    '--writers-quiesced',
    'Confirm API, scheduler, supervisor and other IP/accounting writers are stopped'
  ) do
    options[:writers_quiesced] = true
  end

  opts.on('-h', '--help', 'Show this help') do
    puts opts
    exit 0
  end
end

parser.parse!

if options[:admin_login].nil? || options[:admin_login].empty? || !options[:writers_quiesced]
  warn '--admin-login and --writers-quiesced are required'
  warn parser
  exit 1
end

exit FixIpChargedEnvironments::Runner.new(
  admin_login: options.fetch(:admin_login),
  writers_quiesced: options.fetch(:writers_quiesced)
).run
