# CI Workflows

Currently, this repo is **private**, so all workflows are defined **`on: workflow_dispatch` only** to avoid consuming GitHub Actions free tier (= doesn't auto-run on push / pull_request, only runs when manually triggered from Actions tab).

## TODO: Activation steps when going public

When making this repo public (or wanting to auto-run CI while staying private), rewrite `on:` in each workflow yaml as:

```yaml
on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:
```

This auto-runs per PR, so CLAUDE.md `## Development Flow` Step 4's "CI gate" won't be empty ("no checks reported").

## Workflow List

| workflow | target | purpose |
|---|---|---|
| [`actionlint.yml`](actionlint.yml) | `.github/workflows/*.yml` | check workflow yaml itself for syntax / common pitfalls |
| [`shellcheck.yml`](shellcheck.yml) | `scripts/*.sh` | static analysis of bash scripts (important for cross-platform requirements) |
| [`python-syntax.yml`](python-syntax.yml) | `tools/a2a-review/codex-a2a-server/server.py` | check a2a-review server Python syntax via `py_compile` (PR #43 target) |

## Design Decision (why `workflow_dispatch` only)

- Option A (yaml doc-only, no yaml): future cost of writing yaml from scratch remains
- Option B (place under `_disabled/`): yaml location non-standard, activation requires `git mv`
- **Option C adopted (this config)**: place under `.github/workflows/` + `workflow_dispatch:` only = one-line trigger rewrite to activate, UI also shows workflow existence

`workflow_dispatch` **enables manual triggering**, so to verify during setup, run from Actions tab and charge yourself.
