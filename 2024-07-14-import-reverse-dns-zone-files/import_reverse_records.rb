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
        dns_server_zone_records, output_records = create_records(input_records)

        # Save output
        File.write(output_json_file, JSON.pretty_generate({ records: output_records }))

        # Fire transactions per server-zone
        configure_servers(dns_server_zone_records)
      end

      protected

      def create_records(records)
        dns_server_zone_records = {}
        output_records = []

        records.each do |r|
          host_ip_address = ::HostIpAddress.find_by!(ip_addr: r['ip'])

          output_records << {
            ip: r['ip'],
            ptr: r['ptr'],
            imported: !host_ip_address.current_owner.nil?
          }

          next if host_ip_address.current_owner.nil?

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

        [dns_server_zone_records, output_records]
      end

      def configure_servers(dns_server_zone_records)
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