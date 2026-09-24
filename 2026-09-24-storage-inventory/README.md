# Backup storage inventory

This task captures backup-pool metadata for one vpsAdmin node and the matching
ZFS objects, then compares the two captures offline. It only reads the database
and ZFS. The report is diagnostic: it never identifies an object as safe to
delete.

## Capture the database

Run `capture_db.rb` where a MariaDB client can reach the production vpsAdmin
database. Use a dedicated account with `SELECT` on the tables named in the
script, no write grants, and a private client option file. A local socket may
be used. Do not pass a password on the command line.

```sh
umask 077
mkdir -m 700 inventory-private
ruby capture_db.rb --node-id NODE_ID \
  --defaults-file /private/path/reader.cnf \
  --output inventory-private/db.jsonl
```

The client option file must be a regular file with no group or other access.
The collector selects every backup pool (`role = 2`) on that exact node. It
captures the node name and FQDN, pool state, datasets in pools, trees,
branches, snapshots, snapshot placements, clone rows, confirmation states,
reference counts and scoped resource and maintenance locks. It omits free-text
maintenance reasons. All queries run on one connection in a repeatable-read,
read-only consistent snapshot. The client streams rows and cannot reconnect
mid-transaction. The artifact records the observation window.
An empty pool selection or failed query leaves no output file.

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
volatility. Version 1 captures must be recaptured. The
scripts create files with mode `0600`, refuse to overwrite an existing output,
and publish only a complete capture or report. The comparator checks both
checksums and the exact root set before comparing exact paths. Findings include
missing and untracked ZFS objects, wrong object types, broken DB links,
confirmation and head state, clone/origin inconsistencies, holds, deferred
destruction, locks and scan volatility. A backup branch's DB parent-entry
pointers predict its physical ZFS origin only when every pointer resolves to
one snapshot on another branch. Ambiguous pointers produce an indeterminate
finding. The comparator also checks the expected origin's `clones` property
and compares each `reference_count` with its DB dependent-entry and clone-row
counts. These counts are diagnostic and never decide deletion eligibility.
A matching report also cannot prove that
the two live systems matched at one instant: their observation windows differ.
Untracked objects can include pool infrastructure or parent datasets; classify
them from the captured paths before drawing conclusions.

Raw captures and reports can contain member dataset names and infrastructure
topology. Keep their directory private, do not commit them, and retain or
remove them under the site's evidence policy. A failed command should be
corrected and rerun with a new output path; the scripts never modify live
storage or database records.

Run the offline tests with `ruby test_inventory.rb`.
