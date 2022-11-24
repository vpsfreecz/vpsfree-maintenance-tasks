#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Usage: $0
#
require 'vpsadmin'

SUBJ = {
  cs: "[vpsFree.cz] Připomínka ukončení provozu OpenVZ a migrace VPS <%= @vps.id %>",
  en: "[vpsFree.cz] Reminder about discontinuation of OpenVZ and migration of VPS <%= @vps.id %>",
}
MAIL = {}
MAIL[:cs] = <<END
Ahoj <%= @user.login %>,

pro jistotu připomínáme, že 19.12.2022 proběhne migrace VPS #<%= @vps.id %> - <%= @vps.hostname %>
u vpsFree.cz na naši novou virtualizační platformu vpsAdminOS.

Po tomto datu už nebude cesty zpět, neboť OpenVZ nody budeme z důvodu úspory
energie vypínat. Doporučujeme si aspoň ověřit, že systém bude fungovat podle
očekávání naklonováním na Playground a řešit to, dokud je čas. Nejlépe se na
migraci s námi domluvit dříve. Na případné komplikace v poslední den migrace
už potom nebudeme moct brát ohled.

Používáš-li ve VPS Docker 1.10, na nové platformě je potřeba jej aktualizovat.
Pokud máš ve VPS QEMU/KVM a konfiguraci sítě podle původního návodu v KB,
bude to vyžadovat změny.

S pozdravem,
tým vpsFree.cz
END

MAIL[:en] = <<END
Hi <%= @user.login %>,

we'd like to remind you that VPS #<%= @vps.id %> - <%= @vps.hostname %>
at vpsFree.cz will be migrated to our new virtualization platform vpsAdminOS
on 19.12.2022.

After this date, it will no longer be possible to go back, because all remaining
OpenVZ nodes will be shutdown to save on power consumption. We recommend you to
at least verify that the VPS will function be cloning it to Playground while
there is still time. It would be best to schedule the migration sooner at your
convenience. Should you discover issues on the last day of migrations, we will
not be able to accomodate you.

If you're using Docker 1.10, it will be necessary to upgrade it. In case you're
using QEMU/KVM, network configuration described in our original KB article is
not compatible.

Best regards,

vpsFree.cz team
END

module TransactionChains
  module Maintenance
    remove_const(:Custom)

    class Custom < TransactionChain
      label 'Notice'

      def link_chain
        ::Vps.joins(:user, :node).where(
          vpses: {object_state: ::Vps.object_states[:active]},
          nodes: {hypervisor_type: ::Node.hypervisor_types[:openvz]},
          users: {level: 2},
        ).order('vpses.id').each do |vps|
          lang_code = vps.user.language.code.to_sym
          
          unless SUBJ.has_key?(lang_code)
            puts "VPS #{vps.id} - translation not found"
            next
          end

          puts "VPS #{vps.id} #{vps.hostname} #{vps.node.domain_name} #{vps.user.login}"

          mail_custom(
            from: 'podpora@vpsfree.cz',
            reply_to: 'podpora@vpsfree.cz',
            user: vps.user,
            role: :admin,
            subject: SUBJ[lang_code],
            text_plain: MAIL[lang_code],
            vars: {user: vps.user, vps: vps},
          )
        end

        fail 'not yet bro'
      end
    end
  end
end

TransactionChains::Maintenance::Custom.fire
