#!/bin/sh

for ctid in `ct ls -H -o id` ; do
  echo $ctid
  ct cgparams unset $ctid cglimit.memory.max
  ct cgparams unset $ctid cglimit.all.max
done
