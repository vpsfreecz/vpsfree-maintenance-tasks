#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Fix VPSes whose UID/GID map belongs to a different user than the VPS owner.
#
# Background:
# A VPS can be visible to its owner while its `user_namespace_map_id` still
# points to a map owned by another user. When the API serializes the VPS for the
# owner, authorization of the nested UserNamespaceMap fails with "Object not
# found". The map itself may still be valid and used by the original owner, so
# do not update or delete it directly.
#
# This script changes the VPS to a map owned by the VPS owner using a custom
# maintenance transaction chain. The chain can notify the user, wait for the
# VPS' configured maintenance window, and then queue node-side userns map use,
# chown, and disuse transactions.
#
# Usage:
#   ./fix_vps_userns_map_owners.rb
#   ./fix_vps_userns_map_owners.rb --vps 16229
#   ./fix_vps_userns_map_owners.rb --vps 16229 --map 123
#   ./fix_vps_userns_map_owners.rb --dry-run
#   ./fix_vps_userns_map_owners.rb --no-mail
#   ./fix_vps_userns_map_owners.rb --no-maintenance-window
#   ./fix_vps_userns_map_owners.rb --finish-weekday 3 --finish-time 04:00
#   ./fix_vps_userns_map_owners.rb --admin-login admin
#
require 'optparse'

SUPPORTED_LANGUAGES = %i[cs en].freeze
DEFAULT_SUPPORT_EMAIL = 'podpora@vpsfree.cz'

SUBJ = {
  cs: '[vpsFree.cz] Plánovaná údržba VPS <%= @vps.id %>',
  en: '[vpsFree.cz] Scheduled maintenance of VPS <%= @vps.id %>',
}.freeze

MAIL = {
  cs: <<~'END',
    Ahoj <%= @user.login %>,

    u VPS <%= @vps.id %> <%= @vps.hostname %> potřebujeme opravit interní
    konfiguraci. Oprava se týká pouze nastavení VPS v našem systému, z tvojí
    strany není potřeba nic měnit.

    <% if @use_maintenance_window -%>
    <% if @custom_maintenance_window -%>
    Práci naplánujeme do tohoto dočasného okna údržby:
    <% else -%>
    Práci naplánujeme do nastaveného okna údržby této VPS:
    <% end -%>

    <%= @maintenance_window_text %>
    <% else -%>
    Práci spustíme po zpracování požadavku administrátorem.
    <% end -%>

    Během opravy může být VPS krátce nedostupná. Pokud by ti termín nevyhovoval,
    odpověz prosím na tento e-mail.

    S pozdravem

    tým vpsFree.cz
  END
  en: <<~'END',
    Hi <%= @user.login %>,

    we need to correct an internal configuration issue on VPS <%= @vps.id %>
    <%= @vps.hostname %>. The change only affects how the VPS is configured in
    our system; no action is required from you.

    <% if @use_maintenance_window -%>
    <% if @custom_maintenance_window -%>
    We will schedule the work during this temporary maintenance window:
    <% else -%>
    We will schedule the work during the configured maintenance window of this VPS:
    <% end -%>

    <%= @maintenance_window_text %>
    <% else -%>
    We will start the work after the administrator request is processed.
    <% end -%>

    The VPS may be briefly unavailable during the maintenance. If this timing
    would be inconvenient, please reply to this e-mail.

    Best regards,

    vpsFree.cz team
  END
}.freeze

DAY_NAMES = {
  cs: %w[neděle pondělí úterý středa čtvrtek pátek sobota],
  en: %w[Sunday Monday Tuesday Wednesday Thursday Friday Saturday],
}.freeze

WEEKDAY_ALIASES = {
  '0' => 0,
  '1' => 1,
  '2' => 2,
  '3' => 3,
  '4' => 4,
  '5' => 5,
  '6' => 6,
  'sun' => 0,
  'sunday' => 0,
  'mon' => 1,
  'monday' => 1,
  'tue' => 2,
  'tuesday' => 2,
  'wed' => 3,
  'wednesday' => 3,
  'thu' => 4,
  'thursday' => 4,
  'fri' => 5,
  'friday' => 5,
  'sat' => 6,
  'saturday' => 6,
}.freeze

def parse_weekday(value)
  weekday = WEEKDAY_ALIASES[value.to_s.strip.downcase]
  return weekday unless weekday.nil?

  fail OptionParser::InvalidArgument, "#{value.inspect} is not a weekday (use 0-6 or English day name)"
end

def parse_time(value)
  match = /\A(\d{1,2}):(\d{2})\z/.match(value.to_s.strip)
  fail OptionParser::InvalidArgument, "#{value.inspect} is not in HH:MM format" unless match

  hour = match[1].to_i
  minute = match[2].to_i

  unless hour.between?(0, 23) && minute.between?(0, 59)
    fail OptionParser::InvalidArgument, "#{value.inspect} is not a valid time"
  end

  (hour * 60) + minute
