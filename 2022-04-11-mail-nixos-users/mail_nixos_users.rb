#!/run/current-system/sw/bin/vpsadmin-api-ruby
require 'vpsadmin'

SUBJ = {
  cs: "[vpsFree.cz] Upozornění na změnu v nixos-unstable",
  en: "[vpsFree.cz] Breaking change in nixos-unstable",
}
MAIL = {}
MAIL[:cs] = <<END
Ahoj <%= @user.login %>,

chtěli bychom Tě upozornit na změnu v NixOS unstable, která způsobí, že VPS
nenastartuje. Jedná se o tento commit v nixpkgs:

https://github.com/NixOS/nixpkgs/commit/a3e0698bf6fd676d96b89bdb4cd54c73ea502746

Volba boot.systemdExecutable nyní vyžaduje absolutní cestu k systemd a protože
v konfiguračním souboru pro naše prostředí je cesta relativní, systemd při
startu VPS není nalezen. Řešení je tedy aktualizovat konfigurační soubor, který
dodáváme v šabloně v /etc/nixos/vpsadminos.nix.

Potřebná změna:

https://github.com/vpsfreecz/vpsadminos/commit/e8101cc63938585f5cf7b692d8dab234267b957f

Kompletní soubor stáhneš odsud:

https://github.com/vpsfreecz/vpsadminos/raw/staging/os/lib/nixos-container/vpsadminos.nix

Tato změna se časem dostane i do nového stabilního vydání, doporučujeme
konfiguraci aktualizovat už teď. Aktuální vpsadminos.nix funguje i na NixOS 21.11.

Pokud se přeci jen dostaneš do situace, kdy VPS nenastartuje, pomocí start menu
v konzoli VPS ve vpsAdminu můžeš nastartovat starší generaci systému, viz

https://kb.vpsfree.cz/navody/vps/start_menu

S pozdravem,

tým vpsFree.cz
END

MAIL[:en] = <<END
Hi <%= @user.login %>,

we would like to inform you about a breaking change in NixOS unstable, which
will result in VPS not starting. The change has been introduced by the following
commit in nixpkgs:

https://github.com/NixOS/nixpkgs/commit/a3e0698bf6fd676d96b89bdb4cd54c73ea502746

Option boot.systemdExecutable now requires absolute path to the systemd
executable, but because the configuration file for NixOS in our environment
uses relative path, the systemd executable will not be found when the VPS
is starting. The solution is to update the configuration file, which the VPS
template installs at /etc/nixos/vpsadminos.nix.

The required change can be seen here:

https://github.com/vpsfreecz/vpsadminos/commit/e8101cc63938585f5cf7b692d8dab234267b957f

The whole file can be downloaded from here:

https://github.com/vpsfreecz/vpsadminos/raw/staging/os/lib/nixos-container/vpsadminos.nix

Since this change will in time land in the next NixOS stable release, we
recommend to update the configuration at your earliest convenience.
The up-to-date vpsadminos.nix file will work also on NixOS 21.11.

Should you still encounter this issue and the VPS is not starting, you can use
the start menu in remote VPS console in vpsAdmin to start the system from
an older generation, see:

https://kb.vpsfree.org/manuals/vps/start_menu

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
