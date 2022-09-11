#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Usage: $0 <node id>
#
require 'vpsadmin'

SUBJ = {
  cs: "[vpsFree.cz] Naplánovaná automatická migrace VPS <%= @vps.id %> na vpsAdminOS",
  en: "[vpsFree.cz] Scheduled migration of VPS <%= @vps.id %> to vpsAdminOS",
}
MAIL = {}
MAIL[:cs] = <<END
Ahoj <%= @user.login %>, 

nastal čas automatické migrace Tvého VPS #<%= @vps.id %> - <%= @vps.hostname %>
u vpsFree.cz na vpsAdminOS v průběhu dne 26.9.2022.

Bylo by nejlepší, kdybys odpověděl na tento email a domluvil se s námi na migraci
na nějaké konkrétní datum a čas, kdy budeš moct zkontrovat, že všechno funguje tak,
jak má.

  https://blog.vpsfree.cz/migrujte-na-vpsadminos-uz-je-cas-na-aktualni-virtualizaci-s-novym-jadrem/

S pozdravem, 
tým vpsFree.cz
END

MAIL[:en] = <<END
Hi <%= @user.login %>,

we'd like to inform you that VPS #<%= @vps.id %> - <%= @vps.hostname %>
at vpsFree.cz will be automatically migrated to vpsAdminOS on 26.9.2022.

It would be best if you could reply to this email, so that we could migrate
the VPS at a time of your choosing, when you could verify that everything works
as expected.

For more information, see our knowledge base:

  https://kb.vpsfree.org/manuals/vps/vpsadminos

Best regards,

vpsFree.cz team
END

module TransactionChains
  module Maintenance
    remove_const(:Custom)

    class Custom < TransactionChain
      label 'Notice'

      def link_chain(node_id)
        ::Vps.joins(:user, :node).where(
          vpses: {object_state: ::Vps.object_states[:active]},
          nodes: {hypervisor_type: ::Node.hypervisor_types[:openvz]},
          node_id: node_id,
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

if ARGV.length != 1
  warn "Usage: #{$0} <node id>"
  exit(false)
end

TransactionChains::Maintenance::Custom.fire(ARGV[0].to_i)
