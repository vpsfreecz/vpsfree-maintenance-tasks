#!/bin/sh

set -eu

config=/etc/ssh/sshd_config
backup=$config.before-2026-11-05-disable-password-authentication

fail() {
	echo "$*" >&2
	exit 1
}

[ -f "$config" ] && [ ! -L "$config" ] || fail 'Expected a regular sshd_config, not a symlink'
command -v sshd >/dev/null || fail 'sshd is not installed'
command -v rc-service >/dev/null || fail 'rc-service is not installed'

includes=$(awk '
	tolower($0) ~ /^[[:space:]]*include([[:space:]=]|$)/ {
		if (tolower($1) != "include" || NF != 2 || $2 != "/etc/ssh/sshd_config.d/*.conf") exit 1
		found = 1
	}
	END { if (found) print "yes" }
' "$config") || fail 'Active Include is unsupported; sshd_config was not changed'

if [ -n "$includes" ]; then
	include_dir=/etc/ssh/sshd_config.d
	if [ -e "$include_dir" ] || [ -L "$include_dir" ]; then
		[ -d "$include_dir" ] && [ -r "$include_dir" ] && [ -x "$include_dir" ] || fail 'Unusable Include directory'
	fi
	for snippet in "$include_dir"/*.conf; do
		[ ! -e "$snippet" ] && [ ! -L "$snippet" ] || fail 'Populated Include is unsupported; sshd_config was not changed'
	done
fi

candidate=$(mktemp "$config.XXXXXX")
previous=
trap 'rm -f "$candidate"; if [ -n "$previous" ]; then rm -f "$previous"; fi' 0
trap 'exit 1' 1 2 15

cp -p "$config" "$candidate"
awk '
	BEGIN { print "PasswordAuthentication no" }
	tolower($0) !~ /^[[:space:]]*passwordauthentication([[:space:]=]|$)/ { print }
' "$config" > "$candidate"

if cmp -s "$config" "$candidate"; then
	echo '  unchanged'
	exit 0
fi

sshd -t -f "$candidate"

previous=$(mktemp "$config.previous.XXXXXX")
cp -p "$config" "$previous"
if [ -e "$backup" ] || [ -L "$backup" ]; then
	[ -f "$backup" ] && [ ! -L "$backup" ] && [ -r "$backup" ] || fail "Unusable backup: $backup"
else
	# Publish the metadata-preserving copy without overwriting an existing backup.
	ln "$previous" "$backup"
fi

mv -f "$candidate" "$config"
if ! rc-service sshd restart; then
	echo '  restart failed; restoring previous sshd_config' >&2
	if cp -p "$previous" "$candidate" && mv -f "$candidate" "$config"; then
		rc-service sshd restart || echo '  service recovery also failed' >&2
	else
		echo '  configuration restoration failed; manual recovery required' >&2
	fi
	exit 1
fi

echo "  changed; sshd restarted; original backup: $backup"
