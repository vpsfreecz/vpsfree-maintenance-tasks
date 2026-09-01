#!/run/current-system/sw/bin/vpsadmin-api-ruby
# frozen_string_literal: true

# Remove notification templates introduced by overlay-based reconciliation.
#
# The production notification template repository intentionally omits these
# optional fallbacks. They were created on 2026-09-01 when reconciliation
# started composing the external repository over vpsAdmin's bundled defaults.
#
# Dry-run is the default. Run this task only after deploying vpsAdmin with
# notificationTemplates.mode = "replace" and reviewing the dry-run output.
# Apply it only during a maintenance window after stopping vpsadmin-api,
# vpsadmin-supervisor, and every scheduled vpsAdmin rake task on all API
# hosts. Keep those database and mail writers stopped until this task commits.
#
# Usage:
#   ./remove_unintended_notification_templates.rb
#   ./remove_unintended_notification_templates.rb \
#     --apply --confirm-mail-writers-stopped

require 'optparse'
require 'vpsadmin'

options = {
  apply: false,
  confirm_mail_writers_stopped: false
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: #{$PROGRAM_NAME} [--apply --confirm-mail-writers-stopped]"

  opts.on('--apply', 'Delete the validated templates (default: dry-run)') do
    options[:apply] = true
  end

  opts.on(
    '--confirm-mail-writers-stopped',
    'Confirm that all vpsAdmin database and mail writers are stopped'
  ) do
    options[:confirm_mail_writers_stopped] = true
  end

  opts.on('-h', '--help', 'Show this help') do
    puts opts
    exit 0
  end
end

parser.parse!

if options[:apply] && !options[:confirm_mail_writers_stopped]
  warn '--apply requires --confirm-mail-writers-stopped'
  warn parser
  exit 1
elsif options[:confirm_mail_writers_stopped] && !options[:apply]
  warn '--confirm-mail-writers-stopped is only valid with --apply'
  warn parser
  exit 1
end

module RemoveUnintendedNotificationTemplates
  CREATED_AT = '2026-09-01 13:28:17'

  TARGETS = [
    {
      id: 71,
      name: 'outage_report_generic',
      label: 'Generic outage report',
      template_id: 'outage_report_role'
    },
    {
      id: 72,
      name: 'outage_report_user',
      label: 'User outage report',
      template_id: 'outage_report_role'
    },
    {
      id: 73,
      name: 'request_create_admin',
      label: 'Create request (admin)',
      template_id: 'request_action_role'
    },
    {
      id: 74,
      name: 'request_resolve_user',
      label: 'Resolve request (user)',
      template_id: 'request_action_role'
    },
    {
      id: 75,
      name: 'request_update_admin',
      label: 'Update request (admin)',
      template_id: 'request_action_role'
    },
    {
      id: 76,
      name: 'request_update_user',
      label: 'Update request (user)',
      template_id: 'request_action_role'
    }
  ].freeze

  TARGET_IDS = TARGETS.map { |target| target.fetch(:id) }.freeze
  TARGET_NAMES = TARGETS.map { |target| target.fetch(:name) }.freeze

  module_function

  def formatted_time(value)
    value&.strftime('%Y-%m-%d %H:%M:%S')
  end

  def expected_attributes(target)
    target.merge(
      user_visibility: 'default',
      created_at: CREATED_AT,
      updated_at: CREATED_AT
    )
  end

  def actual_attributes(template)
    {
      id: template.id,
      name: template.name,
      label: template.label,
      template_id: template.template_id,
      user_visibility: template.user_visibility,
      created_at: formatted_time(template.created_at),
      updated_at: formatted_time(template.updated_at)
    }
  end

  def validate_templates!(templates)
    expected_by_id = TARGETS.to_h { |target| [target.fetch(:id), expected_attributes(target)] }
    actual_by_id = templates.to_h { |template| [template.id, actual_attributes(template)] }

    return if actual_by_id == expected_by_id

    warn 'Template metadata does not match the recorded reconciliation result.'
    warn "Expected: #{expected_by_id.inspect}"
    warn "Actual:   #{actual_by_id.inspect}"
    raise 'Refusing to remove templates with unexpected metadata'
  end

  def validate_translations!(templates)
    translations = MailTemplateTranslation
                   .where(mail_template_id: templates.map(&:id))
                   .includes(:language)
                   .lock
                   .order(:mail_template_id, :id)
                   .to_a
    by_template_id = translations.group_by(&:mail_template_id)

    templates.each do |template|
      validate_translation!(template, by_template_id.fetch(template.id, []))
    end

    translations
  end

  def validate_translation!(template, translations)
    unless translations.length == 1
      raise "Template #{template.id}:#{template.name} has " \
            "#{translations.length} translations, expected 1"
    end

    translation = translations.first
    language = translation.language.code
    unless language == 'en'
      raise "Template #{template.id}:#{template.name} has language " \
            "#{language.inspect}, expected en"
    end

    translation_times = [
      formatted_time(translation.created_at),
      formatted_time(translation.updated_at)
    ]
    return if translation_times == [CREATED_AT, CREATED_AT]

    raise "Translation #{translation.id} of #{template.name} was changed after creation"
  end

  def referencing_tables(connection, template_ids)
    ids = template_ids.map { |id| Integer(id) }.join(',')

    connection.tables.filter_map do |table|
      next unless connection.columns(table).any? { |column| column.name == 'mail_template_id' }

      quoted_table = connection.quote_table_name(table)
      quoted_column = connection.quote_column_name('mail_template_id')
      count = connection.select_value(
        "SELECT COUNT(*) FROM #{quoted_table} WHERE #{quoted_column} IN (#{ids})"
      ).to_i
      [table, count] if count.positive?
    end.to_h
  end

  def validate_references!(template_ids, translations)
    references = referencing_tables(ActiveRecord::Base.connection, template_ids)
    expected_translation_count = references.delete('mail_template_translations')

    unless expected_translation_count == translations.length
      raise 'Translation references changed while validating the target templates'
    end

    return if references.empty?

    raise "Target templates are referenced by #{references.inspect}; refusing removal"
  end

  def validate_audit_history!(templates, translations)
    {
      'MailTemplate' => templates.map(&:id),
      'MailTemplateTranslation' => translations.map(&:id)
    }.each do |item_type, item_ids|
      versions = PaperTrail::Version
                 .where(item_type:, item_id: item_ids)
                 .order(:item_id, :id)
                 .to_a
      versions_by_item_id = versions.group_by(&:item_id)

      item_ids.each do |item_id|
        item_versions = versions_by_item_id.fetch(item_id, [])
        unless item_versions.length == 1
          raise "#{item_type} #{item_id} has #{item_versions.length} audit " \
                'versions, expected one creation version'
        end

        validate_creation_version!(item_type, item_id, item_versions.first)
      end
    end
  end

  def validate_creation_version!(item_type, item_id, version)
    actual = {
      event: version.event,
      created_at: formatted_time(version.created_at),
      object: version.object,
      whodunnit: version.whodunnit
    }
    expected = {
      event: 'create',
      created_at: CREATED_AT,
      object: nil,
      whodunnit: nil
    }
    return if actual == expected

    raise "#{item_type} #{item_id} audit version does not match the recorded " \
          "creation: #{actual.inspect}"
  end

  def find_targets
    targets_by_id = MailTemplate.where(id: TARGET_IDS)
    targets_by_name = MailTemplate.where(name: TARGET_NAMES)
    targets_by_id.or(targets_by_name).lock.order(:id).to_a
  end

  def validate_complete_set!(templates)
    return if templates.length == TARGETS.length

    found = templates.map { |template| "#{template.id}:#{template.name}" }
    raise "Found only part of the target set: #{found.join(', ')}"
  end

  def validate_absent_references!
    references = referencing_tables(ActiveRecord::Base.connection, TARGET_IDS)
    return if references.empty?

    raise "Target templates are absent but their IDs are still referenced by " \
          "#{references.inspect}"
  end

  def verify_deletion!(template_ids)
    remaining_templates = MailTemplate.where(id: TARGET_IDS).or(
      MailTemplate.where(name: TARGET_NAMES)
    )
    raise 'Template deletion verification failed' if remaining_templates.exists?

    references = referencing_tables(ActiveRecord::Base.connection, template_ids)
    return if references.empty?

    raise "Target template IDs remain referenced after deletion: #{references.inspect}"
  end

  def run(apply:)
    ActiveRecord::Base.transaction do
      process_targets(apply:)
    end
  end

  def process_targets(apply:)
    templates = find_targets
    if templates.empty?
      validate_absent_references!
      return :already_absent
    end

    validate_complete_set!(templates)
    validate_templates!(templates)
    translations = validate_translations!(templates)
    template_ids = (TARGET_IDS + templates.map(&:id)).uniq
    validate_references!(template_ids, translations)
    validate_audit_history!(templates, translations)

    templates.each do |template|
      puts "Validated #{template.id}:#{template.name} with one unchanged English translation"
    end

    return :dry_run unless apply

    templates.each(&:destroy!)
    verify_deletion!(template_ids)
    :removed
  end
end

puts "#{options[:apply] ? 'Apply' : 'Dry-run'} mode"

status = RemoveUnintendedNotificationTemplates.run(apply: options[:apply])

case status
when :already_absent
  puts 'All six target templates are already absent; nothing to do.'
when :dry_run
  puts 'Dry-run only; no rows changed. To delete this exact set, stop all ' \
       'vpsAdmin mail writers and pass --apply --confirm-mail-writers-stopped.'
when :removed
  puts 'Removed all six templates and their translations.'
end

puts 'Done'
