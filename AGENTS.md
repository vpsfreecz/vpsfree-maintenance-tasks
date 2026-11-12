# Repository Guidelines

## Project Structure & Module Organization
- Top-level directories are one-off maintenance tasks named with a date prefix: `YYYY-MM-DD-task-name/`.
- Each task folder contains one or more runnable scripts (mostly `.rb` or `.sh`) plus any task-specific helpers.
- `templates/` holds starter templates for new tasks.
- `new` is the scaffolding script for creating a new task directory.

## Build, Test, and Development Commands
- `./new <name> [vpsadmind|api|nodectld]` creates a dated task folder and optionally copies a template.
- Run a task script directly when it is executable, for example `./2024-10-14-calc-aggregation/calc_aggregation.rb`.
- If a script is not executable in your environment, run it with the appropriate interpreter, e.g. `ruby path/to/script.rb` or `sh path/to/script.sh`.
- There is no global build step; tasks are standalone.

## Tasks run with vpsadmin-api-ruby

These rules apply only to scripts using `vpsadmin-api-ruby`, including its
shebang. Other task runtimes retain their own launch contracts.

- The packaged runner resolves the script path, removes it from `ARGV`, then uses
  Ruby `load` without changing `$PROGRAM_NAME`. Dispatch the executable CLI
  unconditionally; a guard based only on `$PROGRAM_NAME == __FILE__` skips it.
  Keep reusable definitions in a separate library that can be required without
  running the CLI or loading the application/database.
- The runner changes CWD to the packaged API directory. Use `require_relative`
  or `__dir__` for task-relative code/assets. Operator file arguments, such as a
  plan path, must be absolute; resolve them before invocation. Do not try to infer
  or restore the caller's working directory inside the task.
- Test the real executable both directly with Ruby and with the runner's
  `script = ARGV[0]; ARGV.shift; load script` sequence. Use an absolute script
  path, a different CWD and absolute file arguments; check argument forwarding,
  output and exit status. Also test that requiring the library starts no CLI or
  application/database work and leaves `ARGV` unchanged.
- When an executable requires a sibling library, install/update both together.
  The existing API template dispatches at top level and needs no entrypoint guard.

## Coding Style & Naming Conventions
- Directory names use the date-first pattern: `YYYY-MM-DD-description`.
- Script names are `snake_case` and match the task intent.
- Follow the style already used in the task folder; Ruby scripts commonly use 2-space indentation and simple, direct control flow.
- Keep changes scoped to a single task directory unless you are updating shared tooling like `new` or `templates/`.
- Maintenance transaction chains must be named `TransactionChains::Maintenance::Custom`.

## Testing Guidelines
- No shared automated test framework exists in this repository.
- Validate scripts by running them in a safe environment and reviewing output before executing on production systems.

## Commit & Pull Request Guidelines
- Commit messages must be prefixed with the task directory name, followed by a colon and a short action, e.g. `2026-02-18-fix-external-dns-zone-secondaries: use Custom transaction chain name`.
- For changes to `AGENTS.md`, use the prefix `agents:`.
- PRs should explain the maintenance goal, list execution steps (commands and paths), and note any safety checks or rollback considerations.

## Security & Configuration Tips
- Many scripts target production infrastructure; confirm you are in the correct environment and have the right credentials before running.
- Prefer least-privilege access and capture logs/output for auditability.
