#!/usr/bin/env ruby

Dir.chdir('/opt/vpsadmin/api')
require '/opt/vpsadmin/api/lib/vpsadmin'

SUBJ = {
  cs: "[vpsFree.cz] Uvolnění playground VPS",
  en: "[vpsFree.cz] Clearing out playground VPS",
}
MAIL = {}
MAIL[:cs] = <<END
Ahoj <%= @user.login %>,

chystáme se přeinstalovat playground na vpsAdminOS, naši novou virtualizační
platformu, kterou nahrazujeme OpenVZ Legacy. Abychom to mohli udělat, musíme
čekat, až expirují všechny playground VPS. Proto bychom Tě chtěli požádát,
abys svou playground VPS smazal, jakmile ji nebudeš potřebovat.
Existující playground VPS už nepůjde prodloužit.

Na playgroundu máš tyto VPS:

<% @vpses.each do |vps| -%>
 - #<%= vps.id %> - <%= vps.hostname %> (expiruje <%= vps.expiration_date.strftime('%Y-%m-%d') %>)
<% end -%>

Budeme rádi, pokud nám můžeš pomoci vyklízení playgroundu urychlit.

S pozdravem,

tým vpsFree.cz
END

MAIL[:en] = <<END
Hi <%= @user.login %>,

we're about to reinstall playground to vpsAdminOS, our new virtualization platform
to replace OpenVZ Legacy. In order to do that, we must wait for all playground
VPS to expire. We'd like to ask you if you could remove your VPS ahead of time,
unless you really need it. Existing playground VPS will not be prolonged.

You have the following playground VPS:

<% @vpses.each do |vps| -%>
 - #<%= vps.id %> - <%= vps.hostname %> (expires on <%= vps.expiration_date.strftime('%Y-%m-%d') %>)
<% end -%>

We'd appreaciate it if you could help us clearing out playground faster.

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
          vpses = user.vpses.where(
            object_state: [::Vps.object_states[:active]],
            node_id: 300,
          ).where.not(expiration_date: nil)
          next if vpses.empty?

          puts "Mailing user #{user.id} #{user.login}"
          vpses.each do |vps|
            puts "  VPS #{vps.id} #{vps.hostname} (#{vps.expiration_date.strftime('%Y-%m-%d')})"
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

        fail 'not yet bro'
      end
    end
  end
end

TransactionChains::Maintenance::Custom.fire
