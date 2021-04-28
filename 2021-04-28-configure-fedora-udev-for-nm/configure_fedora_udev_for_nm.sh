#!/usr/bin/env bash
#
# Reconfigure Fedora VPSes for networking to work on Fedora 34, in case they
# upgrade from an older version.
# 
# See
#   https://github.com/vpsfreecz/vpsadminos-image-build-scripts/commit/2df9e56c5a43915b15f7f5ac70477fefd9b4c7e0
#

cat <<EOF > runscript.sh
#!/bin/sh

[ -h /etc/systemd/system/systemd-udev-trigger.service ] && \
	rm /etc/systemd/system/systemd-udev-trigger.service

mkdir -p /etc/systemd/system/systemd-udev-trigger.service.d
cat <<EOT > /etc/systemd/system/systemd-udev-trigger.service.d/vpsadminos.conf
[Service]
ExecStart=
ExecStart=-udevadm trigger --subsystem-match=net --action=add
EOT

cat <<EOT > /etc/udev/rules.d/86-vpsadminos.rules
ENV{ID_NET_DRIVER}=="veth", ENV{NM_UNMANAGED}="0"
EOT
EOF

for ctid in `ct ls -H -o id --distribution fedora` ; do
	echo "$ctid"
	ct runscript -r $ctid runscript.sh
	if [ $? == "0" ] ; then
		echo "  ok"
	else
		echo "  error"
	fi
done
