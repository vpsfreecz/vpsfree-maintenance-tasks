# Notify Alpine users about the SSH security issue

Copy this task directory to a host with the vpsAdmin API environment. Supply the
original SSH run log and the read-only original-backup report as separate files;
do not add logs, reports or recipient lists to Git.

First collect the fixed TSV report from every relevant node using the companion
[SSH task](../2026-11-05-disable-ssh-password-authentication/README.md#read-only-original-backup-report).
Review its stderr/unknown rows and concatenate node reports outside Git. Then
preview from this directory:

```sh
./mail_alpine_users_sshhole.rb /path/to/run.log /path/to/backups.tsv
```

The preview prints log counts, evidence exclusions, identity mismatches,
recipients, internal VPS outcomes, subject and rendered message. It prepares
mail through the usual Custom chain and deliberately raises before returning,
so the database transaction rolls back and queues no mail. A nonzero preview
exit is expected. Invalid arguments, malformed/conflicting evidence or rendering
errors abort; no eligible recipients is a successful no-op.

After reviewing the preview, an operator can explicitly queue messages with:

```sh
./mail_alpine_users_sshhole.rb /path/to/run.log /path/to/backups.tsv execute
```

Executing again can queue duplicate messages. Queued or sent email cannot be
undone by reverting this script. Development checks use mocks; no live database
or mail run was performed while preparing this task.

Recipients are active users with active Alpine VPSes whose latest available
status reports both valid status and running. Automatic eligibility requires an
explicit changed log result AND an enabled original-backup report with SHA-256,
matching the log pool, current pool and current node domain name. Disabled,
unknown, missing or mismatched report evidence excludes that VPS. The old run
log's changed result alone proves a file rewrite/restart, not that password
authentication was previously enabled. No recipient count follows from the old
43 changed records without the external report and current database filtering.

Operator-confirmed manually fixed VPS 30231 remains the sole explicit exception
when its failed dozer/30231 log record is present. The operator also confirmed
its original backup exists; it still needs the current active/running/Alpine/pool
checks but does not require enabled report policy. Other failed, unchanged,
incomplete, unlogged, stopped and ineligible VPSes are excluded.

The report parser accepts only the fixed ssh-password-backup-v1 TSV format.
Identical duplicate rows coalesce; conflicting node/pool/policy/hash rows for one
VPS ID abort before any mail preparation. The log does not prove a historical
node/ownership map: global ID, original log pool, read-only report identity and
current database identity are the available binding. Inspect the selected users
and VPSes before execution.

There is one email per qualifying user. Failure classifications stay in operator
output and do not appear in member mail. Only confirmed changed VPSes appear in
the change and original-backup paragraphs. Czech and English templates are
provided, with English fallback for missing or unsupported user language. The
templates describe SSH key deployment and remote-console access.
