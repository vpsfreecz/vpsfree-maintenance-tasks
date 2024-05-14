#!/run/current-system/sw/bin/vpsadmin-api-ruby
#
# Automatically carry out remaining IP address replacements. Add new addresses
# and remove old ones.
#
# Usage:
#   $0 $(pwd)/replacements.json EXECUTE=yes
#
require 'vpsadmin'
require_relative 'common'

SUBJ = {
  cs: "[vpsFree.cz] Oznámení o dokončení výměny IP adres VPS",
  en: "[vpsFree.cz] IP address replacement completed",
}
MAIL = {}
MAIL[:cs] = <<END
Ahoj <%= @user.login %>,

podle plánu byla provedena výměna zbylých IP adres.

<% @vps_done.each do |vps, replacements| -%>
VPS <%= vps.id %> <%= vps.hostname %>:

<% replacements.each do |r| -%>
  - IPv<%= r.src_ip.network.ip_version %> <%= r.src_ip.host_ip_addresses.take.ip_addr %> -> <%= r.dst_ip.host_ip_addresses.take.ip_addr %>
<% end -%>

<% end -%>

Nové adresy byly přidány na síťové rozhraní a původní adresy byly odebrány.

V případě potřeby nastavení reverzních záznamů prosím odpověz na tento e-mail
s informací, pro jakou IP adresu a doménu chceš záznam nastavit. Obratem ti jej
nastavíme.

Více informací a odpovědi na časté dotazy najdeš ve znalostní bázi:

  https://kb.vpsfree.cz/informace/vymena_ip

S pozdravem,

tým vpsFree.cz
END

MAIL[:en] = <<END
Hi <%= @user.login %>,

remaining IP addresses were replaced as planned.

<% @vps_done.each do |vps, replacements| -%>
VPS <%= vps.id %> <%= vps.hostname %>:

<% replacements.each do |r| -%>
  - IPv<%= r.src_ip.network.ip_version %> <%= r.src_ip.host_ip_addresses.take.ip_addr %> -> <%= r.dst_ip.host_ip_addresses.take.ip_addr %>
<% end -%>

<% end -%>

New addresses were added to the network interface and old addresses were
removed.

In case you'll need reverse records to be set, please reply to this e-mail
and tell us what domain you'd like to set it to.

More information and answers to frequently asked questions can be found
in knowledge base:

  https://kb.vpsfree.org/information/ip_replacement

Best regards,

vpsFree.cz team
END

module TransactionChains
  module Maintenance
    remove_const(:Custom)

    class Custom < TransactionChain
      label 'Replace IPs'
      allow_empty

      include ReplaceIspIps

      def link_chain(user, replacements)
        user_active = %w[active suspended].include?(user.object_state)
        vps_replacements = {}

        replacements.each do |r|
          vps_replacements[r.vps] ||= []
          vps_replacements[r.vps] << r

          concerns(:affect, [r.vps.class.name, r.vps.id])
        end

        return if vps_replacements.empty?

        puts "User #{user.id} #{user.login} #{user.object_state}"

        vps_done = {}

        vps_replacements.each do |vps, replacements|
          puts "  VPS #{vps.id} #{vps.hostname} #{vps.object_state}"

          vps_active = %w[active suspended].include?(vps.object_state)

          replacements.each do |r|
            if r.dst_ip.network_interface.nil?
              warn "    missing route #{r.dst_ip} on VPS #{vps.id}"
            end
          end

          add_hosts = replacements.select do |r|
            r.dst_ip.network_interface \
              && r.dst_ip.network_interface.vps_id == vps.id \
              && !r.dst_ip.host_ip_addresses.take!.assigned?
          end

          if add_hosts.any? && vps_active
            add_hosts.each do |r|
              puts "    add host address #{r.dst_ip.host_ip_addresses.take!.ip_addr}"
            end

            use_chain(NetworkInterface::AddHostIp, args: [
              add_hosts.first.netif, # we assume we have only one netif
              add_hosts.map { |r| r.dst_ip.host_ip_addresses.take! },
            ])
          end

          del_routes = replacements.select do |r|
            r.src_ip.network_interface && r.src_ip.network_interface.vps_id == vps.id
          end

          if del_routes.any?
            del_routes.each do |r|
              puts "    del route #{r.src_ip}"
            end

            use_chain(NetworkInterface::DelRoute, args: [
              del_routes.first.netif, # we assume we have only one netif
              del_routes.map(&:src_ip),
            ])
          end

          if (add_hosts.any? || del_routes.any?) && vps_active
            vps_done[vps] = (add_hosts + del_routes).uniq { |r| r.src_ip.id }
          end
        end

        if vps_done.any? && user_active
          puts "  -> mail"
          mail_custom(
            from: 'podpora@vpsfree.cz',
            reply_to: 'podpora@vpsfree.cz',
            user: user,
            role: :admin,
            subject: SUBJ[user.language.code.to_sym],
            text_plain: MAIL[user.language.code.to_sym],
            vars: { user:, vps_done: },
          )
        end

        puts

        fail 'set EXECUTE=yes' unless execute_changes?
      end
    end
  end
end

def load_replacements(save_file)
    json = JSON.parse(File.read(save_file), symbolize_names: true)

    json[:replacements].to_h do |user_id, tmp|
      # There is a bug in 03_request_replace_ips.rb which saves the return
      # value of a transaction chain, which is [chain, value]. So we skip
      # the chain identifier and access the value.
      _, replacements = tmp

      [
        ::User.find(user_id.to_s.to_i),
        replacements.map do |v|
          begin
            vps = ::Vps.find(v[:vps])
          rescue ActiveRecord::RecordNotFound
            next
          end

          IpReplacement.new(
            vps:,
            netif: ::NetworkInterface.find(v[:netif]),
            src_ip: ::IpAddress.find(v[:src_ip][:id]),
            dst_ip: ::IpAddress.find(v[:dst_ip][:id]),
          )
        end.compact
      ]
    end
  end

if ARGV.length < 1
  fail "Usage: #{$0} <replacements save file>"
end

EXCLUDE_USER_IDS = [
  2,
  357
]

users_replacements = load_replacements(ARGV[0])
i = 0

users_replacements.each do |user, replacements|
  if EXCLUDE_USER_IDS.include?(user.id)
    puts "Skip user #{user.id} #{user.login}"
    puts
    next
  end

  TransactionChains::Maintenance::Custom.fire(user, replacements)

  i += 1

  if i >= 20
    puts
    puts 'Press enter to continue'
    STDIN.readline
    i = 0
  end
end
