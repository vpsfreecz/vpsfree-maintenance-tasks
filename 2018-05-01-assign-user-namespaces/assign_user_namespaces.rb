#!/usr/bin/env ruby
# <description>
#
# Usage: ./assign_user_namespaces.rb <BLOCK_COUNT> [USER... | all]
#

Dir.chdir('/opt/vpsadmin/api')
require '/opt/vpsadmin/api/lib/vpsadmin'

if ARGV.count < 2
  puts "Usage: ./assign_user_namespaces.rb <BLOCK_COUNT> [USER... | all]"
  exit(false)
end

module TransactionChains
  module Maintenance
    remove_const(:Custom)

    class Custom < TransactionChain
      label 'Assign userns'
      allow_empty

      def link_chain
        cnt = ARGV[0].to_i

        if ARGV[1] == 'all'
          ::User.where('object_state < 2').order('id').each do |user|
            assign_to_user(user, cnt)
          end

        else
          ::User.where(
            id: ARGV[1..-1].map(&:to_i)
          ).where('object_state < 2').each do |user|
            assign_to_user(user, cnt)
          end
        end
      end

      protected
      def assign_to_user(user, cnt)
        use_chain(UserNamespace::Allocate, args: [user, cnt])
      end
    end
  end
end

TransactionChains::Maintenance::Custom.fire