end

options = {
  dry_run: false,
  finish_minutes_source: nil,
  mail_from: DEFAULT_SUPPORT_EMAIL,
  mail_reply_to: DEFAULT_SUPPORT_EMAIL,
  reserve_minutes: 15,
  send_mail: true,
  use_maintenance_window: true,
  vps_ids: [],
}

OptionParser.new do |opts|
  opts.banner = 'Usage: fix_vps_userns_map_owners.rb [options]'

  opts.on('--vps ID', Integer, 'Only repair selected VPS; can be used repeatedly') do |value|
    options[:vps_ids] << value
  end

  opts.on('--map ID', Integer, 'Use selected target map; requires exactly one --vps') do |value|
    options[:map_id] = value
  end

  opts.on('--admin-login LOGIN', 'Set User.current for transaction-chain audit metadata') do |value|
    options[:admin_login] = value
  end

  opts.on('--[no-]mail', 'Send an email to the VPS owner before maintenance (default: yes)') do |value|
    options[:send_mail] = value
  end

  opts.on('--mail-from EMAIL', 'Sender address for notification email') do |value|
    options[:mail_from] = value
  end

  opts.on('--mail-reply-to EMAIL', 'Reply-To address for notification email') do |value|
    options[:mail_reply_to] = value
  end

  opts.on('--[no-]maintenance-window', 'Wait for the VPS configured maintenance window (default: yes)') do |value|
    options[:use_maintenance_window] = value
  end

  opts.on('--finish-weekday DAY', String, 'Use custom maintenance finish day, 0=Sunday..6=Saturday') do |value|
    options[:finish_weekday] = parse_weekday(value)
  end

  opts.on('--finish-time HH:MM', String, 'Use custom maintenance finish time') do |value|
    if options[:finish_minutes_source]
      fail OptionParser::InvalidOption, "--finish-time conflicts with #{options[:finish_minutes_source]}"
    end

    options[:finish_minutes] = parse_time(value)
    options[:finish_minutes_source] = '--finish-time'
  end

  opts.on('--finish-minutes N', Integer, 'Use custom maintenance finish minutes from midnight') do |value|
    if options[:finish_minutes_source]
      fail OptionParser::InvalidOption, "--finish-minutes conflicts with #{options[:finish_minutes_source]}"
    end

    options[:finish_minutes] = value
    options[:finish_minutes_source] = '--finish-minutes'
  end

  opts.on('--reserve-minutes N', Integer, 'Required minutes left in the maintenance window (default: 15)') do |value|
    options[:reserve_minutes] = value
  end

  opts.on('--dry-run', 'Show what would be done, do not enqueue transactions') do
    options[:dry_run] = true
  end

  opts.on('-h', '--help', 'Show this help') do
    puts opts
    exit 0
  end
end.parse!

if options[:map_id] && options[:vps_ids].length != 1
  fail '--map requires exactly one --vps'
end

if options[:reserve_minutes] <= 0
  fail '--reserve-minutes must be a positive integer'
end

finish_weekday_set = !options[:finish_weekday].nil?
finish_minutes_set = !options[:finish_minutes].nil?

if finish_weekday_set != finish_minutes_set
  fail '--finish-weekday must be set together with --finish-time or --finish-minutes'
end

if finish_minutes_set && !options[:finish_minutes].between?(0, (24 * 60) - 30)
  fail '--finish-time/--finish-minutes must be between 00:00 and 23:30'
end

if finish_weekday_set && !options[:use_maintenance_window]
  fail '--finish-weekday conflicts with --no-maintenance-window'
end

require 'vpsadmin'

if options[:admin_login]
  admin = User.find_by!(login: options[:admin_login])
  User.current = admin
  puts "Running as #{admin.login} for transaction-chain audit metadata"
end

module TransactionChains
  module Maintenance
    remove_const(:Custom) if const_defined?(:Custom, false)

    class Custom < TransactionChain
      label 'Repair VPS configuration'

      def link_chain(vps, current_map, target_map, opts)
        lock(vps)
        concerns(:affect, [vps.class.name, vps.id])

        if opts[:send_mail]
          mail_custom(
            from: opts[:mail_from],
            reply_to: opts[:mail_reply_to],
            user: vps.user,
            role: :admin,
            subject: ::SUBJ.fetch(opts[:language]),
            text_plain: ::MAIL.fetch(opts[:language]),
            vars: {
              custom_maintenance_window: opts[:custom_maintenance_window],
              maintenance_window_text: opts[:maintenance_window_text],
              use_maintenance_window: opts[:use_maintenance_window],
              user: vps.user,
              vps:,
            },
          )
        end

        if opts[:use_maintenance_window]
          append_t(
            Transactions::MaintenanceWindow::Wait,
            args: [vps, opts[:reserve_minutes]],
            kwargs: { maintenance_windows: opts[:maintenance_windows] },
          )
        end

        use_chain(UserNamespaceMap::Use, args: [vps, target_map])

        append_t(Transactions::Vps::Chown, args: [vps, current_map, target_map]) do |t|
          t.edit(vps, user_namespace_map_id: target_map.id)
        end

        use_chain(
          UserNamespaceMap::Disuse,
          args: [vps],
          kwargs: { userns_map: current_map },
        )
      end
    end
  end
