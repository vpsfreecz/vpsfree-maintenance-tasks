#!/usr/bin/env ruby
# vz to os migration did not configure dns resolvers using osctl, so whenever
# the contents of /etc/resolv.conf is reset, e.g. on reinstall, it will not get
# repopulated.

Dir.chdir('/opt/vpsadmin/api')
require '/opt/vpsadmin/api/lib/vpsadmin'

module TransactionChains
  module Maintenance
    remove_const(:Custom)

    class Custom < TransactionChain
      label 'Fix resolvers'

      def link_chain
        vps_ids = []

        ::TransactionChains::Vps::Migrate::VzToOs.where(
          state: [
            ::TransactionChain.states[:done],
            ::TransactionChain.states[:resolved],
          ],
        ).each do |chain|
          puts "Chain #{chain.id}"

          concern = chain.transaction_chain_concerns.take!

          next if concern.class_name != 'Vps'

          if vps_ids.include?(concern.row_id)
            puts "  duplicate"
            next
          end

          vps_ids << concern.row_id

          begin
            vps = ::Vps.find(concern.row_id)
          rescue ActiveRecord::RecordNotFound
            puts "  VPS not found"
            next
          end

          puts "  VPS #{vps.id}"

          if vps.node.hypervisor_type != 'vpsadminos'
            puts "  not vpsAdminOS"
            next
          end

          lock(vps)

          puts "  fixing"
          append(Transactions::Vps::DnsResolver, args: [
            vps,
            vps.dns_resolver,
            vps.dns_resolver,
          ])
        end

        # fail 'not yet bro'
      end
    end
  end
end

TransactionChains::Maintenance::Custom.fire
