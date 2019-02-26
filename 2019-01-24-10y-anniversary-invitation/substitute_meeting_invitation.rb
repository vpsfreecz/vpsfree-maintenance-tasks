#!/usr/bin/env ruby

Dir.chdir('/opt/vpsadmin/api')
require '/opt/vpsadmin/api/lib/vpsadmin'

SUBJ = {
  cs: "Pozvánka na náhradní členskou schůzi, 9. března 2019 v Brně",
  en: "Invitation to a substitute member meeting, March 9, 2019 in Brno",
}
MAIL = {}
MAIL[:cs] = <<END
Ahoj <%= @user.login %>,

Rada spolku vpsFree.cz zve členy na náhradní členskou schůzi, která se bude konat
9. března 2019 v 16:30 v brněnském Base48 [1]. Schůze bude náhradou za předchozí
schůzi konanou 23. února 2019 v Praze, kde jsme nebyli usnášeníschopní.

Na programu je pouze změna stanov vpsFree.cz a přidání možnosti on-line hlasování.
Znění upravených stanov bude před konáním schůze dostupné v community mailing
listu [2] k případné diskusi.

[1]: https://base48.cz/
[2]: https://kb.vpsfree.cz/informace/komunikace
 
/snajpa
(Pavel Šnajdr)
(Předseda vpsFree.cz)
END

MAIL[:en] = <<END
Hi <%= @user.login %>,

The council of vpsFree.cz invites its members to a substitute member meeting
to be held 9 March 2019 at 4:30 pm Base48, Brno [1]. The meeting will replace 
previous meeting held on 23 February 2019 in Prague where we didn't have
enought attendance to constitute a quorum.

There is only one topic: changes in bylaws of vpsFree.cz – adding on-line
voting option. The text of the revised articles will be discussed in
community mailing list [2] before meeting.

[1]: https://base48.cz/
[2]: https://kb.vpsfree.org/information/communication

/snajpa
(Pavel Šnajdr)
(chairman of vpsFree.cz)
END

module TransactionChains
  module Maintenance
    remove_const(:Custom)

    class Custom < TransactionChain
      label 'Invitation'

      def link_chain
        ::User.where(
          object_state: [
            ::User.object_states[:active],
            ::User.object_states[:suspended],
          ],
        ).each do |user|
          puts "Inviting user #{user.id} #{user.login}"
          mail_custom(
            from: 'pavel.snajdr@vpsfree.cz',
            reply_to: 'podpora@vpsfree.cz',
            user: user,
            role: :account,
            subject: SUBJ[user.language.code.to_sym],
            text_plain: MAIL[user.language.code.to_sym],
            vars: {user: user},
          )
        end

        fail 'not yet bro'
      end
    end
  end
end

TransactionChains::Maintenance::Custom.fire
