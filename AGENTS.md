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

## Coding Style & Naming Conventions
- Directory names use the date-first pattern: `YYYY-MM-DD-description`.
- Script names are `snake_case` and match the task intent.
- Follow the style already used in the task folder; Ruby scripts commonly use 2-space indentation and simple, direct control flow.
- Keep changes scoped to a single task directory unless you are updating shared tooling like `new` or `templates/`.

## Testing Guidelines
- No shared automated test framework exists in this repository.
- Validate scripts by running them in a safe environment and reviewing output before executing on production systems.

## Commit & Pull Request Guidelines
- Commit messages typically follow `Add YYYY-MM-DD-task-name` or `task-name: short action`.
- PRs should explain the maintenance goal, list execution steps (commands and paths), and note any safety checks or rollback considerations.

## Security & Configuration Tips
- Many scripts target production infrastructure; confirm you are in the correct environment and have the right credentials before running.
- Prefer least-privilege access and capture logs/output for auditability.
