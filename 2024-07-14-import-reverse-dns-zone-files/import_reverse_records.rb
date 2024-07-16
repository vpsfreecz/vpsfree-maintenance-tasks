#!/run/current-system/sw/bin/vpsadmin-api-ruby
require 'vpsadmin'

module TransactionChains
  module Maintenance
    remove_const(:Custom)

    class Custom < TransactionChain
      label 'Import reverse records'

      def link_chain(input_json_file, output_json_file)
        input_records = JSON.parse(File.read(input_json_file))['records']

        # Create records
        dns_server_zone_records, created_host_ips, output_records = create_records(input_records)

        # Save output
        File.write(output_json_file, JSON.pretty_generate({ records: output_records }))

        # Fire transactions per server-zone
        configure_servers(dns_server_zone_records, created_host_ips)
      end

      protected

      def create_records(records)
        dns_server_zone_records = {}
        created_host_ips = []
        output_records = []

        records.each do |r|
          host_ip_address, missing_host = get_host_ip_address(r)

          imported =
            if host_ip_address.nil?
              false
            else
              !host_ip_address.current_owner.nil?
            end

          output_records << {
            ip: r['ip'],
            ptr: r['ptr'],
            imported:,
            created: missing_host
          }

          next unless imported

          created_host_ips << host_ip_address if missing_host

          ptr_content = r['ptr']

          lock(host_ip_address)

          dns_zone = host_ip_address.ip_address.reverse_dns_zone

          concerns(
            :affect,
            [host_ip_address.class.name, host_ip_address.id],
            [dns_zone.class.name, dns_zone.id]
          )

          record = host_ip_address.reverse_dns_record

          if record
            record.content = ptr_content
            created = false
          else
            if /\A(.+)\.#{Regexp.escape(dns_zone.name)}\Z/ !~ host_ip_address.reverse_record_domain
              raise "Unable to find reverse record name for #{host_ip_address} in zone #{dns_zone.name}"
            end

            record_name = Regexp.last_match(1)

            record = ::DnsRecord.create!(
              dns_zone:,
              name: record_name,
              record_type: 'PTR',
              content: ptr_content,
              host_ip_address:
            )
            host_ip_address.reverse_dns_record = record
            created = true
          end

          log = ::DnsRecordLog.create!(
            dns_zone:,
            change_type: created ? 'create_record' : 'update_record',
            name: record.name,
            record_type: 'PTR',
            content: ptr_content
          )

          dns_zone.dns_server_zones.each do |dns_server_zone|
            dns_server_zone_records[dns_server_zone] ||= []
            dns_server_zone_records[dns_server_zone] << {
              host_ip_address:,
              record:,
              log:,
              created:
            }
          end
        end

        [dns_server_zone_records, created_host_ips, output_records]
      end

      def get_host_ip_address(r)
        host_ip = ::HostIpAddress.find_by(ip_addr: r['ip'])
        return [host_ip, false] if host_ip

        addr = IPAddress.parse(r['ip'])
        ip_v = addr.ipv4? ? 4 : 6

        network = ::Network.where(ip_version: ip_v).detect { |n| n.include?(r['ip']) }

        if network.nil?
          fail "Network for #{r['ip']} not found"
        end

        ip = network.ip_addresses.detect { |ip| ip.include?(addr) }
        return [nil, false] if ip.current_owner.nil?

        host_ip = ::HostIpAddress.create!(
          ip_address: ip,
          ip_addr: addr.to_s,
          order: nil,
          auto_add: false,
          user_created: true
        )

        [host_ip, true]
      end

      def configure_servers(dns_server_zone_records, created_host_ips)
        dns_server_zone_records.each do |dns_server_zone, records|
          create_records = []
          update_records = []

          records.each do |r|
            if r[:created]
              create_records << r
            else
              update_records << r
            end
          end

          if create_records.any?
            append_t(
              Transactions::DnsServerZone::CreateRecords,
              args: [dns_server_zone, create_records.map { |r| r[:record] }]
            )
          end

          if update_records.any?
            append_t(
              Transactions::DnsServerZone::UpdateRecords,
              args: [dns_server_zone, update_records.map { |r| r[:record] }]
            )
          end
        end

        append_t(Transactions::Utils::NoOp, args: find_node_id) do |t|
          created_host_ips.each do |host_ip|
            t.just_create(host_ip)
          end

          dns_server_zone_records.each_value do |records|
            records.each do |r|
              if r[:created]
                t.just_create(r[:record])
                t.edit_before(r[:host_ip_address], reverse_dns_record_id: nil)
              else
                t.edit_before(r[:record], content: r[:record].content_was)
              end

              t.just_create(r[:log])

              r[:record].save!
              r[:host_ip_address].save!
            end
          end
        end
      end
    end
  end
end

if ARGV.length != 2
  fail "Usage: #{$0} <input json file> <output json file>"
end

TransactionChains::Maintenance::Custom.fire(ARGV[0], ARGV[1])