end

def bad_vps_scope(vps_ids)
  scope =
    Vps
      .including_deleted
      .left_outer_joins(user_namespace_map: :user_namespace)
      .where.not(vpses: { user_namespace_map_id: nil })
      .where(
        'user_namespace_maps.id IS NOT NULL ' \
        'AND user_namespaces.id IS NOT NULL ' \
        'AND user_namespaces.user_id <> vpses.user_id'
      )

  scope = scope.where(vpses: { id: vps_ids }) if vps_ids.any?

  scope
    .includes(
      :node,
      :user,
      user_namespace_map: [
        :user_namespace_map_entries,
        { user_namespace: :user }
      ]
    )
    .order(:id)
end

def owner_maps(user)
  UserNamespaceMap
    .joins(:user_namespace)
    .where(user_namespaces: { user_id: user.id })
    .includes(:user_namespace_map_entries, user_namespace: :user)
    .order(:id)
    .to_a
end

def map_usage_count(map)
  Vps.including_deleted.where(user_namespace_map_id: map.id).count
end

def map_entries(map)
  map.user_namespace_map_entries.sort_by(&:id).map do |entry|
    "#{entry.kind} #{entry.vps_id}:#{entry.ns_id}:#{entry.count}"
  end
end

def language_code(user)
  code = user.language&.code&.to_sym
  SUPPORTED_LANGUAGES.include?(code) ? code : :en
end

def format_minutes(minutes)
  format('%02d:%02d', minutes / 60, minutes % 60)
end

def format_maintenance_windows(windows, lang)
  days = DAY_NAMES.fetch(lang)

  windows.map do |window|
    format(
      '%<day>s %<open>s-%<close>s',
      day: days[window.weekday],
      open: format_minutes(window.opens_at),
      close: format_minutes(window.closes_at),
    )
  end.join("\n")
end

def format_finish(weekday, minutes, lang)
  "#{DAY_NAMES.fetch(lang)[weekday]} #{format_minutes(minutes)}"
end

def configured_maintenance_windows(vps)
  vps.vps_maintenance_windows.where(is_open: true).order(:weekday).to_a
end

def print_map(prefix, map)
  owner = map.user_namespace.user
  entries = map_entries(map)

  puts format(
    '%<prefix>s map=%<map_id>d label=%<label>s user=%<login>s(%<user_id>d) userns=%<userns_id>d used_by_vps=%<count>d',
    prefix:,
    map_id: map.id,
    label: map.label,
    login: owner.login,
    user_id: owner.id,
    userns_id: map.user_namespace_id,
    count: map_usage_count(map)
  )
  puts "#{prefix} entries: #{entries.empty? ? 'none' : entries.join(', ')}"
end

def prompt(question)
  print question
  STDIN.gets&.strip
end

def confirm?(question)
  prompt("#{question} [y/N]: ").to_s.downcase == 'y'
end

def choose_target_map(vps, candidates, forced_map_id)
  if forced_map_id
    map = candidates.find { |candidate| candidate.id == forced_map_id }
    fail "Map #{forced_map_id} does not belong to VPS owner #{vps.user.login}" unless map

    return map
  end

  return candidates.first if candidates.length == 1

  puts 'Candidate owner maps:'
  candidates.each { |map| print_map('  candidate', map) }

  loop do
    value = prompt("Target map id for VPS #{vps.id} (empty to skip): ")
    return nil if value.nil? || value.empty?

    map_id = Integer(value, exception: false)
    map = candidates.find { |candidate| candidate.id == map_id }
    return map if map

    puts "Map #{value} is not one of the candidate maps for #{vps.user.login}"
  end
end

