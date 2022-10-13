#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Find VPS migrations in state `fatal` and generate a bash script to resolve them:
#
#   - cancel transaction confirmations
#   - ensure the VPS is running on the source node
#   - clean up the VPS on the destination
#   - clean up migration state on the source node
#
# We assume that the migration failed during rollback, so we restore the VPSes
# on the source nodes. The output script is supposed to be run from a system
# with SSH access to all nodes.
#
require 'vpsadmin'

if ARGV.length != 1
  fail "Usage: #{$0} <dir>"
end

dir = ARGV[0]

chain_file = File.open(File.join(dir, 'chains.txt'), 'w')
vps_file = File.open(File.join(dir, 'vpses.txt'), 'w')
script_file = File.open(File.join(dir, 'script.sh'), 'w')

script_file.puts(<<END)
#!/usr/bin/env bash
set -x
END

::TransactionChain.where(state: 'fatal', name: 'os_to_os').each do |chain|
  concern = chain.transaction_chain_concerns.take!
  vps = ::Vps.find(concern.row_id)
  
  node = vps.node
  dst_node = nil

  chain.transactions.joins(:transaction_confirmations).where(
    transaction_confirmations: {class_name: 'Vps'}
  ).each do |t|
    t.transaction_confirmations.where(class_name: 'Vps').each do |conf|
      if conf.attr_changes['node_id']
        dst_node = ::Node.find(conf.attr_changes['node_id'])
        break
      end
    end
  end

  if dst_node.nil?
    fail "not found dst node for chain #{chain.id}"
  end

  uns_map = vps.dataset_in_pool.user_namespace_map

  puts "#{chain.id} #{chain.created_at} #{chain.name} VPS #{vps.id} from #{node.domain_name} to #{dst_node.domain_name} (uns #{uns_map.id})"

  chain_file.puts(chain.id.to_s)
  vps_file.puts(vps.id.to_s)

  script_file.puts(<<END)
echo "VPS #{vps.id} on #{node.domain_name}"
echo "  > cancelling confirmations"
cat <<EOF | ssh root@#{node.domain_name}
nodectl chain #{chain.id} confirm --no-success
nodectl chain #{chain.id} release
nodectl chain #{chain.id} resolve
EOF

echo "  > ensuring it is started"
cat <<EOF | ssh root@#{node.domain_name}
ct ls #{vps.id}
ct start #{vps.id}
EOF

echo "  > cleaning up on src"
cat <<EOF | ssh root@#{node.domain_name}
ct send cancel -l -f #{vps.id}
EOF

echo "  > cleaning up on dst"
cat <<'EOF' | ssh root@#{dst_node.domain_name}
ct ls #{vps.id}
ct_state=$(ct show -H -o state #{vps.id})
if [ "$ct_state" != "stopped" ] ; then
  echo "ct is not stopped!"
else
  ct del #{vps.id}
  user del #{uns_map.id}
fi
EOF

echo "  > hit enter to continue"
read


END
end

chain_file.close
vps_file.close
script_file.close
