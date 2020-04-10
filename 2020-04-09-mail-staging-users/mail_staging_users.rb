#!/usr/bin/env ruby

ORIG_PWD = Dir.pwd

Dir.chdir('/opt/vpsadmin/api')
require '/opt/vpsadmin/api/lib/vpsadmin'

SUBJ = {
  cs: "[vpsFree.cz] Možnost přesunu staging VPS na produkci",
  en: "[vpsFree.cz] Migration of staging VPS to production",
}
MAIL = {}
MAIL[:cs] = <<END
Ahoj <%= @user.login %>,

na stagingu máš VPS, které provozuješ dlouhodobě místo produkce, kde bylo
k dispozici jen OpenVZ Legacy. V Praze nyní máme tři produkční nody s vpsAdminOS
a můžeme Ti nabídnout přesun VPS do produkčního prostředí. IP adresy mohou zůstat
stejné, ale může být potřeba upravit výši členského příspěvku, jestliže to máš
jako VPS navíc.

<% if @earned_ip -%>
Jako poděkování za pomoc při vývoji a testování vpsAdminOS Ti při přesunu na
produkci ponecháme IPv4 adresu ze stagingu bez navýšení členského příspěvku.
<% end -%>

Migrace je prozatím dobrovolná, stačí odpovědět na tento e-mail a na přesunu se
domluvíme.

Nas stagingu máš tyto VPS:

<% @vpses.each do |vps| -%>
 - #<%= vps.id %> - <%= vps.hostname %>
<% end -%>

S pozdravem,

tým vpsFree.cz
END

MAIL[:en] = <<END
Hi <%= @user.login %>,

you've been using staging VPS as a substitute for a production VPS, while we
were working on vpsAdminOS. We have three production nodes with vpsAdminOS
already and we can offer you a migration from staging. IP addresses can remain
the same, but the membership fee may have to be adjusted accordingly. No other
changes are necessary.

<% if @earned_ip -%>
As a thank you for your help with developing and testing vpsAdminOS, we will
give you your IPv4 address from staging without the monthly fee.
<% end -%>

For now, the migration to production is optional, simply reply to this e-mail
if you wish to have your VPS moved.

You have the following VPS on staging:

<% @vpses.each do |vps| -%>
 - #<%= vps.id %> - <%= vps.hostname %>
<% end -%>

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
            node_id: [400, 401],
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
