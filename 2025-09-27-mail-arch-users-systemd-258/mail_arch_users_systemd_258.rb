#!/run/current-system/sw/bin/vpsadmin-api-ruby
require 'vpsadmin'

SUBJ = {
  cs: "[vpsFree.cz] Upozornění na aktualizaci systemd 258 v Arch Linuxu",
  en: "[vpsFree.cz] Warning about upgrade to systemd 258 in Arch Linux",
}
MAIL = {}
MAIL[:cs] = <<END
Ahoj <%= @user.login %>,

systemd 258 kompletně odstranil podporu pro cgroups v1 a aktualizace
na nodech s cgroups v1 vyžaduje zvláštní pozornost. Tento mail Ti posíláme,
protože máš Arch Linux na nodu s cgroups v1.

Původně se zdálo, že problém nebude -- VPS se systemd 258 nastartuje a připojí
v2 hierarchii. Během aktualizace na verzi 258 se však systemd nečekaně ukončí
a VPS se vypne, protože v /sys/fs/cgroup je připojena hybridní hierarchie
(mix cgroups v1 a v2), což systemd nečeká. Více informací o cgroups viz KB:

  https://kb.vpsfree.cz/navody/vps/cgroups

Existuje několik způsobů, jak aktualizaci na systemd 258 provést:

1) Napsat si na podpora@vpsfree.cz o přesun na node s cgroups v2 a aktualizovat
   až potom. Jedině tak lze plnohodnotně využívat cgroups v2. Rovnou prosím uvěď
   datum a čas, kdy by Ti přesun vyhovoval.

   V Brně aktuálně node s cgroups v2 není k dispozici -- pokud je nezbytně
   potřebuješ, VPS lze přesunout do Prahy se změnou IP adres.

2) Restartovat VPS. Upravili jsme konfiguraci tak, že po restartu se ve VPS
   připojí cgroups v2. Pokud však node používá cgroups v1, tak na v2 nejsou
   k dispozici žádné controllery, tj. nelze nastavovat limity. Pokud to pro tebe
   není překážka, můžeš tuto možnost využít.

3) Před aktualizací spustit příkaz `mount -t cgroup2 cgroup2 /sys/fs/cgroup`,
   potom `pacman -Syu` a nakonec restart systému. Platí zde stejné omezení
   jako u 2).

Současně s odstraněním podpory cgroups v1 se změnilo i něco v souvislosti
s getty na konzoli VPS, ve výchozím stavu se po aktualizaci na konzoli nedá
přihlásit. Příčina prozatím není známa, nicméně následující příkazy to opraví:

mkdir -p /etc/systemd/system/console-getty.service.d

cat <<EOT > /etc/systemd/system/console-getty.service.d/vpsadminos.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --noreset --noclear --issue-file=/etc/issue:/etc/issue.d:/run/issue.d:/usr/lib/issue.d --keep-baud console 115200,57600,38400,9600 ${TERM}
EOT

systemctl daemon-reload
systemctl restart console-getty

Jediný rozdíl v nastavení ExecStart je "console" místo "-".

Co dělat, když už jsi aktualizaci spustil a VPS se vypnul? Nejprve zkus
VPS nastartovat a připojit se na SSH. Pokud SSH funguje, stačí smazat pacmanův
zámek a aktualizaci dokončit:

  rm var/lib/pacman/db.lck
  pacman -Syu

Pokud SSH neběží a zároveň se nejde přihlásit na konzoli, VPS nastartuj
do nouzového režimu [1] a přidej systemd override tak jak je popsán výše,
jen místo /etc použij /mnt/vps/etc. Po restartu VPS najede zase z vlastního
disku a konzole by už měla fungovat, potom z ní dokonči aktualizaci systému.

[1] https://kb.vpsfree.cz/navody/vps/vpsadminos/oprava#nouzovy_rezim

S pozdravem

tým vpsFree.cz
END

MAIL[:en] = <<END
Hi <%= @user.login %>,

systemd 258 has completely removed support for cgroups v1, and updating VPS
on nodes running cgroups v1 requires special attention. You are receiving this
email because you have Arch Linux on a node with cgroups v1.

At first, it seemed this would not be a problem -- a VPS with systemd 258
will boot and mount the v2 hierarchy. However, during the upgrade to version
258, systemd unexpectedly terminates and the VPS shuts down, because a
hybrid hierarchy (a mix of cgroups v1 and v2) is mounted in /sys/fs/cgroup,
which systemd does not expect. More information about cgroups can be found
in the KB:

  https://kb.vpsfree.org/manuals/vps/cgroups

There are several ways to perform the upgrade to systemd 258:

1) Write to support@vpsfree.org to request migration to a node with cgroups v2
   and update afterwards. Only this way can you fully benefit from cgroups v2.
   Please also include the date and time that would be convenient for the
   migration.

   In Brno, a node with cgroups v2 is currently not available -- if you
   need cgroups v2 with all controllers, the VPS can be migrated to Prague
   with a change of IP addresses.

2) Restart the VPS. We have adjusted the configuration so that after a
   restart, cgroups v2 will be mounted inside the VPS. However, if the node
   uses cgroups v1, no controllers are available on v2, meaning limits cannot
   be set. If this is not an obstacle for you, you can use this option.

3) Before updating, run the command `mount -t cgroup2 cgroup2 /sys/fs/cgroup`,
   then `pacman -Syu` and finally reboot the system. The same limitation as
   in 2) applies here.

Along with the removal of cgroups v1 support, something also changed regarding
getty on the VPS console: after the update, logging in on the console is not
possible by default. The cause is not yet known, but the following commands
fix it:

mkdir -p /etc/systemd/system/console-getty.service.d

cat <<EOT > /etc/systemd/system/console-getty.service.d/vpsadminos.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --noreset --noclear --issue-file=/etc/issue:/etc/issue.d:/run/issue.d:/usr/lib/issue.d --keep-baud console 115200,57600,38400,9600 ${TERM}
EOT

systemctl daemon-reload
systemctl restart console-getty

The only difference in the ExecStart setting is "console" instead of "-".

What to do if you already started the update and the VPS shut down? First,
try starting the VPS and connecting via SSH. If SSH works, simply remove
pacman’s lock and finish the update:

  rm var/lib/pacman/db.lck
  pacman -Syu

If SSH does not work and you also cannot log in to the console, start the VPS
in rescue mode [1] and add the systemd override as described above, just use
/mnt/vps/etc instead of /etc. After reboot, the VPS will boot again from its
own disk and the console should work; then finish the system update from
there.

[1] https://kb.vpsfree.org/manuals/vps/vpsadminos/recovery#rescue_mode

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
          vpses = user.vpses.joins(:os_template, node: :node_current_status).where(
            vpses: {object_state: [::Vps.object_states[:active]]},
            os_templates: {distribution: %w(arch)},
            node_current_statuses: {cgroup_version: 1}
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
