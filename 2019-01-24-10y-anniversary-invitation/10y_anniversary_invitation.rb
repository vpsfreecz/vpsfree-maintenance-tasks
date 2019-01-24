#!/usr/bin/env ruby

Dir.chdir('/opt/vpsadmin/api')
require '/opt/vpsadmin/api/lib/vpsadmin'

SUBJ = {
  cs: "Pozvánka na výroční schůzi a párty k 10. výročí vpsFree.cz",
  en: "Annual meeting and 10. anniversary vpsFree.cz party",
}
MAIL = {}
MAIL[:cs] = <<END
Ahoj <%= @user.login %>,

pojďme výroční schůzi pojmout jako party a oslavit 10 let existence vpsFree.cz.

Přijďte *23.2.2019* od *16:30* do pražského Brmlabu. Zaklikněte se prosím na Doodle,
ať víme, s kolika lidmi počítat, co se občerstvení týká:

  https://doodle.com/poll/axqy2afvi65dzfw5

Nejprve proběhne klasická členská schůze, shrneme historii a hlavně se podíváme na
budoucnost, která je rozhodně zajímavá. Čeká nás změna platformy, úprava stanov,
přebudování síťové infrastruktury, vstup do NIX.CZ a další novinky. To vše se dozvíte
na výroční schůzi a pak hlavně na párty.

Pro více informací si přečtěte článek na blogu:

  https://blog.vpsfree.cz/prvnich-10-let-je-za-nami-chystame-spoustu-novinek/

Přijďte prosím všichni, kdo můžete a chcete, obzvlášť prosím všichni z vás,
kterým je myšlenka vpsFree blízká - bez zpětné vazby se težko dělá cokoliv smysluplného.

Díky, těším se na vás všechny!
 
/snajpa
(Pavel Šnajdr)
(Předseda vpsFree.cz)
END

MAIL[:en] = <<END
Hi <%= @user.login %>,

let's make our annual meeting a celebration party! vpsFree.cz is now 10 years old.

Come *23.2.2019* at *16:30* to Brmlab Prague. The meeting will be held in Czech.
Please join our Doodle to let us know how many members will come and what kind
of cattering we should provide:

  https://doodle.com/poll/axqy2afvi65dzfw5

We will do traditional member meeting at first, summarize our history and mainly look into
the future, which is interesting for sure. We are heading for platform change, article
adjustments, network infrastructure rebuild, entering into NIX.CZ peering center
and many other topics. Join us and learn about the future of our organization and especially
join us at the party!

See our blog (in Czech) for more information:

  https://blog.vpsfree.cz/prvnich-10-let-je-za-nami-chystame-spoustu-novinek/

Please come if you can and if you want to, mostly if you like our ideas - we cannot do
anything meaningful without your feedback.

Thanks and I am looking forward to see you all!

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
