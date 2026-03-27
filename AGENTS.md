# AGENTS

This file defines the default workflow for human and AI contributors in this repository.

## Git Worktree Policy

By default, if you are going to modify files, do not work in the main checkout and do not work on `main`.

- Treat the main checkout as read-only integration space for normal implementation work.
- Read-only investigation on `main` is allowed.
- Any non-trivial task that edits files should use its own dedicated branch and its own dedicated git worktree.
- Merge validated task branches back to `main` from the integration checkout.

### Small Fix Exception

Tiny, low-risk fixes may be done directly on `main` in the main checkout when all of the following are true:

- The change is isolated and easy to review.
- The change does not span multiple subsystems.
- There is no parallel agent or human work that could conflict with it.
- The change does not rewrite or reorganize existing work.

Examples:

- Excluding one stray file from a package manifest
- Fixing a typo in docs or comments
- Adjusting a small build warning with an obvious one-file fix

When in doubt, use a branch and a worktree.

## Branch Naming

Use a branch prefix that matches the task:

- `task/<name>` for general implementation work
- `fix/<name>` for bug fixes
- `exp/<name>` for experiments and visual comparisons

Keep names short, concrete, and filesystem-friendly.

## Standard Task Setup

```bash
cd /path/to/repo
git switch main
git pull --ff-only
git worktree add ../repo-<task-name> -b task/<task-name> main
cd ../repo-<task-name>
```

If a sibling directory is inconvenient, use another suitable location such as `/tmp`.

## Merge And Cleanup

After the task is validated:

```bash
cd /path/to/repo
git switch main
git merge --ff-only task/<task-name>
git worktree remove ../repo-<task-name>
git branch -d task/<task-name>
```

For experiments, keep the branch only as long as it still adds comparison value.

## Safety Rules

- Do not rewrite or delete someone else's in-progress work without explicit approval.
- Do not use destructive git commands unless explicitly requested.
- If multiple agents are working at once, each agent should use a separate worktree.
