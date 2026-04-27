# AGENTS

This file defines the default workflow for human and AI contributors in this repository.

## Git Worktree Policy

By default, if you are going to modify files, do not work in the main checkout and do not work on `main`.

- Treat the main checkout as read-only integration space for normal implementation work.
- Read-only investigation on `main` is allowed.
- Each AI agent should keep one long-lived default worktree outside the main checkout, for example `~/src/codex-elevated` or `~/src/claude-elevated`.
- Normal day-to-day agent work should happen in that agent's default worktree, not in the main checkout.
- Extra task-specific worktrees are for work that is unusually risky, long-running, experimental, or likely to overlap with another active branch.
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

When in doubt, use the agent's default worktree first. Make an extra task worktree only when the default one is not enough.

## Branch Naming

Use a branch prefix that matches the task:

- `task/<name>` for general implementation work
- `fix/<name>` for bug fixes
- `exp/<name>` for experiments and visual comparisons

Keep names short, concrete, and filesystem-friendly.

## Standard Task Setup

For normal AI work, bootstrap one default agent worktree and keep using it:

```bash
cd /path/to/repo
git switch main
git pull --ff-only
git worktree add ~/src/<agent>-elevated -b task/<agent>-default main
cd ~/src/<agent>-elevated
```

If the default worktree is already busy and you need a separate feature branch, create an extra task worktree:

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
- Do not add `Co-Authored-By:` trailers to commits.

## 4K Fidelity Policy

The `elevated4k/` path is not a freeform reinterpretation of Elevated. Treat it as
an engineering port with size constraints, not as an art direction sandbox.
See also `elevated4k/FIDELITY.md`.

- Preserve rendering semantics unless the user explicitly approves a visual change.
- Do not make "looks close enough" shader edits just because they save bytes.
- Cleanup, simplification, and tooling improvements are welcome when they preserve
  the produced image and timing behavior.
- When a change touches modeling, shading, texturing, camera behavior, motion blur,
  postprocessing, or pass structure, assume it is high risk for visual regression.
- High-risk visual changes must be validated with output comparison at representative
  timestamps before they are treated as acceptable optimizations.
- If a change is exploratory or intentionally changes the image, keep it on an
  experiment branch such as `exp/...` until it has been reviewed.

The historical reference for Elevated matters. The Function 2009 "behind elevated"
seminar describes the intended architecture and image goals. In particular:

- The intro uses the "2 triangles plus 1,000,000" approach: rasterized primary
  intersections plus fullscreen procedural shading.
- The final image pipeline is a 3-pass structure: geometry/intersection pass,
  deferred shading pass, then postprocessing pass.
- Motion blur is a postprocess effect and is not license to replace the shading
  model with a cheaper approximation.

If there is tension between visual fidelity and packed size, fidelity wins by
default unless the user says otherwise.
