# Disable SSH password authentication

Copy both shell scripts together to each vpsAdminOS node, then run as root:

```sh
./2026-11-05-disable-ssh-password-authentication/disable_ssh_password_authentication.sh
```

The script selects running Alpine containers with `osctl ct ls`, keeping pool
and container ID together. It executes the companion script with
`osctl ct runscript` in each running container. It sets `PasswordAuthentication no`
globally and removes active overrides in the main `/etc/ssh/sshd_config`, including
Match blocks. It validates changed configuration and restarts Alpine's `sshd`
OpenRC service only when the file changes. Stopped containers are not started.

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
