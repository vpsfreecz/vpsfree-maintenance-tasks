#!/usr/bin/env bash
#
# Reconfigure Arch VPSes for networking to work with systemd-networkd by overriding
# systemd-udev-trigger. The trigger by default fails to access some devices
# in /sys. We need only events for network devices, so that systemd will consider
# the veth device ready/available.
#
# This change could also benefit netctl configurations, where we could drop
# BindToInterfaces=() from its config.

for ctid in `ct ls -H -o id --distribution arch` ; do
	echo "$ctid"
	ct runscript -r $ctid - <<EOF
#!/bin/sh

[ -h /etc/systemd/system/systemd-udev-trigger.service ] && \
	rm /etc/systemd/system/systemd-udev-trigger.service

mkdir -p /etc/systemd/system/systemd-udev-trigger.service.d
cat <<EOT > /etc/systemd/system/systemd-udev-trigger.service.d/vpsadminos.conf
[Service]
ExecStart=
ExecStart=-udevadm trigger --subsystem-match=net --action=add
EOT
EOF
	if [ $? == "0" ] ; then
		echo "  ok"
	else
		echo "  error"
	fi
done
