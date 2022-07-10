#!/run/current-system/sw/bin/vpsadmin-api-ruby
require 'vpsadmin'

SUBJ = {
  cs: "[vpsFree.cz] Doporučená změna v konfiguraci systému",
  en: "[vpsFree.cz] Recommended change in system configuration",
}
MAIL = {}
MAIL[:cs] = <<END
Ahoj <%= @user.login %>,

chtěli bychom Tě upozornit na doporučenou změnu v konfiguračním souboru NixOS
pro naše prostředí.

Při aktivaci nové verze systému může dojít k restartu služby
networking-setup.service, což znamená, že VPS dočasně přijde o konektivitu.
Pokud zároveň používáš NAS, může se aktivace systému zaseknout na přístupu
k nedostupnému NFS mountu.

Abychom zabránili restartu networking-setup.service, nastavíme

  systemd.services.networking-setup.restartIfChanged = false;

Tato změna je součástí nově vytvořených VPS, u existujících VPS doporučujeme
konfiguraci upravit. Ve výchozím stavu ji nalezneš v /etc/nixos/vpsadminos.nix.
Potřebná změna viz:

  https://github.com/vpsfreecz/vpsadminos/commit/4e4739691b8e1f91091375db82e8144e194daaa4

Kompletní soubor stáhneš odsud:

  https://github.com/vpsfreecz/vpsadminos/raw/staging/os/lib/nixos-container/vpsadminos.nix

S pozdravem,

tým vpsFree.cz
END

MAIL[:en] = <<END
Hi <%= @user.login %>,

we would like to inform you about a recommended change in the NixOS configuration
file for our environment.

When the system configuration is being switched, service networking-setup.service
can be restarted. This means that for a moment, the VPS will lose its network
connectivity. If you're also using NAS, accessing the unavailable NFS mount can
result in the configuration switch to hang.

To prevent restarts of networking-setup.service, set:

  systemd.services.networking-setup.restartIfChanged = false;

This change is included in newly created VPSes, we recommend to apply it also
in your configuration, which is by default in /etc/nixos/vpsadminos.nix.
The required change can be seen here:

  https://github.com/vpsfreecz/vpsadminos/commit/4e4739691b8e1f91091375db82e8144e194daaa4

The whole file can be downloaded from here:

  https://github.com/vpsfreecz/vpsadminos/raw/staging/os/lib/nixos-container/vpsadminos.nix

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
            os_templates: {distribution: 'nixos'},
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
