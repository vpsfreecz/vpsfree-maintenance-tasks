#!/usr/bin/env ruby

ORIG_PWD = Dir.pwd

Dir.chdir('/opt/vpsadmin/api')
require '/opt/vpsadmin/api/lib/vpsadmin'

SUBJ = {
  cs: "[vpsFree.cz] Možnost přesunu VPS na vpsAdminOS",
  en: "[vpsFree.cz] Migration of OpenVZ VPS to vpsAdminOS",
}
MAIL = {}
MAIL[:cs] = <<END
Ahoj <%= @user.login %>,

na node18.prg na kterém je tvá VPS máme v plánu provést údržbu a bude potřeba 
tvou VPS přemigrovat na jiný node. 

Rádi bychom Ti navrhnuli možnost migrace na jeden z našich produkčních nodů, 
kde běží náš vpsAdminOS. 
viz. https://kb.vpsfree.cz/navody/vps/vpsadminos 

Pokud bys měl zájem o migraci na vpsAdminOS, ujisti se, prosím, jestli nemáš 
v detailu VPS ve vpsAdminu nějaké mounty (připojení na NAS). 
Pokud máš, předělej si je prosím na exporty a mounty smaž. 
viz. https://kb.vpsfree.cz/navody/vps/vpsadminos/storage

Bylo by akorát potřeba, aby sis po migraci na vpsAdminOS zkontroloval, 
jestli všechno funguje a pokud ne, tak nám dej vědět. 

V případě, že se neozveš, přesuneme tvou VPS na node s OpenVZ. 
O následné migraci Tě bude informovat vpsAdmin. 

Nas node18.prg máš tyto VPS:

<% @vpses.each do |vps| -%>
 - #<%= vps.id %> - <%= vps.hostname %>
<% end -%>

S pozdravem,

tým vpsFree.cz
END

MAIL[:en] = <<END
Hi <%= @user.login %>,


Best regards,

vpsFree.cz team
END

module TransactionChains
  module Maintenance
    remove_const(:Custom)

    class Custom < TransactionChain
      label 'Notice'

      def link_chain
        limit = 20
        count = 0
        logfile = File.join(ORIG_PWD, 'notified-users.txt')

        notified =
          if File.exist?(logfile)
            File.readlines(logfile).map { |v| v.strip.to_i }
          else
            []
          end

        earned = File.readlines(File.join(ORIG_PWD, 'earned.txt')).map { |v| v.strip.to_i }
        
        log = File.open(logfile, 'a')

        ::User.where(
          object_state: [::User.object_states[:active]],
        ).where.not(
          id: [1,2],
        ).each do |user|
          next if notified.include?(user.id)
          break if count >= limit

          vpses = user.vpses.where(
            object_state: [::Vps.object_states[:active]],
            node_id: [119],
            expiration_date: nil,
          )
          next if vpses.empty?

          puts "Mailing user #{user.id} #{user.login}"
          vpses.each do |vps|
            puts "  VPS #{vps.id} #{vps.hostname}"
          end

          if earned.include?(user.id)
            puts "  earned IP"
          end

          mail_custom(
            from: 'podpora@vpsfree.cz',
            reply_to: 'podpora@vpsfree.cz',
            user: user,
            role: :admin,
            subject: SUBJ[user.language.code.to_sym],
            text_plain: MAIL[user.language.code.to_sym],
            vars: {
              user: user,
              vpses: vpses,
              earned_ip: earned.include?(user.id),
            },
          )

          count += 1
          log.puts(user.id.to_s)
        end

        fail 'not yet bro'
      end
    end
  end
end

TransactionChains::Maintenance::Custom.fire
