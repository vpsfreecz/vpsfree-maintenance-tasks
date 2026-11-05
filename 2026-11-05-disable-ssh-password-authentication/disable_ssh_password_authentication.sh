#!/usr/bin/env bash

set -u

report=false
case "$#:${1:-}" in
	0:) ;;
	1:--report-backup) report=true ;;
	*) echo "Usage: $0 [--report-backup]" >&2; exit 1 ;;
esac
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 1
payload=$script_dir/disable_ssh_password_authentication_in_container.sh
if [ ! -r "$payload" ]; then
	echo "Unable to read container script: $payload" >&2
	exit 1
fi
if "$report"; then
	node=$(hostname -f) || exit 1
	[[ "$node" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || { echo 'Invalid node hostname' >&2; exit 1; }
fi
if ! containers=$(osctl ct ls -H -o pool,id --distribution alpine --state running); then
	echo 'Unable to list running Alpine containers' >&2
	exit 1
fi

status=0
while read -r pool id; do
	[ -n "$pool" ] || continue
	if [[ ! "$pool" =~ ^[^[:space:]/]+$ || ! "$id" =~ ^[1-9][0-9]*$ ]]; then
		echo 'Invalid container identity from osctl' >&2
		status=1
		continue
	fi
	if "$report"; then
		ok=true
		inspection=$(osctl --pool "$pool" ct runscript "$id" "$payload" report-backup </dev/null) || ok=false
		policy=unknown
		digest=-
		if [[ "$inspection" =~ ^(enabled|disabled|unknown)$'\t'([a-fA-F0-9]{64}|-)$ ]]; then
			policy=${BASH_REMATCH[1]}
			digest=${BASH_REMATCH[2]}
			if [[ "$policy" != unknown && ( "$digest" = - || "$ok" = false ) ]]; then
				policy=unknown
				digest=-
			fi
		fi
		printf 'ssh-password-backup-v1\t%s\t%s\t%s\t%s\t%s\n' "$node" "$pool" "$id" "$policy" "$digest"
		if [ "$policy" = unknown ] || [ "$ok" = false ]; then
			echo "Backup inspection unresolved: $pool/$id" >&2
			status=1
		fi
	else
		echo "$pool/$id"
		if ! osctl --pool "$pool" ct runscript "$id" "$payload" </dev/null; then
			echo "  failed: $pool/$id" >&2
			status=1
		fi
	fi
done <<< "$containers"

exit "$status"
