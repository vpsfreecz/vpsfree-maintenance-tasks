#!/run/current-system/sw/bin/vpsadmin-api-ruby
require 'vpsadmin'

SUBJ = {
  cs: "[vpsFree.cz] Možnost přesunu VPS na node5.brq",
  en: "[vpsFree.cz] Option to move VPS to node5.brq",
}
MAIL = {}
MAIL[:cs] = <<END
Ahoj <%= @user.login %>,

omlouváme se za výpadky na node6.brq, které nás tento měsíc trápí. Na nápravě
pracujeme, ale řešení ještě může nějakou chvíli trvat.

Můžeme ti nabídnout přesun na node5.brq. který však používá cgroups v2. Více
o cgroups se dočteš ve znalostní bázi:

  https://kb.vpsfree.cz/navody/vps/cgroups

Všechny moderní distribuce vydané během posledních let cgroups v2 podporují.
Problém může být třeba starší verze Dockeru (<20.10), popř. pokud někde explicitně
nastavuješ cgroups v1 parametry. Pokud jsi s cgroups nepřišel do styku,
nejspíše to bude v pořádku.

Na node6.brq máš tyto VPS:

<% @vpses.each do |vps| -%>
  <%= vps.id %> <%= vps.hostname %> (<%= vps.os_template.label %> cgroups v2 <%= vps.os_template.cgroup_version == 'cgroup_v1' ? 'nepodporuje' : 'podporuje' %>)
<% end -%>

Přesun VPS můžeme domluvit na konkrétní čas. Vzhledem ke změně cgroups doporučujeme
posléze zkontrolovat funkčnost.

Dej prosím vědět, jestli si přeješ svůj VPS přesunout.

S pozdravem,

tým vpsFree.cz
END

MAIL[:en] = <<END
Hi <%= @user.login %>,

we'd like to apologize for outages of node6.brq that are plaguing us this month.
We're working on a solution, but it may still take some time to figure it out.

We can move your VPS to node5.brq if you'd like. Note that node5.brq uses cgroups v2.
You can read more about cgroups in our knowledge base:

  https://kb.vpsfree.org/manuals/vps/cgroups

All distributions released in the last few years support cgroups v2. Problems
can arise should you have some older Docker version (<20.10) that does not support
cgroups v2 or if you're explicitly configuring cgroups v1 parameters somewhere.
If you've never needed to know what cgroups are, then you're most likely good to go.

You have the following VPS on node6.brq:

<% @vpses.each do |vps| -%>
  <%= vps.id %> <%= vps.hostname %> (cgroups v2 is <%= vps.os_template.cgroup_version == 'cgroup_v1' ? 'not supported' : 'supported' %> by <%= vps.os_template.label %>)
<% end -%>

The move can be planned on a specific day and time. Due to the cgroups change,
we recommend that you check that everything is working as expected afterwards.

Please let us know if you'd like to have your VPS moved.

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
          vpses = user.vpses.where(node_id: 215, object_state: 'active')
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
