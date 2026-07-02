# Worktrees (how to create and clean up work worktrees)

When making changes, **create a work worktree with `git worktree add` before editing**. This rule summarizes how to create/clean up worktrees and why `git checkout -b` is prohibited. For overall development flow, see [CLAUDE.md](../CLAUDE.md) "Development Flow"; for stage worktree conventions (lecture checkpoint mechanism), see [CLAUDE.md](../CLAUDE.md) "Stage Branch Conventions".

## Why `git worktree add` instead of `git checkout -b`?

**Do NOT change the main checkout's branch with `git checkout -b`.** In direct-mount boxes, the main checkout is directly tied to the host's working tree; if you `git checkout -b`, you change the user's environment (host work tree). Always create a worktree and work there.

```bash
# NG: changes the main checkout's branch (dirties the host environment)
git checkout -b fix/something

# OK: leaves main as-is, work in a worktree
git worktree add .worktrees/fix-something -b fix/something
# ... work·commit·push ...
git worktree remove .worktrees/fix-something
```

## Creating and cleaning up

- **Create**: `git worktree add .worktrees/<name> -b <branch> main` (base is normally main)
- **Clean up**: After work (after merge), run `git worktree remove .worktrees/<name>` (manual rm leaves stale registry entries). If the current directory is inside the worktree, remove will fail; **first `cd` back to the main repo** before removing.
- Worktrees use `--relative-paths` (git 2.48+), so `git -C .worktrees/<name>` works even inside a box (see cross-platform requirements in [CLAUDE.md](../CLAUDE.md))

## Project (demo app) implementation is in stage worktrees

- Changes to lecture materials (README / CLAUDE.md / rules/ / scripts/ / slides/) and `sbx/` are made in work worktrees per this rule.
- **Project (demo app) implementation itself is done inside the corresponding stage worktree (`.worktrees/<NN-slug>/*`)**, not in the main checkout. Don't place project code in the main checkout. If stage worktrees are not yet set up, expand them with `bash scripts/internal/setup-worktrees.sh` (Windows: `scripts/internal/setup-worktrees.ps1`) (stage is the lecture checkpoint mechanism. Conventions: [CLAUDE.md](../CLAUDE.md) "Stage Branch Conventions").
