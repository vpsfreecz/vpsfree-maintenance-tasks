#!/run/current-system/sw/bin/vpsadmin-api-ruby
require 'vpsadmin'

SUBJ = {
  cs: "[vpsFree.cz] Upozornění na aktualizaci Docker 23.0.0",
  en: "[vpsFree.cz] Warning about upgrade to Docker 23.0.0",
}
MAIL = {}
MAIL[:cs] = <<END
Ahoj <%= @user.login %>,

používáš-li ve VPS Docker na CentOS/AlmaLinux/Rocky/Fedora, chtěli bychom Tě
upozornit na aktualizaci na verzi 23.0.0, po jejíž instalaci nebudou startovat
kontejnery. Docker se totiž snaží použít AppArmor, protože jej detekuje v kernelu,
i když ve VPS AppArmor utility nainstalované nejsou. Tyto distribuce AppArmor
vůbec nepodporují, doinstalovat tedy ani nejdou. Tento email dostáváš, pokud
nějakou z těchto distribucí používáš.

Následujícím způsobem lze použití AppArmoru v Dockeru obejít:

mkdir -p /etc/systemd/system/docker.service.d
cat <<EOF > /etc/systemd/system/docker.service.d/vpsadminos.conf
[Service]
Environment=container=lxc
EOF

systemctl daemon-reload
systemctl restart docker

S pozdravem,

tým vpsFree.cz
END

MAIL[:en] = <<END
Hi <%= @user.login %>,

in case you're using Docker on CentOS/AlmaLinux/Rocky/Fedora, we'd like to warn
you about upgrading it to version 23.0.0. Containers won't start after upgrading.
Docker is trying to use AppArmor, because it detects it in the kernel, even though
the VPS has no AppArmor utilities installed. These distributions do not support
AppArmor at all, so it's not possible to install it. We're sending you this email,
because you're using one of them.

The following commands can be used to work around this issue:

mkdir -p /etc/systemd/system/docker.service.d
cat <<EOF > /etc/systemd/system/docker.service.d/vpsadminos.conf
[Service]
Environment=container=lxc
EOF

systemctl daemon-reload
systemctl restart docker

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
            os_templates: {distribution: %w(almalinux centos fedora rocky)},
          ).where.not(
            os_templates: {distribution: 'centos', version: %w(5 6)},
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
