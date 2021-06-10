#!/bin/sh
set -e
umount /proc/cpuinfo
mount --move /dev/.osctl-mount-helper/cpuinfo /proc/cpuinfo
umount /proc/diskstats
mount --move /dev/.osctl-mount-helper/diskstats /proc/diskstats
umount /proc/loadavg
mount --move /dev/.osctl-mount-helper/loadavg /proc/loadavg
umount /proc/stat
mount --move /dev/.osctl-mount-helper/stat /proc/stat
umount /proc/uptime
mount --move /dev/.osctl-mount-helper/uptime /proc/uptime
umount /sys/devices/system/cpu/online
mount --move /dev/.osctl-mount-helper/online /sys/devices/system/cpu/online

