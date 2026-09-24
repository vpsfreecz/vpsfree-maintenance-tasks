# Backup storage inventory

This task captures backup-pool metadata for one vpsAdmin node and the matching
ZFS objects, then compares the two captures offline. It only reads the database
and ZFS. The report is diagnostic: it never identifies an object as safe to
delete.

## Capture the database

Run `capture_db.rb` in the normal vpsAdmin API Ruby environment. Its shebang
uses `vpsadmin-api-ruby`, whose runner resolves the script path before starting
a transient unit as the configured API service user. That unit changes its
working directory to the immutable API package. The script and its two local
Ruby dependencies must be readable by that user, and `--output` must be an
absolute path in a private directory writable by that user. The entry point
requires `vpsadmin` and uses that runtime's production database configuration;
`db_capture.rb` holds the importable collector. There is no separate client
option file, password argument or credential override in this task. The normal
API account may have write
grants. The collector's SQL `READ ONLY` transaction is the enforced database
write protection for this run. A dedicated SELECT-only account would require
separate API runtime configuration, which this task does not provide. The
account also needs SELECT on `locations` and `environments` to build the node
identity, in addition to the captured storage and lock tables. Check the API
runtime's database target before running the task.

On the API host, run these commands as root from the directory containing
`capture_db.rb`, `db_capture.rb` and `inventory.rb`. Read the actual service
identity from `vpsadmin-api.service`; the default user and group are both
`vpsadmin-api`. The temporary directory is mode `0700` and owned by that
identity, so the transient unit can create its mode `0600` capture there.
Keep the printed capture path for the later private transfer.

```sh
(
set -eu
umask 077
api_user=$(systemctl show --property=User --value vpsadmin-api.service)
api_group=$(systemctl show --property=Group --value vpsadmin-api.service)
test -n "$api_user"
test -n "$api_group"
capture_dir=$(mktemp -d /var/tmp/vpsadmin-storage-inventory.XXXXXXXX)
chown "$api_user:$api_group" "$capture_dir"
install -o "$api_user" -g "$api_group" -m 0750 capture_db.rb "$capture_dir/capture_db.rb"
install -o "$api_user" -g "$api_group" -m 0640 db_capture.rb inventory.rb "$capture_dir/"
"$capture_dir/capture_db.rb" --node-id NODE_ID --output "$capture_dir/db.jsonl"
printf 'Capture: %s\n' "$capture_dir/db.jsonl"
)
```

A caller-relative script path can work because the shell wrapper resolves it
before starting the unit. A relative output path instead resolves under the
unit's package working directory, so the DB collector rejects it before
loading the API runtime.

The collector selects every backup pool (`role = 2`) on that exact node. It
captures the node name and FQDN, pool state, datasets in pools, trees,
branches, snapshots, snapshot placements, clone rows, confirmation states,
reference counts and scoped resource locks (including Snapshot locks), plus
maintenance locks. It omits free-text
maintenance reasons. Model relations fetch rows in bounded batches without
filtering confirmation states. The collector pins one ActiveRecord connection,
sets `REPEATABLE READ` for the next transaction, starts a read-only consistent
InnoDB snapshot, checks that the physical connection and DB connection ID do
not change, and ends the observation with `ROLLBACK`. It uses scalar metadata
queries for the DB server's UTC clock, connection ID and previous statement
timeout; application rows are read only through model relations. It restores
the session statement timeout after capture. Individual DB statements are
limited to 30 seconds and the whole capture to 15 minutes; an overrun aborts
the private temporary output. The API runtime must not start another
transaction or switch connections during this task. The `observation` record
contains server start/end UTC times and collector start/end UTC times; the
artifact header/trailer include file creation and completion. An empty pool
selection, failed query, timeout, or connection replacement leaves no output
file.

## Capture ZFS

