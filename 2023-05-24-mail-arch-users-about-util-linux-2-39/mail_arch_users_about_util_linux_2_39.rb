#!/run/current-system/sw/bin/vpsadmin-api-ruby
require 'vpsadmin'

SUBJ = {
  cs: "[vpsFree.cz] Upozornění na util-linux 2.39 v Arch Linuxu",
  en: "[vpsFree.cz] Warning about util linux 2.39 in Arch Linux",
}
MAIL = {}
MAIL[:cs] = <<END
Ahoj <%= @user.login %>,

chtěli bychom Tě upozornit na aktualizaci util-linux na verzi 2.39, po které
systém pravděpodobně nastartuje do nouzového řežimu kvůli tmp.mount. Je to
způsobeno chybou v util-linux, viz

  https://github.com/util-linux/util-linux/issues/2247

  https://github.com/util-linux/util-linux/pull/2248

Pokud už máš aktualizováno, dá se to obejít zakomentováním /tmp v /etc/fstab.
Může to však mít vliv i na další mounty. Proto doporučujeme s aktualizací počkat
na opravu util-linux.

S pozdravem,

tým vpsFree.cz
END

MAIL[:en] = <<END
Hi <%= @user.login %>,

we would like to inform you about a bug in util-linux 2.39 which may result
in your system starting into emergency mode due to an error with tmp.mount.
For more information, see

  https://github.com/util-linux/util-linux/issues/2247

  https://github.com/util-linux/util-linux/pull/2248

In case you've already upgraded, the emergency mode can be bypassed by
commenting-out /tmp mount in /etc/fstab. Note that other mounts can still be
failing. We therefore recommend to wait with upgrades until util-linux is fixed.

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
          vpses = user.vpses.joins(:os_template).where(
            vpses: {object_state: [::Vps.object_states[:active]]},
            os_templates: {distribution: %w(arch)},
          )
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
