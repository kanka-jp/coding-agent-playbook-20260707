# Box Ops (sbx box lifecycle)

The operational foundation of box-primary mode = **running claude / codex inside sbx (Docker Sandboxes) boxes** (YOLO/isolated, microVM-per-agent). This rule covers the procedures for box environment setup, launch, parallel execution, host escape hatch, and cleanup. See [CLAUDE.md](../CLAUDE.md) "Development Flow" for the full development flow, and [sbx/README.md](../sbx/README.md) for image/mixin details.

## 0. Environment Setup (Once per machine. Reusable across all projects)

Images can be loaded at the machine level and reused independently of the project:

```bash
sbx login                                              # Required for subsequent sbx secret set / image pull etc. (template load itself uses local tar, so not needed)
docker build --load -t coding-agent-playbook-sbx sbx/ # Generic box with claude/codex/uv/python included (--load: puts into local image store even with non-default BUILDX_BUILDER driver)
docker save coding-agent-playbook-sbx -o cap-sbx.tar
sbx template load cap-sbx.tar                          # sbx does not share local images, so load is required
```

**Secret registration** (proxy injection outside box is the principle. Exception: in some paths, tokens are provisioned inside box; security tradeoff is explained in [sbx/README.md](../sbx/README.md)):

- **claude**: For subscription parallelism, use `claude setup-token` → `sbx secret set -g anthropic` (automatic authentication for all boxes, recommended). For single-session, use `/login` inside box. For API key, use `sbx secret set -g anthropic`
- **codex**: Built-in claude agent's cohabiting box (codex included) cannot use OAuth proxy injection (agent-gating), so transfer `~/.codex/auth.json` from host after `codex login` to the box (3 steps: pre-create transfer dest dir + `sbx cp` + change ownership; see [sbx/README.md](../sbx/README.md) "codex subscription authentication"). **Built-in codex agent's dedicated box (codex reviewer pair = `cdx-<NAME>`)** uses `sbx secret set -g openai --oauth` for proxy injection at creation time (token doesn't enter box, auth.json transfer not needed)

## 1. Box Launch

```bash
# Single dev box (bind-mount host worktree. auto-named with auto-provisioned cdx-<NAME> reviewer pair)
bash scripts/dev.sh

# Named dev box (idempotent attach-or-create)
bash scripts/dev.sh <NAME>

# Parallel dev boxes (run multiple with no args in separate terminals; each dev box gets independent cdx pair)
bash scripts/dev.sh
bash scripts/dev.sh
bash scripts/dev.sh ls [-q]                             # List + cdx status (-q for name only)
bash scripts/dev.sh attach [<NAME|N>]                   # Re-attach (no args = picker)
bash scripts/dev.sh kill <NAME|N>                       # Terminate (also destroys paired cdx-<NAME>)
bash scripts/dev.sh prune [--yes] [--all]               # Bulk cleanup of orphan cdx pairs / stale leases / stale locks (no args = dry-run; --all includes dev boxes without CDX. --all uses sbx ls --json to skip status=running (jq required; failure/parse error = fail-closed abort). Dev.sh shell attached or direct sbx exec boxes are not mistakenly deleted. Re-snapshots running just before delete to prevent race between scan and delete window)

# Sandbox box (--clone ., no cdx pair, for ad-hoc exploration before PR)
bash scripts/dev.sh sandbox [<NAME>]
```

- Startup loads `.mcp.json` / CLAUDE.md (box co-hosts claude+codex)
- **dev box (bind-mount)** makes host's `.worktrees/<NN>/` visible from box (worktree is created with `--relative-paths` so `git -C .worktrees/<NN>` works inside box too)
- **sandbox box (`--clone .`)** doesn't bring host's `.worktrees/` (untracked) so if handling stage inside it, run `bash scripts/internal/setup-worktrees.sh` in box

## 2. Host Escape Hatch (limited uses for leaving the box)

Default is inside the box. Only leave for host-privileged tasks:

1. Browser verification with visual feedback (headful chrome-devtools on host)
2. Docker operations (Traefik for parallel startup etc.)
3. Other host-privileged tasks

Dev server inside box is published to host via `sbx ports <box> --publish <port>` (outputs `127.0.0.1:<host port>->...` immediately after publish. Re-check anytime with `sbx ports <box>`).

## 3. Cleanup

- Kill dev box: `bash scripts/dev.sh kill <NAME|N>` (also destroys paired cdx-`<NAME>` reviewer). Sandbox box: `sbx rm <box>`
- Codex reviewer pair box (`cdx-<NAME>`) auto-tears down via dev.sh trap on TTY exit (per-pair lifecycle, [setup.md](../docs/setup.md)). Orphan/stale leases/locks left if trap doesn't run are bulk-cleaned with **`bash scripts/dev.sh prune`** (dry-run shows deletion candidates → `--yes` to execute). Stale sbx policy entries: check with `sbx policy ls` and remove with `sbx policy rm <id>`
