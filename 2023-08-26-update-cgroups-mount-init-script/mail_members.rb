#!/run/current-system/sw/bin/vpsadmin-api-ruby
require 'vpsadmin'

SUBJ = {
  cs: "[vpsFree.cz] Provedena aktualizace init skriptu na připojení cgroups",
  en: "[vpsFree.cz] Update of init script that mounts cgroups",
}
MAIL = {}
MAIL[:cs] = <<'END'
Ahoj <%= @user.login %>,

chtěli bychom Tě informovat o provedené aktualizaci init skriptu, který se stará
o připojení cgroups [1] při startu VPS.

Původní init skript obsahoval pevně daný seznam cgroups, které se do /sys/fs/cgroup
připojovaly. Protože může docházet ke změnám dostupných cgroups ze strany kernelu,
rozhodli jsme se tento init skript upravit tak, aby si při spuštění sám zjistil,
které cgroups má připojit. Díky tomu bychom se do buoducna měli vyhnout dalším
úpravám.

Změna se týká následujících VPS:

<% @vpses.each do |vps| -%>
  - VPS <%= vps.id %> <%= vps.hostname %> -- <%= vps.allow_admin_modifications ? "upraven soubor #{{'alpine' => '/etc/init.d/cgroups-mount', 'devuan' => '/etc/init.d/cgroups-mount', 'slackware' => '/etc/rc.d/rc.vpsadminos.cgroups', 'void' => '/etc/runit/core-services/10-vpsadminos-cgroups.sh'}[vps.os_template.distribution]}" : 'úpravy ze strany vpsFree.cz nejsou ve vpsAdminu povoleny' %>
<% end -%>
<% if @vpses.to_a.any? { |vps| !vps.allow_admin_modifications } -%>

Aktuální verzi init skriptu najdeš v repozitáři vpsAdminOS:

  https://github.com/vpsfreecz/vpsadminos/tree/staging/image-scripts/images
<% end -%>

[1] https://kb.vpsfree.cz/navody/vps/cgroups

S pozdravem

tým vpsFree.cz
END

MAIL[:en] = <<'END'
Hi <%= @user.login %>,

we'd like to inform you about an update of an init script that is used to mount
cgroups [1] when the VPS is starting.

The original init script contained a hardcoded list of cgroups to mount within
/sys/fs/cgroup. This approach turned out to be troublesome, because the available
controllers can change depending on the kernel. We've decided to change the init
script to automatically discover the cgroups to mount at runtime, thus hopefully
avoiding future modifications.

The following VPS are affected:

<% @vpses.each do |vps| -%>
  - VPS <%= vps.id %> <%= vps.hostname %> -- <%= vps.allow_admin_modifications ? "updated file #{{'alpine' => '/etc/init.d/cgroups-mount', 'devuan' => '/etc/init.d/cgroups-mount', 'slackware' => '/etc/rc.d/rc.vpsadminos.cgroups', 'void' => '/etc/runit/core-services/10-vpsadminos-cgroups.sh'}[vps.os_template.distribution]}" : 'modifications by vpsFree.cz admins are disallowed in vpsAdmin' %>
<% end -%>
<% if @vpses.to_a.any? { |vps| !vps.allow_admin_modifications } -%>

The up-to-date init script can be found in vpsAdminOS repository:

  https://github.com/vpsfreecz/vpsadminos/tree/staging/image-scripts/images
<% end -%>

[1] https://kb.vpsfree.org/manuals/vps/cgroups

Best regards,

vpsFree.cz team
END

module TransactionChains
  module Maintenance
    remove_const(:Custom)

    class Custom < TransactionChain
      label 'Notice'

      def link_chain
        ::User.where(
          object_state: [::User.object_states[:active]],
        ).each do |user|
          vpses = user.vpses.joins(:os_template).where(
            vpses: {object_state: [::Vps.object_states[:active]]},
            os_templates: {distribution: %w(alpine devuan slackware void)},
          )
          next if vpses.empty?

          puts "Mailing user #{user.id} #{user.login}"
          vpses.each do |vps|
            puts "  VPS #{vps.id} #{vps.hostname} #{vps.os_template.label} -- #{vps.allow_admin_modifications ? 'allowed' : 'NOT allowed'}"
          end

          mail_custom(
            from: 'podpora@vpsfree.cz',
            reply_to: 'podpora@vpsfree.cz',
            user: user,
            role: :admin,
            subject: SUBJ[user.language.code.to_sym],
            text_plain: MAIL[user.language.code.to_sym],
            vars: {user: user, vpses: vpses},
          )
        end

        fail 'not yet' if ARGV[0] != 'execute'
      end
    end
  end
end

TransactionChains::Maintenance::Custom.fire
