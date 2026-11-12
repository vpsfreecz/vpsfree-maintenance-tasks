# Reconcile owned IP charges

This command repairs explicitly selected owned, detached IP allocations with a
missing charge environment and reconciles explicitly listed owner/resource groups.
It uses the installed `vpsadmin-api-ruby` and current vpsAdmin models. It requires
coordinated IP reservations, `charged_environment_id` and the existing transaction
confirmation schema. It changes no API contract or database schema.

Install `reconcile_owned_ip_charges.rb` and its sibling
`reconcile_owned_ip_charges_lib.rb` together. The executable dispatches the CLI
when run directly or loaded by `vpsadmin-api-ruby`; the library defines helpers
without starting the CLI or loading the application.

`vpsadmin-api-ruby` changes the working directory to the packaged API directory.
Pass absolute paths for operator files, including `--plan`. For a file in your
current directory, resolve it before invoking the runner, for example
`--plan "$(pwd)/plan.json"`. Task code uses `require_relative` to find its library.
Do not copy only the executable when updating an installation.

Choose the intended charge environments and exact final usage values before
applying a plan. Current network locations do not establish historical charge
provenance. A forward reconciliation is an explicit accounting decision.

## Plan and preview

Create a private JSON plan with exactly these top-level keys:

```json
{
  "version": 1,
  "groups": [{"owner_config_id": 10, "resource": "ipv6"}],
  "ips": [{
    "id": 51, "owner_config_id": 10, "network_id": 2,
    "prefix": 64, "size": "18446744073709551616",
    "from_environment_id": null, "to_environment_id": 1
  }],
  "usage_changes": [{
    "id": 40, "config_id": 10, "environment_id": 1, "resource": "ipv6",
    "from_value": "18446744073709551616",
    "to_value": "36893488147419103232"
  }]
}
```

These IDs are synthetic. Replace them with reviewed technical identities.
`owner_config_id` anchors an owner through an existing EnvironmentUserConfig;
a group spans that owner's named resource across every environment. Resources
are `ipv4`, `ipv4_private` and `ipv6`. Groups may have no IP mapping, for a
separately accepted existing discrepancy. Every missing pointer in a listed
group must have an explicit mapping.

IDs and prefixes are JSON integers. Sizes and usage values are canonical unsigned
decimal strings of at most 40 digits; size is positive. IP `from_environment_id`
is always null in this command. Unknown keys, duplicate identities and duplicate
JSON keys fail. Each IP must match its expected owner, network, prefix and size,
remain detached and unrouted, and have no charge environment. Its destination
must have one owner config and be available to the network.

```sh
./reconcile_owned_ip_charges.rb --plan /private/path/plan.json
```

Preview performs reads only and takes no reservations. It verifies complete
owned plus disjoint userless VPS inventory for exactly the listed groups, counting
each prefix by full size once. Host addresses add no quota use. Assigned export
endpoints, invalid routing/ownership, nonfinal VPS objects, unexpected usage
consumers and missing required usage rows are unsupported. Normal existing
uses must be enabled, confirmed, unlocked and correctly linked. An absent use
with zero inventory is harmless.

The computed existing-use correction set must exactly equal `usage_changes`.
An extra discrepancy, stale value or omitted correction refuses the whole plan.
Changed usage totals must fit existing allowances. The command never creates a
usage row, changes an allowance or calls allocation/free chains.

## Apply and recovery

Stop every API, scheduler and other IP/accounting writer, drain older transaction
work, then stop the supervisor. Keep writers stopped through verification. The
command does not control services. Use an administrator's numeric ID:

```sh
./reconcile_owned_ip_charges.rb --plan /private/path/plan.json \
  --apply --writers-quiesced --admin-id 900
```

The flag attests this maintenance exclusion. Apply also checks active chains,
existing reservations and undone confirmations on selected records. Failed or
resolved work with outstanding effects remains a blocker. Resolve it through its
original recovery procedure; do not remove someone else's reservations.

Apply locks and rereads the inputs, reserves the contributing IPs, VPSes and
user resources, recomputes the exact comparison, then writes metadata and usage
in one transaction. Reservations are created and removed within that transaction.
Model audit behavior remains enabled. Postconditions verify pointers, usage,
allowances and unrelated rows from the snapshot. A failure before commit rolls
back the batch. There is no automatic retry or rollback switch.

Save the scalar output privately. `validated_before_commit` includes the normalized
plan SHA256 and exact pre/post values; only `committed` reports completion. A lost
connection or output failure can make the outcome uncertain. Under fresh exclusion,
inspect exact rows against both states before retrying. A complete post-state needs
no repeat apply; a mixed or changed state needs operator inspection. Repeated apply
normally refuses stale null/before values. After later release, transfer or
assignment, restoring old values can corrupt accounting.

## Verification

Parser-only callers must require `reconcile_owned_ip_charges_lib.rb` rather than
the executable. Requiring the library preserves arguments and starts no CLI or
database work.

Pure synthetic checks load no application or database:

```sh
ruby reconcile_owned_ip_charges_test.rb
```

The synthetic suite also launches the real executable directly and through the
production runner's `script = ARGV[0]; ARGV.shift; load script` contract, from a
different working directory. It checks help, missing arguments and malformed JSON,
and separately checks a fresh library require.

The optional actual-model cases require the vpsAdmin API development shell and
its isolated MariaDB test runner. They cover preview immutability, successful
apply, unchanged allowances/unrelated rows, stale rerun, reservations, undone
confirmations and rollback after an injected later-write failure. From that API
shell, with the maintenance checkout path set explicitly:

```sh
RACK_ENV=test RECONCILE_IP_DB_TEST=1 VPSADMIN_API_DIR="$PWD" \
  bundle exec ruby /path/to/maintenance/2026-11-12-reconcile-owned-ip-charges/reconcile_owned_ip_charges_test.rb
```

The API support code selects an isolated database when no database URL/config is
provided. Use a disposable test database with a name containing `test`; these
cases delete fixture allocations, usage, reservations and transaction records.
Record the effective API source and environment with the result. The command
has an offline contract; these tests do not certify online concurrency or live
VPS behavior.
