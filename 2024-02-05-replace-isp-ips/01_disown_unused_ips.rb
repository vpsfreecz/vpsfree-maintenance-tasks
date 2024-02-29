#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Disown IP addresses that are not used in any VPS
#
# Usage:
#   $0 $(pwd)/disowned-ips.json EXECUTE=yes
#
require 'vpsadmin'
require_relative 'common'

module TransactionChains
  module Maintenance
    remove_const(:Custom)

    class Custom < TransactionChain
      label 'Disown unused IPs'
      allow_empty

      include ReplaceIspIps

      def link_chain(save_file)
        networks = get_networks
        disowned_ips = []

        networks.each do |net|
          net.ip_addresses.each do |ip|
            next if ip.current_owner.nil?

            # The IP is owned, but not assigned -- simply remove it from the user
            if ip.user_id && ip.network_interface_id.nil?
              puts "IP #{ip} not assigned, disowning"
              
              disowned_ips << {
                ip_id: ip.id,
                ip_addr: ip.addr,
                user_id: ip.user_id,
                charged_environment_id: ip.charged_environment_id,
              }

              begin
                use_chain(Ip::Update, args: [ip, {user: nil}])
              rescue ActiveRecord::RecordNotFound => e
                warn "  db consistency error: #{e.message}"
                next
              end
            end
          end
        end

        File.write(save_file, JSON.pretty_generate({disowned_ips: disowned_ips}))

        fail 'set EXECUTE=yes' unless execute_changes?
      end
    end
  end
end

if ARGV.length < 1
  fail "Usage: #{$0} <ips save file>"
end

TransactionChains::Maintenance::Custom.fire2(args: [ARGV[0]])