def process_vps(
  vps,
  finish_minutes:,
  finish_weekday:,
  forced_map_id:,
  dry_run:,
  mail_from:,
  mail_reply_to:,
  reserve_minutes:,
  send_mail:,
  use_maintenance_window:
)
  current_map = vps.user_namespace_map
  candidates = owner_maps(vps.user)
  lang = language_code(vps.user)

  puts
  puts "VPS #{vps.id} #{vps.hostname} on #{vps.node.domain_name}"
  puts "  owner: #{vps.user.login}(#{vps.user_id})"
  print_map('  current', current_map)

  if candidates.empty?
    puts "  SKIP: owner #{vps.user.login} has no user namespace maps"
    return :skipped
  end

  target_map = choose_target_map(vps, candidates, forced_map_id)
  unless target_map
    puts '  SKIP: no target map selected'
    return :skipped
  end

  if target_map.id == current_map.id
    puts '  SKIP: target map is already assigned'
    return :skipped
  end

  print_map('  target ', target_map)

  maintenance_windows = []
  maintenance_window_text = nil
  custom_maintenance_window = !finish_weekday.nil?

  if custom_maintenance_window
    maintenance_windows = ::VpsMaintenanceWindow.make_for(
      vps,
      finish_weekday:,
      finish_minutes:,
    )
    maintenance_window_text = format_maintenance_windows(maintenance_windows, lang)

    puts "  maintenance window: custom finish=#{format_finish(finish_weekday, finish_minutes, :en)}, reserve=#{reserve_minutes} minutes"
    format_maintenance_windows(maintenance_windows, :en).each_line do |line|
      puts "    #{line.chomp}"
    end

  elsif use_maintenance_window
    maintenance_windows = configured_maintenance_windows(vps)

    if maintenance_windows.empty?
      puts '  SKIP: VPS has no open maintenance windows; use --no-maintenance-window to enqueue immediately'
      return :skipped
    end

    maintenance_window_text = format_maintenance_windows(maintenance_windows, lang)
    puts "  maintenance window: configured, reserve=#{reserve_minutes} minutes"
    format_maintenance_windows(maintenance_windows, :en).each_line do |line|
      puts "    #{line.chomp}"
    end

  else
    puts '  maintenance window: disabled; transactions will run as soon as workers process them'
  end

  effective_send_mail = send_mail && vps.user.mailer_enabled

  if effective_send_mail
    puts "  email: enabled, language=#{lang}, from=#{mail_from}, reply-to=#{mail_reply_to}"
  elsif send_mail
    puts '  email: skipped, user has mail delivery disabled'
  else
    puts '  email: disabled by --no-mail'
  end

  unless confirm?("Enqueue VPS #{vps.id} repair #{current_map.id} -> #{target_map.id}?")
    puts '  SKIP: not confirmed'
    return :skipped
  end

  if dry_run
    puts '  DRY-RUN: transaction chain not enqueued'
    return :dry_run
  end

  chain, = TransactionChains::Maintenance::Custom.fire(
    vps,
    current_map,
    target_map,
    {
      language: lang,
      mail_from:,
      mail_reply_to:,
      maintenance_window_text:,
      maintenance_windows:,
      custom_maintenance_window:,
      reserve_minutes:,
      send_mail: effective_send_mail,
      use_maintenance_window:,
    },
  )

  puts "  OK: queued transaction chain #{chain.id}"
  :fixed
end

selected_ids = options[:vps_ids].uniq
bad_vpses = bad_vps_scope(selected_ids).to_a

if selected_ids.any?
  found_ids = Vps.including_deleted.where(id: selected_ids).pluck(:id)
  missing_ids = selected_ids - found_ids
  fail "VPS not found: #{missing_ids.join(', ')}" if missing_ids.any?

  selected_without_mismatch = selected_ids - bad_vpses.map(&:id)
  selected_without_mismatch.each do |vps_id|
    vps = Vps.including_deleted.find(vps_id)
    puts "VPS #{vps.id} #{vps.hostname}: no cross-owner user namespace map mismatch"
    puts "  owner: #{vps.user.login}(#{vps.user_id})"
    puts "  map: #{vps.user_namespace_map_id || 'none'}"
  end
end

if bad_vpses.empty?
  puts 'No cross-owner VPS user namespace map mismatches found.'
  exit 0
end

puts "Found #{bad_vpses.length} cross-owner VPS user namespace map mismatch(es)."
puts 'Dry-run mode is enabled.' if options[:dry_run]

counts = Hash.new(0)

bad_vpses.each do |vps|
  result = process_vps(
    vps,
    finish_minutes: options[:finish_minutes],
    finish_weekday: options[:finish_weekday],
    forced_map_id: options[:map_id],
    dry_run: options[:dry_run],
    mail_from: options[:mail_from],
    mail_reply_to: options[:mail_reply_to],
    reserve_minutes: options[:reserve_minutes],
    send_mail: options[:send_mail],
    use_maintenance_window: options[:use_maintenance_window],
  )
  counts[result] += 1
rescue StandardError => e
  counts[:failed] += 1
  warn "  ERROR: #{e.class}: #{e.message}"
  warn e.backtrace.first(5).map { |line| "    #{line}" }.join("\n")
end

puts
puts 'Summary:'
%i[fixed dry_run skipped failed].each do |key|
  puts "  #{key}: #{counts[key]}"
end

exit(counts[:failed] > 0 ? 1 : 0)
