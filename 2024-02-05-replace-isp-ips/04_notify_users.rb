#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Remind users about the IP replacement request. If the original IP is no longer
# assigned to an interface, we consider the change fullfilled.
#
# Usage:
#   $0 $(pwd)/replacements.json EXECUTE=yes
#
require 'vpsadmin'
require_relative 'common'

SUBJ = {
  cs: "[vpsFree.cz] Připomenutí změny IP adres VPS",
  en: "[vpsFree.cz] IP address replacement reminder",
}
MAIL = {}
MAIL[:cs] = <<END
Ahoj <%= @user.login %>,

chtěli bychom ti připomenout výměnu IP adres u tvých VPS, aby nově byly
z adresních rozsahů přidělených našemu spolku.

<% @vps_replacements.each do |vps, replacements| -%>
VPS <%= vps.id %> <%= vps.hostname %>:

<% replacements.each do |r| -%>
  - IPv<%= r.src_ip.network.ip_version %> <%= r.src_ip.host_ip_addresses.take.ip_addr %> -> <%= r.dst_ip.host_ip_addresses.take.ip_addr %>
<% end -%>

<% end -%>

Nové adresy stačí v detailu VPS ve vpsAdminu přídat na síťové rozhraní
(formulář „Interface addresses“) a původní adresy můžeš z VPS odebrat.

Budeme rádi, když změnu IP adres provedeš co nejdříve. Po 1. květnu 2024 zbylé
adresy vyměníme automaticky.

V případě potřeby nastavení reverzních záznamů prosím odpověz na tento e-mail
s informací, pro jakou IP adresu a doménu chceš záznam nastavit. Obratem ti jej
nastavíme.

S pozdravem,

tým vpsFree.cz
END

MAIL[:en] = <<END
Hi <%= @user.login %>,

we would like to remind you to change your IP addresses, so that the new addresses
would be from address ranges assigned to our organization.

<% @vps_replacements.each do |vps, replacements| -%>
VPS <%= vps.id %> <%= vps.hostname %>:

<% replacements.each do |r| -%>
  - IPv<%= r.src_ip.network.ip_version %> <%= r.src_ip.host_ip_addresses.take.ip_addr %> -> <%= r.dst_ip.host_ip_addresses.take.ip_addr %>
<% end -%>

<% end -%>

The new addresses can be added to your VPS in VPS details in vpsAdmin
(form "Interface addresses"), after that you can remove the old addresses.

We'd appreciate if you could plan this change as soon as possible. After May 1
2024, we will automatically replace the remaining IP addresses.

In case you'll need reverse records to be set, please reply to this e-mail
and tell us what domain you'd like to set it to.

Best regards,

vpsFree.cz team
END

module TransactionChains
  module Maintenance
    remove_const(:Custom)

    class Custom < TransactionChain
      label 'Notify users'

      include ReplaceIspIps

      def link_chain(save_file)
        users_replacements = load_replacements(save_file)

        users_replacements.each do |user, replacements|
          vps_replacements = {}

          replacements.each do |r|
            # If the original address is no longer on the interface, consider
            # the exchange completed.
            next if r.src_ip.network_interface.nil?

            vps_replacements[r.vps] ||= []
            vps_replacements[r.vps] << r
          end

          next if vps_replacements.empty?

          puts "User #{user.id} #{user.login}"

          mail_custom(
            from: 'podpora@vpsfree.cz',
            reply_to: 'podpora@vpsfree.cz',
            user: user,
            role: :admin,
            subject: SUBJ[user.language.code.to_sym],
            text_plain: MAIL[user.language.code.to_sym],
            vars: {user: user, vps_replacements: vps_replacements},
          )
        end

        fail 'set EXECUTE=yes' unless execute_changes?
      end

      protected
      def load_replacements(save_file)
        json = JSON.parse(File.read(save_file), symbolize_names: true)

        Hash[json[:replacements].map do |user_id, tmp|
          # There is a bug in 03_request_replace_ips.rb which saves the return
          # value of a transaction chain, which is [chain, value]. So we skip
          # the chain identifier and access the value.
          _, replacements = tmp

          [
            ::User.find(user_id),
            replacements.map do |v|
              IpReplacement.new(
                vps: ::Vps.find(v[:vps]),
                netif: ::NetworkInterface.find(v[:netif]),
                src_ip: ::IpAddress.find(v[:src_ip][:id]),
                dst_ip: ::IpAddress.find(v[:dst_ip][:id]),
              )
            end
          ]
        end]
      end
    end
  end
end

if ARGV.length < 1
  fail "Usage: #{$0} <replacements save file>"
end

TransactionChains::Maintenance::Custom.fire2(args: [ARGV[0]])
