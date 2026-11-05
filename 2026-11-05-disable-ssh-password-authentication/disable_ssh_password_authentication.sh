#!/usr/bin/env bash

set -u

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 1
payload=$script_dir/disable_ssh_password_authentication_in_container.sh
if [ ! -r "$payload" ]; then
	echo "Unable to read container script: $payload" >&2
	exit 1
fi

if ! containers=$(osctl ct ls -H -o pool,id --distribution alpine --state running); then
	echo 'Unable to list running Alpine containers' >&2
	exit 1
fi

status=0
while read -r pool id; do
	[ -n "$pool" ] || continue
	echo "$pool/$id"
	if osctl --pool "$pool" ct runscript "$id" "$payload" </dev/null; then
		:
	else
		echo "  failed: $pool/$id" >&2
		status=1
	fi
done <<< "$containers"

exit "$status"
