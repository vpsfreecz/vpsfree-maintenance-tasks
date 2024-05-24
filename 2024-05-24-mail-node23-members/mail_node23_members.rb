#!/run/current-system/sw/bin/vpsadmin-api-ruby
require 'vpsadmin'

SUBJ = {
  cs: "[vpsFree.cz] Omluva za výpadky node23.prg",
  en: "[vpsFree.cz] Apology for outages of node23.prg",
}
MAIL = {}
MAIL[:cs] = <<END
Ahoj <%= @user.login %>,

omlouváme se za výpadky na node23.prg v poslední týdnech. Zjistili jsme, že
část z nich je způsobena hardwarovou závadou nebo chybou ve firmware.
Máme objednaný náhradní stroj, na který čekáme.

Zatím ti můžeme nabídnout přesun VPS na jiný node. Zejména node21.prg s cgroups v2
má dostatek volné kapacity. Více o cgroups se dočteš na naší KB:

  https://kb.vpsfree.cz/navody/vps/cgroups

Na node23.prg máš tyto VPS:

<% @vpses.each do |vps| -%>
  <%= vps.id %> <%= vps.hostname %> (<%= vps.os_template.label %> cgroups v2 <%= vps.os_template.cgroup_version == 'cgroup_v1' ? 'nepodporuje' : 'podporuje' %>)
<% end -%>

Migrace může proběhnout v rámci tebou nastaveného okna pro odstávky v detailu VPS
nebo přes den, pokud by ti to nevadilo.

Dej prosím vědět, jestli si přeješ svůj VPS přesunout.

S pozdravem,

tým vpsFree.cz
END

MAIL[:en] = <<END
Hi <%= @user.login %>,

we'd like to apologize for recent outages of node23.prg. We've discovered that
some of them were caused by hardware or firmware issue. We're currently waiting
for a replacement machine.

For now we can offer you migration to a different node. Especially node21.prg
with cgroups v2 has enough free capacity. You can read more about cgroups in KB:

  https://kb.vpsfree.org/manuals/vps/cgroups

You have the following VPS on node23.prg:

<% @vpses.each do |vps| -%>
  <%= vps.id %> <%= vps.hostname %> (cgroups v2 is <%= vps.os_template.cgroup_version == 'cgroup_v1' ? 'not supported' : 'supported' %> by <%= vps.os_template.label %>)
<% end -%>

The migration can take place during your maintenance window configured in VPS details
or during the day.

Please let us know if you'd like to have your VPS moved to another node.

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
          vpses = user.vpses.where(node_id: 124, object_state: 'active')
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
