#!/run/current-system/sw/bin/vpsadmin-api-ruby
require 'vpsadmin'

SUBJ = {
  cs: "[vpsFree.cz] Změna veřejných IP adres NATu",
  en: "[vpsFree.cz] NAT public address replacement",
}
MAIL = {}
MAIL[:cs] = <<END
Ahoj <%= @user.login %>,

ve VPS používáš privátní IPv4 adresu a pokud se privátní adresa nachází
na síťovém rozhraní jako první, nebo VPS veřejnou IPv4 adresu vůbec nemá,
do Internetu přistupuješ přes NAT na našich routerech. V noci z 31.5
na 1.6.2024 proběhne změna veřejných IPv4 adres NATu.

Tato změna se tě týká jen pokud máš IP adresy NATu povoleny někde ve firewallu
v sítích, kam se z VPS připojuješ. Jinak nic řešit nemusíš a tuto zprávu můžeš
ignorovat.

Původní IP adresy:

  83.167.228.129
  83.167.228.130

Nové IP adresy:

  37.205.15.253
  37.205.15.254

Následující VPS používají privátní IP adresy:

<% @vpses.each do |vps| -%>
  <%= vps.id %> <%= vps.hostname %>
<% end -%>

S pozdravem,

tým vpsFree.cz
END

MAIL[:en] = <<END
Hi <%= @user.login %>,

we're sending you this email, because your VPS is using private IPv4 addresses.
When the private address is the first on the network interface, or when the VPS
doesn't have any public IPv4 address at all, you're accessing the Internet through
NAT on our routers. During the night from 31.5. to 1.6.2024, we will be replacing
the NAT's public IPv4 addresses.

This change is relevant to you only when you've explicitly configured the NAT's
IP addresses in a firewall somewhere in networks you're connecting to. No action
is required from you otherwise and you can disregard this message.

Original IP addresses are:

  83.167.228.129
  83.167.228.130

New IP addresses will be:

  37.205.15.253
  37.205.15.254

The following VPS are using private IP addresses:

<% @vpses.each do |vps| -%>
  <%= vps.id %> <%= vps.hostname %>
<% end -%>

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
          vpses = user.vpses.joins(:node).where(
            object_state: 'active',
            nodes: {location_id: [3, 5, 7]}
          )
          next if vpses.empty?

          vpses_with_private_ips = []

          vpses.each do |vps|
            vps.network_interfaces.each do |netif|
              first_ip = netif.ip_addresses
                .joins(:host_ip_addresses)
                .where.not(host_ip_addresses: { order: nil })
                .order('host_ip_addresses.order')
                .take

              if first_ip && first_ip.network.role == 'private_access'
                vpses_with_private_ips << vps
              end
            end
          end

          vpses_with_private_ips.uniq!

          next if vpses_with_private_ips.empty?

          puts "Mailing user #{user.id} #{user.login}"
          vpses_with_private_ips.each do |vps|
            puts "  VPS #{vps.id} #{vps.hostname} #{vps.node.domain_name}"
          end

          mail_custom(
            from: 'podpora@vpsfree.cz',
            reply_to: 'podpora@vpsfree.cz',
            user: user,
            role: :admin,
            subject: SUBJ[user.language.code.to_sym],
            text_plain: MAIL[user.language.code.to_sym],
            vars: {user: user, vpses: vpses_with_private_ips},
          )
        end

        fail 'not yet bro'
      end
    end
  end
end

TransactionChains::Maintenance::Custom.fire
