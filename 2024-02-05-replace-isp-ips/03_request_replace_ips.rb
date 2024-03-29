#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Replace IP addresses and email users. The new addresses are routed to individual
# interfaces, but it is up to the user to assign them to the interfaces itself.
#
# Usage:
#   $0 $(pwd)/replacements.json EXECUTE=yes
#
require 'vpsadmin'
require_relative 'common'

SUBJ = {
  cs: "[vpsFree.cz] Změna IP adres VPS",
  en: "[vpsFree.cz] IP address replacement",
}
MAIL = {}
MAIL[:cs] = <<END
Ahoj <%= @user.login %>,

abychom mohli používat svůj vlastní autonomní systém (AS), prosíme tě o výměnu IP
adres u tvých VPS, aby nově byly z adresních rozsahů přidělených našemu spolku.

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

in order for us to be able to use our own autonomous system (AS), we would like
to ask you to change IP addresses of your VPS. The new addresses are from address
ranges assigned to our organization.

<% @vps_replacements.each do |vps, replacements| -%>
VPS <%= vps.id %> <%= vps.hostname %>:

<% replacements.each do |r| -%>
  - IPv<%= r.src_ip.network.ip_version %> <%= r.src_ip.host_ip_addresses.take.ip_addr %> -> <%= r.dst_ip.host_ip_addresses.take.ip_addr %>
<% end -%>

<% end -%>

The new addresses can be added to your VPS in VPS details in vpsAdmin
(form "Interface addresses"), after that you can remove the old addresses.

We'd appreciate if you could make this change as soon as possible. After
May 1 2024, we will automatically replace the remaining IP addresses.

In case you'll need reverse records to be set, please reply to this e-mail
and tell us what domain you'd like to set it to.

Best regards,

vpsFree.cz team
END

include ReplaceIspIps

module TransactionChains
  module Maintenance
    remove_const(:Custom)

    class Custom < TransactionChain
      label 'Replace IPs'

      def link_chain(user, ips, except_networks, except_ips)
        puts "User #{user.login}"
        
        all_replacements, vps_replacements  = get_replacements(user, ips, except_networks, except_ips)

        mail_custom(
          from: 'podpora@vpsfree.cz',
          reply_to: 'podpora@vpsfree.cz',
          user: user,
          role: :admin,
          subject: SUBJ[user.language.code.to_sym],
          text_plain: MAIL[user.language.code.to_sym],
          vars: {user: user, vps_replacements: vps_replacements},
        )

        fail 'set EXECUTE=yes' unless execute_changes?

        all_replacements
      end

      protected
      def get_replacements(user, ips, except_networks, except_ips)
        all_replacements = []
        vps_replacements = {}

        ips.each do |ip|
          vps = ip.network_interface.vps
          vps_replacements[vps] ||= []

          dst_ip = nil

          loop do
            begin
              dst_ip = pick_addr!(
                user: user,
                location: vps.node.location,
                ip_v: ip.network.ip_version,
                role: ip.network.role.to_sym,
                purpose: ip.network.purpose.to_sym,
                except_networks: except_networks,
                except_ips: except_ips
              )

              lock(dst_ip)
            rescue ResourceLocked
              next
            else
              break
            end
          end

          except_ips << dst_ip
          
          replacement = IpReplacement.new(
            vps:,
            netif: ip.network_interface,
            src_ip: ip,
            dst_ip:,
          )

          puts "  #{ip} -> #{dst_ip} (VPS #{vps.id} #{vps.hostname})"

          vps_replacements[vps] << replacement
          all_replacements << replacement
        end

        vps_replacements.each do |vps, replacements|
          begin
            use_chain(NetworkInterface::AddRoute, args: [
              replacements.first.netif, # we assume we have only one netif
              replacements.map(&:dst_ip),
            ])
          rescue VpsAdmin::API::Exceptions::ClusterResourceAllocationError => e
            warn "unable to add route: vps=#{vps.id}, resource allocation error: #{e.message}"
            next
          end
        end

        puts

        [all_replacements, vps_replacements]
      end

      # Return first free and unlocked IP address version `v` from `location`
      #
      # If option `:address_location` is used, the IP addresses is selected only
      # from networks that are available both in `:location` and `:address_location`.
      #
      # @param opts [Hash]
      # @option opts [::User] :user target user
      # @option opts [::Location] :location target location
      # @option opts [4, 6] :ip_v IP version
      # @option opts [:public_access, :private_access] :role network role
      # @option opts [:any, :vps, :export] :purpose network purpose
      # @option opts [Array<::Network>] :except_networks
      # @option opts [Array<::IpAddress>] :except_ips
      def pick_addr!(opts)
        opts[:role] ||= :public_access
        opts[:purpose] ||= :any

        q = ::IpAddress.select('ip_addresses.*')
                .joins(network: :location_networks)
                .joins("LEFT JOIN resource_locks rl ON rl.resource = 'IpAddress' AND rl.row_id = ip_addresses.id")
                .where(
                  networks: {
                    ip_version: opts[:ip_v],
                    role: ::Network.roles[opts[:role]]
                  }
                )
                .where('network_interface_id IS NULL')
                .where('(ip_addresses.user_id = ? OR ip_addresses.user_id IS NULL)', opts[:user].id)
                .where('rl.id IS NULL')
                .where(
                  location_networks: {
                    location_id: opts[:location].id,
                    autopick: true
                  }
                )

        if opts[:purpose] != :any
          q = q.where(
            networks: {
              purpose: [
                ::Network.purposes[:any],
                ::Network.purposes[opts[:purpose]]
              ]
            }
          )
        end

        q = q.where.not(network: opts[:except_networks]) if opts[:except_networks]
        q = q.where.not(id: opts[:except_ips].map(&:id)) if opts[:except_ips]

        q.order('ip_addresses.user_id DESC, location_networks.priority, ip_addresses.id').take!
      end
    end
  end
end

if ARGV.length < 1
  fail "Usage: #{$0} <replacements save file>"
end

# Find networks
networks = get_networks

# Find all users and their IPs
users_ips = get_users_ips(networks)

# Assign replacements
new_ips = []
replacements = {}

users_ips.each do |user, ips|
  replacements[user.id] = TransactionChains::Maintenance::Custom.fire2(args: [
    user,
    ips,
    networks,
    new_ips,
  ])

  # Save replacements in each iteration
  File.write(ARGV[0], JSON.pretty_generate({replacements: replacements}))
end
