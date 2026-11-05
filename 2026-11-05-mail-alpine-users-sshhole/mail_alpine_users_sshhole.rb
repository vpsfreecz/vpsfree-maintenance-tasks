#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Usage: mail_alpine_users_sshhole.rb LOGFILE BACKUP_REPORT [execute]

unless ARGV.length.between?(2, 3) && (ARGV[2].nil? || ARGV[2] == 'execute')
  abort "Usage: #{$PROGRAM_NAME} LOGFILE BACKUP_REPORT [execute]"
end
ARGV.first(2).each do |path|
  abort 'LOGFILE and BACKUP_REPORT must be readable regular files' unless File.file?(path) && File.readable?(path)
end

require_relative 'run_log'
require_relative 'backup_report'
# Operator confirmed VPS 30231 was manually fixed and its original backup exists.
MANUALLY_FIXED_VPS_IDS = [30231].freeze
RUN_LOG = SshholeRunLog.read(ARGV[0]).freeze
BACKUP_REPORT = SshholeBackupReport.read(ARGV[1]).freeze
LOGGED_IDS = RUN_LOG.values.select do |entry|
  if entry[:outcome] == :changed
    report = BACKUP_REPORT[entry[:id]]
    if report && report[:policy] == 'enabled' && report[:pool] == entry[:pool]
      true
    else
      reason = report.nil? ? 'missing' : "#{report[:policy]} or pool mismatch"
      puts "Excluded VPS #{entry[:id]}: original backup evidence #{reason}"
      false
    end
  else
    entry[:outcome] == :failed && entry[:pool] == 'dozer' && MANUALLY_FIXED_VPS_IDS.include?(entry[:id])
  end
end.map { |entry| entry[:id] }.freeze
%i(changed failed unchanged incomplete).each do |outcome|
  entries = RUN_LOG.values.select { |entry| entry[:outcome] == outcome }
  puts "Log #{outcome}: #{entries.length}"
  if %i(unchanged incomplete).include?(outcome) || outcome == :failed
    entries.each do |entry|
      next if LOGGED_IDS.include?(entry[:id])

      puts "  excluded #{entry[:pool]}/#{entry[:id]}: #{outcome}"
    end
  end
end
puts "Candidate VPS IDs: #{LOGGED_IDS.length}"
puts 'Identity binding uses original log pool, backup-report node/pool and current VPS identity; historical ownership is not proved.'
if LOGGED_IDS.empty?
  puts 'No confirmed changed VPSes in log; no recipients'
  exit 0
end

require 'vpsadmin'
require 'erb'

SUBJ = {
  cs: '[vpsFree.cz] Bezpečnostní chyba SSH v Alpine Linuxu',
  en: '[vpsFree.cz] Alpine Linux SSH security issue',
}.freeze
MAIL = %i(cs en).to_h { |lang| [lang, File.read(File.join(__dir__, "mail-#{lang}.erb"))] }.freeze

VpsAdmin::API.default

module TransactionChains
  module Maintenance
    remove_const(:Custom)

    class Custom < TransactionChain
      label 'Notice'
      allow_empty

      def link_chain
        messages = []
        ::User.includes(:language).where(object_state: ::User.object_states[:active]).order(:id).each do |user|
          vpses = user.vpses.includes(:node, :os_template, :vps_current_status, dataset_in_pool: :pool).joins(
            :os_template, :vps_current_status,
          ).where(
            vpses: { object_state: ::Vps.object_states[:active], id: LOGGED_IDS },
            os_templates: { distribution: 'alpine' },
            vps_current_statuses: { status: true, is_running: true },
          ).order('vpses.id').select do |vps|
            entry = RUN_LOG.fetch(vps.id)
            if entry[:pool] != vps.pool.name
              puts "Excluded VPS #{vps.id}: current pool #{vps.pool.name} differs from log pool #{entry[:pool]}"
              false
            elsif entry[:outcome] == :changed && BACKUP_REPORT.fetch(vps.id)[:node] != vps.node.domain_name
              puts "Excluded VPS #{vps.id}: current node differs from backup report"
              false
            else
              true
            end
          end
          next if vpses.empty?

          changed_vpses = vpses
          lang = user.language&.code&.to_sym
          lang = :en unless SUBJ.key?(lang)
          vars = { user:, changed_vpses: }
          context = Object.new
          vars.each { |key, value| context.instance_variable_set("@#{key}", value) }
          body = ERB.new(MAIL.fetch(lang), trim_mode: '-').result(context.instance_eval { binding })
          messages << { user:, lang:, vars:, body:, vpses: }
        end

        if messages.empty?
          puts 'No eligible recipients; no emails prepared'
          return
        end

        messages.each do |message|
          user, lang = message.values_at(:user, :lang)
          puts "User #{user.id} #{user.login} language=#{lang}"
          message[:vpses].each do |vps|
            outcome = RUN_LOG.fetch(vps.id)[:outcome] == :changed ? 'changed' : 'manually fixed (operator confirmed backup)'
            puts "  VPS #{vps.id} #{vps.hostname}: #{outcome}"
          end
          puts SUBJ.fetch(lang)
          puts message[:body]
          mail_custom(
            from: 'podpora@vpsfree.cz',
            reply_to: 'podpora@vpsfree.cz',
            user:,
            role: :admin,
            subject: SUBJ.fetch(lang),
            text_plain: MAIL.fetch(lang),
            vars: message[:vars],
          )
        end
        puts "Prepared #{messages.length} emails"
        fail 'Preview only: rolling back; use literal execute to queue emails' unless ARGV[2] == 'execute'
      end
    end
  end
end

TransactionChains::Maintenance::Custom.fire
