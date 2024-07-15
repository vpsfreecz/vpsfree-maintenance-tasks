#!/usr/bin/env bash

for ns in ns{1,2}.vpsfree.cz ; do
    for file in json-zones/zone.* ; do
        ruby check_reverse_records.rb "$file" "$ns" || exit 1
    done
done