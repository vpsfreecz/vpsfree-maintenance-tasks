#!/usr/bin/env bash
# Connect to OpenVZ nodes and find VPS which can be safely migrated:
# 
#  - no NFS
#  - no docker 1.10
#  - no qemu
#
# Run from a confctl cluster configuration directory

if [ $# != 1 ] ; then
	echo "Usage: $0 <output dir>"
	exit 1
fi

outDir="$1"
vzNodes="$(confctl ls -a node.role=hypervisor --managed n -H -o host.fqdn)"

mkdir -p "$outDir"

for vzNode in $vzNodes ; do
	echo "Checking $vzNode"

	logFile="$outDir/${vzNode}-log.txt"
	okFile="$outDir/${vzNode}-migrate.txt"

	cat <<'EOF' | ssh -l root $vzNode 2> "$logFile" > "$okFile"
for veid in $(vzlist -H -o veid) ; do
	>&2 echo "checking $veid"

	veok=yes

	if vzctl exec2 $veid cat /proc/mounts | grep nfs | grep -q '172\.' ; then
		>&2 echo "  > $veid has nfs"
		veok=no
	fi

	if vzctl exec2 $veid docker --version 2> /dev/null | grep -q 'version 1\.10' ; then
		>&2 echo "  > $veid has docker"
		veok=no
	fi

	if vzctl exec2 $veid ps aux | grep -q qemu ; then
		>&2 echo "  > $veid has qemu"
		veok=no
	fi

	[ "$veok" == "yes" ] && echo $veid
done
EOF
done
