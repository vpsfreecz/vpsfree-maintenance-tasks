#!/usr/bin/env ruby
# Perform necessary steps when OS on a node has been reinstalled.
#
#  - Generate VPS configs
#  - Save new public host SSH keys
#  - Update .shh/known_hosts on active nodes in the cluster
#  - Deploy private key
#
# Usage: ./register_reinstalled_node.rb <NODE_ID>
#

Dir.chdir('/opt/vpsadmin-api')
require '/opt/vpsadmin-api/lib/vpsadmin'

unless ARGV[0]
  puts "Usage: ./register_reinstalled_node.rb <NODE_ID>"
  exit(false)
end

module TransactionChains
  module Maintenance
    remove_const(:Custom)

    class Custom < TransactionChain
      label 'Install'

      def link_chain
        node = ::Node.find(ARGV[0].to_i)

        # Create configs
        if node.role == 'node'
          ::VpsConfig.all.each do |cfg|
            append(Transactions::Hypervisor::CreateConfig, args: [node, cfg])
          end
        end

        if node.role != 'mailer'
          # Save SSH public key to database
          append(Transactions::Node::StorePublicKeys, args: node)
          
          # Regenerate ~/.ssh/known_hosts on all nodes in the cluster
          t = ::NodeCurrentStatus.table_name

          ::Node.joins(:node_current_status).where(
            "(#{t}.updated_at IS NULL AND UNIX_TIMESTAMP() - UNIX_TIMESTAMP(CONVERT_TZ(#{t}.created_at, 'UTC', 'Europe/Prague')) <= 120)
            OR
            (UNIX_TIMESTAMP() - UNIX_TIMESTAMP(CONVERT_TZ(#{t}.updated_at, 'UTC', 'Europe/Prague')) <= 120)"
          ).where.not(
              role: ::Node.roles[:mailer],
          ).each do |n|
            append(Transactions::Node::GenerateKnownHosts, args: n)
          end

          # Deploy private key
          append(Transactions::Node::DeploySshKey, args: node)
        end
      end
    end
  end
end

TransactionChains::Maintenance::Custom.fire
