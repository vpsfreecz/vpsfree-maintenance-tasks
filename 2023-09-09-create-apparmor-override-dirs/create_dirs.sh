#!/usr/bin/env bash

mkdir -p /run/vpsadmin/sys-kernel-security
mount -t tmpfs -o mode=755,size=65536 tmpfs /run/vpsadmin/sys-kernel-security
echo "[none] integrity confidentiality" > /run/vpsadmin/sys-kernel-security/lockdown
echo "capability,lockdown,yama" > /run/vpsadmin/sys-kernel-security/lsm
chmod 0444 /run/vpsadmin/sys-kernel-security/lsm
mkdir /run/vpsadmin/sys-kernel-security/integrity
mount -o remount,ro /run/vpsadmin/sys-kernel-security

mkdir -p /run/vpsadmin/sys-module-apparmor
mount -t tmpfs -o ro,mode=755,size=65536 tmpfs /run/vpsadmin/sys-module-apparmor
