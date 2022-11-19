#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Usage: $0
#
require 'vpsadmin'

SUBJ = {
  cs: "[vpsFree.cz] Ukončení provozu OpenVZ a migrace VPS <%= @vps.id %> na vpsAdminOS",
  en: "[vpsFree.cz] Discontinuation of OpenVZ, migration of VPS <%= @vps.id %> to vpsAdminOS",
}
MAIL = {}
MAIL[:cs] = <<END
Ahoj <%= @user.login %>,

19.12.2022 proběhne migrace VPS #<%= @vps.id %> - <%= @vps.hostname %> u vpsFree.cz
na naši novou virtualizační platformu vpsAdminOS. Čas upřesníme den před migrací.

Provoz OpenVZ Legacy, na kterém VPS aktuálně běží, bude po tomto dni ukončen.
Pokud by ses chtěl domluvit na nějaké dřívější datum a čas, odepiš prosím na tento
e-mail.

Více informací o přesunu a důvodech viz:

  https://blog.vpsfree.cz/migrujte-na-vpsadminos-uz-je-cas-na-aktualni-virtualizaci-s-novym-jadrem/

  https://blog.vpsfree.cz/inovujeme-skoro-vsechen-hardware-chceme-byt-energeticky-uspornejsi/

S pozdravem,
tým vpsFree.cz
END

MAIL[:en] = <<END
Hi <%= @user.login %>,

we'd like to inform you that VPS #<%= @vps.id %> - <%= @vps.hostname %>
at vpsFree.cz will be migrated to our new virtualization platform vpsAdminOS
on 26.9.2022. We will provide you with a closer time window a day before the
migration.

Our original platform OpenVZ Legacy, which the VPS uses at this time, will be
discontinued after this date. If you'd like the migration to take place sometime
sooner, please reply to this e-mail.

For more information about the migration, see our knowledge base:

  https://kb.vpsfree.org/manuals/vps/vpsadminos

Reasons behind the migration and our current strategy is described on our blog,
however, only in Czech:

  https://blog.vpsfree.cz/inovujeme-skoro-vsechen-hardware-chceme-byt-energeticky-uspornejsi/

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
