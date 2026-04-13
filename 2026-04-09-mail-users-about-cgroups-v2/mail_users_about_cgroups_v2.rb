#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Mail active users about cgroups v2.
#
# Usage:
#   ./mail_users_about_cgroups_v2.rb [execute]

require 'vpsadmin'

SUPPORTED_LANGUAGES = %i(cs en).freeze

SUBJ = {
  cs: '[vpsFree.cz] Možnost přesunu na cgroups v2',
  en: '[vpsFree.cz] cgroups v2 available',
}.freeze

MAIL = {
  cs: <<~'END',
    Ahoj <%= @user.login %>,

    rádi bychom ti nabídli možnost přesunu VPS na node s cgroups v2. V Praze
    je k dispozici node25.prg a v Brně node6.brq. Přechod na cgroups v2
    doporučujeme všem, protože podpora pro cgroups v1 z novějších vydání
    distribucí postupně mizí. Pokud ti ale VPS v současné podobě fungují
    bez potíží, není potřeba nic řešit hned.

    Tyto tvé VPS jsou aktuálně na nodech s cgroups v1:

    <% @vpses_on_v1.each do |vps| -%>
      - VPS <%= vps.id %> <%= vps.hostname %> (<%= vps.os_template.label %> cgroups v2 <%= vps.os_template.cgroup_version == 'cgroup_v1' ? 'nepodporuje' : 'podporuje' %>, node <%= vps.node.domain_name %>)
    <% end -%>

    Více o cgroups viz KB:

      https://kb.vpsfree.cz/navody/vps/cgroups

    Pokud chceš VPS přesunout, odpověz prosím na tento e-mail. Přesun je možné
    realizovat ve vybraný den a čas, případně v rámci nastaveného okna pro odstávky.

    S pozdravem

    tým vpsFree.cz
  END
  en: <<~'END',
    Hi <%= @user.login %>,

    we'd like to offer you the possibility of moving your VPS to a node
    with cgroups v2. node25.prg is available in Prague and node6.brq
    in Brno. We recommend the transition to cgroups v2 to everyone,
    because support for cgroups v1 is gradually disappearing from newer
    distribution releases. If your VPS are working fine as they are,
    there is no need to make any immediate changes.

    The following VPS are currently running on nodes with cgroups v1:

    <% @vpses_on_v1.each do |vps| -%>
      - VPS <%= vps.id %> <%= vps.hostname %> (cgroups v2 is <%= vps.os_template.cgroup_version == 'cgroup_v1' ? 'not supported' : 'supported' %> by <%= vps.os_template.label %>, node <%= vps.node.domain_name %>)
    <% end -%>

    If you'd like to have your VPS moved, please reply to this e-mail. The move can
    take place at specific day/hour or during the configured maintenance window.

    Best regards,

    vpsFree.cz team
  END
}.freeze

# Load plugins
VpsAdmin::API.default

module TransactionChains
  module Maintenance
    remove_const(:Custom)

    class Custom < TransactionChain
      label 'Notice'

      def link_chain
        sent = 0
        ignored_no_active_vpses = 0
        ignored_no_vpses_with_cgroups_v1 = 0

        eligible_users.each do |user|
          active_vpses = user_active_vpses(user)
          if active_vpses.empty?
            puts "Ignoring user #{user.id} #{user.login}: no active VPSes"
            ignored_no_active_vpses += 1
            next
          end

          vpses_on_v1, vpses_on_v2 = active_vpses.partition do |vps|
            vps.node.node_current_status.cgroup_v1?
          end
          if vpses_on_v1.empty?
            puts "Ignoring user #{user.id} #{user.login}: no VPSes with cgroups v1"
            ignored_no_vpses_with_cgroups_v1 += 1
            next
          end

          lang = language_code(user)

          puts "Mailing user #{user.id} #{user.login} lang=#{lang} active_vpses=#{active_vpses.length} v1=#{vpses_on_v1.length} v2=#{vpses_on_v2.length}"
          active_vpses.each do |vps|
            puts "  VPS #{vps.id} #{vps.hostname} #{vps.os_template.label} #{vps.node.domain_name} cgroups=#{vps.node.node_current_status.cgroup_version}"
          end

          mail_custom(
            from: 'podpora@vpsfree.cz',
            reply_to: 'podpora@vpsfree.cz',
            user:,
            role: :admin,
            subject: SUBJ[lang],
            text_plain: MAIL[lang],
            vars: {
              user:,
              active_vpses:,
              vpses_on_v1:,
              vpses_on_v2:,
            },
          )

          sent += 1
        end

        puts "Prepared #{sent} emails (ignored_no_active_vpses=#{ignored_no_active_vpses}, ignored_no_vpses_with_cgroups_v1=#{ignored_no_vpses_with_cgroups_v1})"

        fail 'not yet bro' if ARGV[0] != 'execute'
      end

      protected

      def eligible_users
        ::User.includes(:language).joins(:user_account).where(
          object_state: ::User.object_states[:active],
          mailer_enabled: true,
        ).where.not(
          user_accounts: { paid_until: nil },
        ).order('users.id')
      end

      def user_active_vpses(user)
        user.vpses.includes(:os_template, node: :node_current_status).joins(
          node: :node_current_status,
        ).where(
          vpses: { object_state: ::Vps.object_states[:active] },
        ).order('vpses.id').to_a
      end

      def language_code(user)
        code = user.language&.code&.to_sym
        SUPPORTED_LANGUAGES.include?(code) ? code : :en
      end
    end
  end
end

TransactionChains::Maintenance::Custom.fire