On `backuper2.prg`, run `capture_zfs.rb` with **each exact `pools.filesystem`
value** from the DB capture. Do not substitute a pool ancestor. The roots
must match the DB selection exactly; the comparator checks this.

```sh
umask 077
mkdir -m 700 inventory-private
ruby capture_zfs.rb --root POOL/ROOT --root OTHER/ROOT \
  --output inventory-private/zfs.jsonl
```

Run this command on the actual DB node. The collector records the kernel host
name and the qualified name returned by `hostname -f`. It fails if the latter
is unqualified or has a different first label. Comparison accepts only the
DB node's location-qualified or full name; short names can collide across
locations. There is no host override. If host name resolution is incomplete,
correct it on the intended host before capturing.

The collector runs `zfs list` and `zfs get` under those roots only. It records
exact names, types, GUIDs, origins, clone names (including clones outside the
scanned roots), user reference counts and deferred-destroy flags. It scans
twice; changed objects appear as `scan_change` records and mark the capture
volatile. It does not create a ZFS snapshot or stop concurrent operations.

## Compare offline

Move the two private captures to a trusted host through an approved private
channel, then run:

```sh
ruby compare.rb --db inventory-private/db.jsonl \
  --zfs inventory-private/zfs.jsonl \
  --output inventory-private/report.jsonl
```

Every artifact is version 2 JSON Lines with a count and SHA-256 trailer. The
checksum covers the header, records and trailer metadata, including scope and
volatility. Version 1 captures must be recaptured. Existing version 2 captures
can be compared again without recapturing; regenerate reports because the
finding codes and their interpretation below have changed. Older reports keep
their original findings and checksum. The scripts create files with mode
`0600`, refuse to overwrite an existing output, and publish only a complete
capture or report. The comparator checks both
checksums and the exact root set before comparing exact paths. Findings include
missing and untracked ZFS objects, wrong object types, local broken DB links,
confirmation and head state, clone/origin inconsistencies, holds, deferred
destruction, locks and scan volatility.

Only a head tree must have exactly one head branch (`branch_head_count`). A
nonhead tree has no branch-head cardinality requirement;
`nonhead_tree_branch_head` records any flagged branches there as a diagnostic.
A backup dataset-in-pool with zero head trees is reported as
`headless_backup_dataset_in_pool`, with tree, branch and
snapshot-entry counts. This is a diagnostic state, possibly caused by head
detachment, even when snapshots remain. Multiple head trees still produce
`tree_head_count` and violate the one-head invariant. A backup branch's DB
parent-entry pointers predict its physical ZFS origin only when every pointer
resolves to one snapshot on another branch. A parent ID absent from this
node-scoped capture produces `unresolved_snapshot_parent`; it may refer to an
out-of-scope row or be missing in the full DB, which this inventory cannot
distinguish. It is not reported as a broken foreign key. Ambiguous pointers
produce `indeterminate_branch_origin`. The comparator also checks the expected
origin's `clones` property.

The count of captured incoming dependent entries plus captured clone rows is
only a lower bound for each `snapshot_in_pool.reference_count`: incoming
references from other pools may be outside this capture. A stored count below
that bound produces `reference_count_below_scoped_minimum`, with the counted
components and is the stronger discrepancy. A higher count produces
`reference_count_above_scoped_minimum`, an explicitly inconclusive follow-up
finding because out-of-scope references may explain the difference. Equality
is also inconclusive; this report cannot validate the complete reference
count. Neither finding decides deletion eligibility. A matching report also
cannot prove that
the two live systems matched at one instant: their observation windows differ.
Untracked objects can include pool infrastructure or parent datasets; classify
them from the captured paths before drawing conclusions.

Raw captures and reports can contain member dataset names and infrastructure
topology. Keep their directory private, do not commit them, and retain or
remove them under the site's evidence policy. A failed command should be
corrected and rerun with a new output path; the scripts never modify live
storage or database records.

Run the offline tests with `ruby test_inventory.rb`.
