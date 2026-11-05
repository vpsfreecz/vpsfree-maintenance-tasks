# Disable SSH password authentication

Copy both shell scripts together to each vpsAdminOS node, then run as root:

```sh
./2026-11-05-disable-ssh-password-authentication/disable_ssh_password_authentication.sh
```

The script selects running Alpine containers with `osctl ct ls`, keeping pool
and container ID together. It executes the companion script with
`osctl ct runscript` in each running container. Proven disabled configurations
are reported as `unchanged`: bytes, original backup and service state are left
alone, even when the effective `no` is not the first line or later duplicates
are ignored by sshd. Proven enabled configurations get a global `PasswordAuthentication no` and
active main-file overrides removed. The candidate is validated
before installing it and restarting Alpine's `sshd` OpenRC service. Stopped
containers are not started.

The guest uses native `sshd -T -f` and the first PasswordAuthentication value in
each Match block. Consistent native/Match values prove enabled or disabled;
mixed or unsupported conditions are `unknown` and fail without modification,
backup creation or restart. This includes potentially enabling conditional
rules, even when some overlapping rules might make them unreachable. Native
Match-all disabling rules are preserved. This is a bounded policy check, not a
full evaluator of every possible connection.

Before the first change, the original file and its metadata are saved at
`/etc/ssh/sshd_config.before-2026-11-05-disable-password-authentication`.
Reruns preserve this first backup. A failed restart restores the immediately
preceding configuration and attempts one recovery restart.

Each result identifies its pool/container. A nonzero exit means enumeration or
at least one container failed; other selected containers are still attempted.
The ordinary `Include /etc/ssh/sshd_config.d/*.conf` line is preserved and
accepted when no snippets match. Matching paths (including dangling symlinks),
unusable include directories and all other active Include forms are refused
without modification because included Match rules can override the setting.
Adding snippets later requires reassessing the policy. Missing sshd/configuration
and custom service or configuration paths require operator attention. Those
containers are not covered by a successful change elsewhere.

## Read-only original-backup report

Before selecting recipients from an earlier run log, inspect the original
backups on each relevant node. Keep the resulting reports outside Git:

```sh
./2026-11-05-disable-ssh-password-authentication/disable_ssh_password_authentication.sh --report-backup > /path/to/node-backups.tsv
```

This mode uses the same classifier on the exact original backup path above. It
does not edit configuration, create backups or invoke the service. Each stdout
row is tab-separated:

```text
ssh-password-backup-v1<TAB>NODE_FQDN<TAB>POOL<TAB>ID<TAB>enabled|disabled|unknown<TAB>SHA256_OR_DASH
```

The node name comes from `hostname -f`. The hash identifies readable original
backup bytes; `-` means no reliable hash. Missing, unusable or changing backups,
parser failure and mixed policy produce `unknown`. All enumerated guests get a
row; a nonzero exit signals unresolved inspection and diagnostics go to stderr.
Review those diagnostics and concatenate reports from the relevant nodes into
one external file for the mail task. Reported `disabled` or `unknown` never
establishes positive evidence of originally enabled password authentication.
The earlier `changed` log alone only proves a file rewrite/restart, because it
could include normalization of configurations that already disabled passwords.

## Local regression checks

```sh
python3 2026-11-05-disable-ssh-password-authentication/test_password_authentication.py
```

Requires Python 3, real OpenSSH `sshd`/`ssh-keygen` and ordinary shell tools.
Tests use temporary host keys/configs and mocked transport/service calls; they
start no server or container. They check actual parser precedence, unchanged
bytes/metadata, failure/recovery and read-only report rows/hashes.

Key authentication settings are preserved. Password logins stop working;
`AuthenticationMethods` rules requiring passwords may prevent logins entirely.
Keyboard-interactive authentication and PAM settings are unchanged.

For deliberate manual restoration, run inside the affected container:

```sh
cp -p /etc/ssh/sshd_config.before-2026-11-05-disable-password-authentication /etc/ssh/sshd_config
sshd -t && rc-service sshd restart
```

Restoration restores the original password policy. The backup is retained.
Avoid concurrent configuration changes; interruption or filesystem failure may
require manual recovery. No production execution is part of preparing this task.
