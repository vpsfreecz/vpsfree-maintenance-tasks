#!/run/current-system/sw/bin/vpsadmin-api-ruby
require 'vpsadmin'

SUBJ = {
  cs: "[vpsFree.cz] Připravujeme podporu pro NixOS impermanence",
  en: "[vpsFree.cz] Announcing upcoming support for NixOS Impermanence",
}
MAIL = {}
MAIL[:cs] = <<END
Ahoj <%= @user.login %>,

pracujeme na podpoře pro modul NixOS Impermanence ve VPS. Pokud máš zájem
to používat, budeme rádi za zpětnou vazbu, než to nasadíme v produkci.

S impermanence modulem se kořenový souborový systém nachází v dočasném ZFS
datasetu, který je vymazán při každém startu VPS. Můžeš si tak zvolit, které
adresáře/soubory chceš mít perzistentní a zbytek se při restartu smaže.

Jak impermanence ve VPS nastavit je popsáno v KB:

  https://kb.vpsfree.cz/navody/distribuce/nixos/impermanence

Aktuálně to funguje jen na stagingu (node1.stg). Pokud to půjde dobře,
brzy to bude k dispozici i v produkci.

Případné poznatky a připomínky můžete poslat na Discourse:

  https://discourse.vpsfree.cz/t/nixos-impermanence/263

Můžeš taky odpovědět na tento email.

S pozdravem

tým vpsFree.cz
END

MAIL[:en] = <<END
Hi <%= @user.login %>,

we're working on support for NixOS Impermanence module on our VPS. If you'd like
to use it, we'd appreaciate feedback before we deploy it to production.

When impermanence is enabled, your root file system will be based in a temporary
ZFS dataset that is reset on every VPS start. You can thus choose which data
is persistent and only those will remain on disk. There is an article in KB
that describes how to enable impermanence:

  https://kb.vpsfree.org/manuals/distributions/nixos/impermanence

Note that currently it works only on Staging (node1.stg). If it goes well, it
will be available in production soon.

Feedback can be reported and discussed on Discourse:

  https://discourse.vpsfree.cz/t/nixos-impermanence/263

You can also reply to this email.

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
