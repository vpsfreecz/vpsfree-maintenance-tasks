# Repair kernel history observation bounds

This task tightens inferred kernel-history intervals when retained evidence
proves a more recent observation of the preceding state. It requires the
vpsAdmin kernel-history fix, including its shared stable-state comparator.
Run it on an API host using the installed `vpsadmin-api-ruby` environment and
the intended database. The script's shebang selects that interpreter.

From this task directory:

```sh
./repair_kernel_history_bounds.rb
./repair_kernel_history_bounds.rb --apply
```

The first command previews all eligible node and storage hosts, including
inactive hosts. Review the output before running the second command. Each line
identifies the node, event, old and proposed bounds, supporting evidence, and
whether the event would change or why it is skipped. The command prints totals
for each node and for the whole run.

Use repeated `--node` options to select a subset:

```sh
./repair_kernel_history_bounds.rb --node 400 --node 401
./repair_kernel_history_bounds.rb --apply --node 400 --node 401 --batch-size 500
```

Node IDs and batch size must be positive integers. The default batch size is
1,000. An unknown or ineligible explicit node ID rejects the invocation before
any writes. Argument errors
exit with status 2; operational failures exit with status 1. Insufficient
evidence and concurrent changes are reported as skips, not command failures.
An interrupted apply can leave earlier repairs committed; rerunning is safe.

## What can be repaired

The task considers inferred node-reported release changes and explicitly
classified livepatch applications or removals. It skips boots, reconstructed or
exact events, missing lower bounds, and ambiguous classifications. Software,
sysctl and other component histories are outside this historical repair.

For each event it finds the preceding public baseline and searches retained
immutable event snapshots, including snapshots attached to internal events.
A supporting snapshot must confirm that baseline's complete stable kernel state
within the same boot. The task checks the stored content digests of the baseline,
target and supporting snapshot. It tightens the lower bound only when:

```text
old observed_after < proven confirmation < observed_before
```

Mutable current snapshots, recovery checkpoints, raw logs and uname-only status
samples cannot support a repair. Retention may have removed the useful evidence,
and unchanged reports do not necessarily create immutable snapshots. Some
intervals can therefore remain wide even after a successful run. The task never
invents a confirmation for those intervals.

The selected nodes and candidate event IDs are fixed before processing starts.
Before each write, the task revalidates the target, predecessor and supporting
evidence under the node lock. Applied repairs change only the lower bound and
`updated_at`, invalidating the public revision. Upper bounds, classification,
confidence, effective timestamps and evidence remain intact. A rerun without
new supporting evidence makes no further changes.

A dry-run does not reserve its proposals for a later apply. For an approved
preview that must match the apply, keep both supervisors and other history
writers paused between the preview and apply. If writers resume, review a fresh
preview. The apply still revalidates every proposal before writing.

## Deployment and rollback

Pause both supervisor writers before activating the new API package. Keep them
paused while running its additive migrations and updating the second API host.
Then restart both supervisors and verify that stable observations advance
`last_confirmed_at` while original event bounds, `updated_at` and revisions stay
unchanged. On NixOS, use a temporary runtime systemd drop-in with a false start
condition to prevent activation from restarting a supervisor. Verify the loaded
drop-in and a blocked start on both API hosts before and after each activation.
Remove the temporary condition only after both packages and the schema are ready.

Migration `20260914180000_add_node_kernel_event_last_confirmed_at` adds a nullable
column without a default or backfill. Migration
`20260914190000_add_node_kernel_evidence_checkpoints` adds an empty private table
for preserving valid comparison reports through rejected evidence. Neither
migration repairs historical rows or seeds confirmation times. Reports already
lost before the upgrade cannot be recovered from that table.

No node upgrade or reboot is required. Older application code can ignore both
additive schema changes on rollback, although its old recording behavior
returns. Keep the column and table during an application rollback. Do not
reverse evidence-supported historical repairs automatically.

## Disposable validation

Use the matching vpsAdmin checkout's API Nix shell to run the task specs:

```sh
nix develop .#api -c bundle exec rspec /absolute/path/to/this/task/spec
```

The API test helper creates an isolated MariaDB database when no database is
configured. The specs exercise the installed interpreter's `load` entry point
in a subprocess against that disposable database, including help, all-node
preview, subset apply, all-node apply and rerun. Do not point the tests at an
operational database.
