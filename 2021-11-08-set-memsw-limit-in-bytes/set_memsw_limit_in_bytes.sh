#!/bin/sh

for ctid in $(osctl ct ls -H -o id) ; do
	echo "VPS $ctid"
	memlimit=$(osctl -p ct cgparams ls -H -o value $ctid memory.limit_in_bytes)

	if [ "$memlimit" == "" ] ; then
		echo "  no limit"
	else
		echo "  set $memlimit"
		osctl ct cgparams set $ctid memory.memsw.limit_in_bytes $memlimit
	fi
done
