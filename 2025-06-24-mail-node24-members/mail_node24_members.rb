#!/run/current-system/sw/bin/vpsadmin-api-ruby
require 'vpsadmin'

SUBJ = {
  cs: "[vpsFree.cz] Výpadky node24.prg",
  en: "[vpsFree.cz] Outages of node24.prg",
}
MAIL = {}
MAIL[:cs] = <<END
Ahoj <%= @user.login %>,

omlouváme se za výpadky na node24.prg v posledním týdnu. Na řešení intenzivně
pracujeme, zatím však opravu nemáme a dalším resetům se nevyhneme. Nepomáhá
ani návrat na starší verzi kernelu/ZFS, pouze to běží o něco déle, takže
se spíše snažíme onu chybu najít a opravit. Pokud by se to nepodařilo,
zkusíme node24.prg přepnout na cgroups v2 [1], protože tam se zatím podobná
chyba neprojevila. O tom budeme případně informovat dále.

Pokud Ti výpadky způsobují potíže, je zde možnost přesunu na jiný node.
Jinak prosíme o trpělivost při hledání řešení, stejná chyba se totiž může
projevit i jinde. Děkujeme.

[1] https://kb.vpsfree.cz/navody/vps/cgroups

S pozdravem

tým vpsFree.cz
END

MAIL[:en] = <<END
Hi <%= @user.login %>,

we apologize for the frequent outages of node24.prg in the last week. While
we're working on finding a solution, we will not avoid further resets. Not
even older and previously used kernel/ZFS versions help, only run a little
longer. We're therefore trying to find and fix the issue(s). Should we fail
at that, we will try to switch node24.prg to cgroups v2, because so far these
issues manifest only on nodes with v1. We'll be in touch if that will be
the case.

If these outages cause you problems, it is possible to move the VPS to another
node. However, since the same issues can manifest on other nodes as well, we
kindly ask you to be patient while we work on a solution. Thank you for bearing
with us.

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
        ::User.where(object_state: 'active').each do |user|
          vpses = user.vpses.where(node_id: 125, object_state: 'active')
          next if vpses.empty?

          puts "Mailing user #{user.id} #{user.login}"
          vpses.each do |vps|
            puts "  VPS #{vps.id} #{vps.hostname} #{vps.os_template.label}"
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
