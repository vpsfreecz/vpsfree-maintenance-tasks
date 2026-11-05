#!/bin/sh

set -eu

config=/etc/ssh/sshd_config
backup=$config.before-2026-11-05-disable-password-authentication

fail() {
	echo "$*" >&2
	exit 1
}

# Unknown syntax or conditional policy is deliberately left to the operator.
classify_policy() {
	policy_file=$1
	if [ ! -f "$policy_file" ] || [ -L "$policy_file" ] || [ ! -r "$policy_file" ]; then
		echo 'Missing or unusable policy file' >&2
		echo unknown
		return
	fi
	includes=$(awk '
		tolower($0) ~ /^[[:space:]]*["\047](include|match|passwordauthentication)/ { exit 1 }
		tolower($0) ~ /^[[:space:]]*include([[:space:]=]|$)/ {
			if (tolower($1) != "include" || NF != 2 || $2 != "/etc/ssh/sshd_config.d/*.conf") exit 1
			found = 1
		}
		END { if (found) print "yes" }
	' "$policy_file") || { echo 'Unsupported policy syntax/Include' >&2; echo unknown; return; }
	if [ -n "$includes" ]; then
		include_dir=/etc/ssh/sshd_config.d
		if [ -e "$include_dir" ] || [ -L "$include_dir" ]; then
			if [ ! -d "$include_dir" ] || [ ! -r "$include_dir" ] || [ ! -x "$include_dir" ]; then
				echo 'Unusable Include directory' >&2
				echo unknown
				return
			fi
		fi
		for snippet in "$include_dir"/*.conf; do
			if [ -e "$snippet" ] || [ -L "$snippet" ]; then
				echo 'Populated Include is unsupported' >&2
				echo unknown
				return
			fi
		done
	fi
	dump=$(sshd -T -f "$policy_file") || { echo unknown; return; }
	native=$(printf '%s\n' "$dump" | awk 'tolower($1) == "passwordauthentication" { print tolower($2) }')
	case "$native" in yes|no) ;; *) echo unknown; return ;; esac
	if ! awk -v native="$native" '
		{
			line = $0
			sub(/^[[:space:]]*/, "", line)
			if (tolower(line) ~ /^match([[:space:]=]|$)/) { in_match = 1; seen = 0; next }
			if (!in_match || seen || tolower(line) !~ /^passwordauthentication([[:space:]=]|$)/) next
			seen = 1
			sub(/^[^[:space:]=]+[[:space:]]*=?[[:space:]]*/, "", line)
			sub(/[[:space:]]+#.*$/, "", line)
			sub(/[[:space:]]*$/, "", line)
			if (line ~ /^".*"$/ || line ~ /^\047.*\047$/) line = substr(line, 2, length(line) - 2)
			if (tolower(line) != native) bad = 1
		}
		END { exit bad }
	' "$policy_file"; then
		echo unknown
	elif [ "$native" = no ]; then
		echo disabled
	else
		echo enabled
	fi
}

hash_file() {
	checksum=$(sha256sum "$1") || return 1
	printf '%s\n' "${checksum%% *}"
}

case "${1:-}" in
	report-backup)
		[ "$#" -eq 1 ] || fail 'Unexpected report arguments'
		if [ ! -f "$backup" ] || [ -L "$backup" ] || [ ! -r "$backup" ]; then
			printf 'unknown\t-\n'
			exit 1
		fi
		before=$(hash_file "$backup") || { printf 'unknown\t-\n'; exit 1; }
		policy=$(classify_policy "$backup")
		after=$(hash_file "$backup") || { printf 'unknown\t-\n'; exit 1; }
		if [ "$before" != "$after" ]; then
			echo 'Backup changed during inspection' >&2
			printf 'unknown\t-\n'
			exit 1
		fi
		printf '%s\t%s\n' "$policy" "$after"
		[ "$policy" != unknown ]
		exit
		;;
	'') [ "$#" -eq 0 ] || fail 'Unexpected arguments' ;;
	*) fail 'Unknown mode' ;;
esac

command -v rc-service >/dev/null || fail 'rc-service is not installed'
policy=$(classify_policy "$config")
case "$policy" in
	disabled) echo '  unchanged'; exit 0 ;;
	enabled) ;;
	*) fail 'PasswordAuthentication policy is unknown; sshd_config was not changed' ;;
esac

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
