set -x

files="/proc/cpuinfo
/proc/diskstats
/proc/loadavg
/proc/stat
/proc/uptime
/sys/devices/system/cpu/online"

script="ct-lxcfs-remount-script.sh"
donelist="ct-fixed.txt"
skiplist="ct-skip.txt"

echo "#!/bin/sh" > $script
echo "set -e" >> $script

for f in $files ; do
  echo "umount $f" >> $script
  echo "mount --move /dev/.osctl-mount-helper/$(basename $f) $f" >> $script
done

for ctid in `ct ls -H -o id -S running` ; do
#for ctid in 11326 ; do
  echo "$ctid"
  grep -x $ctid $donelist && continue
  grep -x $ctid $skiplist && continue

  for f in $files ; do
    hostpath="/run/osctl/pools/tank/mounts/$ctid/$(basename $f)"
    touch "$hostpath"
    mount --bind /var/lib/lxcfs/$f "$hostpath"
  done

  ct runscript $ctid $script
  rc=$?
  
  for f in $files ; do
    hostpath="/run/osctl/pools/tank/mounts/$ctid/$(basename $f)"
    umount "$hostpath"
    rm "$hostpath"
  done

  if [ "$rc" != "0" ] ; then
    echo failed
    exit 1
  fi

  echo $ctid >> $donelist
  echo ok
  #read
  sleep 3
done

