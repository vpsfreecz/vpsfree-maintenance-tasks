#!/usr/bin/env bash

echo 0 > /proc/sys/vm/cgroup_memory_ksoftlimd_for_all

sleep 10

for controlfile in /sys/fs/cgroup/memory/osctl/pool.tank/group.default/user.*/ct.*/memory.ksoftlimd_control ; do
        echo $controlfile
        echo 1 > $controlfile
done
