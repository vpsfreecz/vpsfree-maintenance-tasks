#!/usr/bin/env bash
# Authorize send-receive pubkeys from vpsAdminOS nodes on vz nodes
# for rsync/ssh migrations.
#
# Run from confctl cluster configuration directory

osNodes="$(confctl ls -a node.role=hypervisor --managed y -H -o host.fqdn)"
vzNodes="$(confctl ls -a node.role=hypervisor --managed n -H -o host.fqdn)"

keyFile=os-nodes-pubkeys.txt

echo > "$keyFile"

for osNode in $osNodes ; do
	echo "Fetching key from $osNode"
	ssh -l root $osNode cat /tank/conf/send-receive/key.pub >> "$keyFile"
done

for vzNode in $vzNodes ; do
	echo "Uploading key to $vzNode"

	if ! ssh -l root $vzNode cat /root/.ssh/authorized_keys-admins > /dev/null ; then
		echo "$vzNode not setup for authorized_keys merge"
		exit 1
	fi

	scp "$keyFile" root@${vzNode}:/root/.ssh/authorized_keys-osnodes
	ssh -l root $vzNode "cd /root/.ssh && cat authorized_keys-admins authorized_keys-osnodes > authorized_keys"
done
