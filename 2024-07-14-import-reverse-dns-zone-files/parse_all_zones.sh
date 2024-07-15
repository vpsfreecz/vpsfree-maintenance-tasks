#!/usr/bin/env bash

mkdir -p json-zones

for file in source-zones/zone.* ; do
    name=$(basename $file)

    ruby parse_zone_file.rb "$file" "json-zones/$name" || exit 1
done