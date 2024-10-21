#!/run/current-system/sw/bin/vpsadmin-api-ruby
require 'vpsadmin'

SUBJ = {
  cs: "[vpsFree.cz] Letošní novinky ve vpsAdminu a našem prostředí",
  en: "[vpsFree.cz] This year's updates in vpsAdmin and our environment",
}
MAIL = {}
MAIL[:cs] = <<END
Ahoj,

rádi bychom tě seznámili s novinkami na našem sdíleném prostředí, které jsme
tento rok zaváděli. Všechny oznámení jsou na Discourse
(https://discourse.vpsfree.cz/t/vitej-na-vpsfree-cz-discourse/17),
nicméně pro lepší viditelnost budeme jednou za čas posílat zprávy
na administrátorský kontakt ve vpsAdminu.

Provozujeme autoritativní DNS servery, které můžeš použít pro hostování záznamů
svých domén (registrace prozatím nezprostředkováváme):

 https://discourse.vpsfree.cz/t/primarni-dns-servery-primary-dns-servers/258

Když si ve VPS spustíš svůj primární server, tak naše servery mohou fungovat
jako sekundární:

 https://discourse.vpsfree.cz/t/reverzni-zaznamy-a-sekundarni-dns-servery-reverse-records-and-secondary-dns-servers/250

Integrována je taktéž správa reverzních záznamů, tj. už není potřeba o nastavení
psát na podporu.

vpsAdmin a status.vpsf.cz dále poskytují metriky pro monitorovací systém Prometheus.
Na titulní stránce vpsAdminu si můžeš rozkliknout heatmapy zatížení nodů v reálném
čase (CPU, disk I/O):

 https://discourse.vpsfree.cz/t/metriky-pro-prometheus-heatmapy-zatizeni-nodu-metrics-for-prometheus-heatmaps-with-node-load/254

Zlepšili jsme zabezpečení účtů ve vpsAdminu, zjednodušili přepínání mezi vícero účty,
posíláme emaily o přihlášeních z nových zařízení, aj.:

 https://discourse.vpsfree.cz/t/prihlasovani-pod-drobnohledem-login-under-scrutiny/233

Mezi vpsAdminem, KB a Discourse funguje single sign-on, můžeš si nastavit délku
přihlášení či omezovat API tokeny na konkrétní akce:

 https://discourse.vpsfree.cz/t/single-sign-on-ve-vpsadminu-vpsadmin-single-sign-on/111

Taky jsme se na nodech zbavili LXCFS a potřebné soubory virtualizujeme přímo
v kernelu:

 https://discourse.vpsfree.cz/t/nahrazeni-lxcfs-virtualizaci-v-kernelu-replacing-lxcfs-with-in-kernel-virtualization/155

S pozdravem

tým vpsFree.cz
END

MAIL[:en] = <<END
Hi,

We would like to introduce you to some updates in our shared environment that
we have implemented this year. All announcements are available on Discourse
(https://discourse.vpsfree.cz/t/welcome-to-vpsfree-cz-discourse/5), but for
better visibility, we will occasionally send messages to the admin contact
in vpsAdmin.

We operate authoritative DNS servers that you can use to host records for your
domains (we currently do not offer domain registration services):

 https://discourse.vpsfree.cz/t/primarni-dns-servery-primary-dns-servers/258#english-5

If you run your own primary server in your VPS, our servers can function as
secondaries:

 https://discourse.vpsfree.cz/t/reverzni-zaznamy-a-sekundarni-dns-servery-reverse-records-and-secondary-dns-servers/250#english-3

We have also integrated the management of reverse records, so there is no longer
a need to contact support to set them up.

vpsAdmin and status.vpsf.cz now provide metrics for the Prometheus monitoring system.
On the vpsAdmin homepage, you can view real-time heatmaps of node loads (CPU, disk I/O):

 https://discourse.vpsfree.cz/t/metriky-pro-prometheus-heatmapy-zatizeni-nodu-metrics-for-prometheus-heatmaps-with-node-load/254#english-3

We have improved account security in vpsAdmin, simplified switching between multiple
accounts, and now send emails about logins from new devices, among other things:

 https://discourse.vpsfree.cz/t/prihlasovani-pod-drobnohledem-login-under-scrutiny/233#english-1

Single sign-on works between vpsAdmin, the Knowledge Base (KB), and Discourse. You can
configure session length or limit API tokens to specific actions:

 https://discourse.vpsfree.cz/t/single-sign-on-ve-vpsadminu-vpsadmin-single-sign-on/111#english-7

We also removed LXCFS from the nodes, and now virtualize the necessary files directly
in the kernel:

 https://discourse.vpsfree.cz/t/nahrazeni-lxcfs-virtualizaci-v-kernelu-replacing-lxcfs-with-in-kernel-virtualization/155#english-1

Best regards,

vpsFree.cz team
END

module TransactionChains
  module Maintenance
    remove_const(:Custom)

    class Custom < TransactionChain
      label 'Notice'

      def link_chain
        ::User.joins(:user_account).where(
          object_state: 'active',
          mailer_enabled: true
        ).where.not(user_accounts: { paid_until: nil }).each do |user|
          mail_custom(
            from: 'podpora@vpsfree.cz',
            reply_to: 'podpora@vpsfree.cz',
            user:,
            role: :admin,
            subject: SUBJ[user.language.code.to_sym],
            text_plain: MAIL[user.language.code.to_sym],
            vars: { user: }
          )
        end

        fail 'not yet bro'
      end
    end
  end
end

TransactionChains::Maintenance::Custom.fire
