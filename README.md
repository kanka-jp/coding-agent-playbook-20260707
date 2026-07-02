# coding-agent-playbook

A workshop repository for learning the full development workflow using coding agents (claude / codex), from implementation to deployment.

**A single command `bash scripts/dev.sh` enters an isolated workshop box, and then relying on claude follows the development flow in [CLAUDE.md](CLAUDE.md) (worktree → implementation → PR → codex review + CI → review handling → merge) autonomously** — that's the fastest path. The security model relies on hypervisor boundaries with microVM-per-agent ([Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) `sbx`), so even in YOLO / auto-mode without approval gates, the container boundary cannot be breached (see [sbx/README.md](sbx/README.md) "Why sbx?").

---

## 1. Initial Setup (Once per machine)

**Requirements**: Host needs `sbx` CLI **v0.31+** ([Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) — verify with `sbx --version`, `--clone` mode introduced in v0.31.0) + Docker, git **2.48+**, and `claude` CLI ([Claude Code official install instructions](https://claude.com/claude-code) — used only for `claude setup-token` in steps 1-2 to issue long-lived tokens).

```bash
# 1-1. Host authentication (once)
sbx login                                  # Docker account authentication

# 1-2. Register secrets (all 3 types required before launching boxes — details & PAT permissions: docs/setup.md)
claude setup-token                         # Paste the displayed token in the next line
sbx secret set -g anthropic
sbx secret set -g github                   # Paste fine-grained PAT (issuance steps: docs/setup.md)
sbx secret set -g openai --oauth           # Browser authentication with ChatGPT

# 1-3. Expand stage worktrees (project itself)
bash scripts/internal/setup-worktrees.sh
```

Image build is **automatic on first run of `bash scripts/dev.sh` in §2** (~5 min). To build explicitly: `bash scripts/build-image.sh` (rebuild) / `bash scripts/check-setup.sh` (environment doctor).

Windows (PowerShell) use corresponding `.ps1` (`powershell -ExecutionPolicy Bypass -File scripts/dev.ps1` etc).

**Details** (PAT scope & rationale / API key path / cdx-`<NAME>` pair reviewer operation / image / claude / codex updates): [docs/setup.md](docs/setup.md)

---

## 2. Enter a box and develop (each session)

```bash
bash scripts/dev.sh                        # Launch new dev box (auto-named / cdx-<NAME> reviewer pair also auto-provisioned / includes ~5 min image build on first run)
# Windows: powershell -ExecutionPolicy Bypass -File scripts/dev.ps1
```

No need to memorize names (the name is output by dev.sh after generation). To re-attach or switch between multiple dev boxes, use subcommands:

```bash
bash scripts/dev.sh ls                     # List existing dev boxes (#, NAME, CDX status)
bash scripts/dev.sh ls -q                  # Name only (Docker `docker ps -aq` compatible, xargs friendly)
bash scripts/dev.sh attach                 # 0→start / 1→unconditional attach / multiple→picker to choose by number
bash scripts/dev.sh attach <NAME|N>        # Direct attach (N is ls line number)
bash scripts/dev.sh <NAME>                 # Idempotent attach-or-create by explicit name
bash scripts/dev.sh kill <NAME|N>          # Stop dev box (corresponding cdx-<NAME> reviewer pair also destroyed)
bash scripts/dev.sh prune [--yes] [--all]  # Batch cleanup orphan cdx pairs / stale leases / stale locks (no args = dry-run, --all targets dev box itself with CDX=none)
```

When you tell claude in a prompt like `create foo feature for issue #N in stage/02-onepager`, it will auto-run through the PR flow in §3 (details: [CLAUDE.md](CLAUDE.md); you can also ask claude in the box "how do I use this project?").

Advanced usage (parallel boxes / shell inside box / Traefik routing etc) see [docs/parallel.md](docs/parallel.md).

---

## 3. PR Flow (claude auto-runs, participants only decide final merge)

| # | step | skill |
|---|------|-------|
| 1 | Create worktree | (automatic / `git worktree add`) |
| 2 | Implement + consult codex at key points | `/a2a-review` |
| 3 | Convert to PR with `gh pr create` | (gh CLI) |
| 4 | Codex review + CI until merge-ready | `/pr-codex-ci` |
| 5 | Handle GitHub bot review (Copilot / qodo etc) | `/pr-review-respond` |
| 6 | Merge | **User decision** (`gh pr merge --squash --delete-branch` etc) |
| 7 | Worktree cleanup | (automatic / `git worktree remove`) |

Step 4's "merge-ready" (codex + CI clean) is **different from ruleset-based merge eligibility**: step 5 requires handling GitHub PR review and **resolving all threads before actual merge is possible** ([docs/repo-settings.md](docs/repo-settings.md)). Details: [CLAUDE.md](CLAUDE.md) and [rules/pr-followup.md](rules/pr-followup.md).

---

## Structure

The main branch is **for lecture progression** and doesn't contain the project code itself. The actual project lives in `stage/*` branches (orphan lineage, not sharing history with main) and is expanded under `.worktrees/` using `git worktree`.

```text
coding-agent-playbook/   # main: lecture progression (CLAUDE.md / explanations / scripts)
  sbx/                   # Custom image (claude/codex/chrome) + codex egress mixin
  tools/                 # Development tools (driven from host)
    a2a-review/          # Make codex a separate box A2A reviewer (underlying /a2a-review skill)
    parallel-dev/        # Parallel development distinguishing multiple boxes by name (Traefik)
  .claude/skills/        # Claude skills bundled with project
  slides/                # Lecture slides by phase (single HTML, 5 slides)
  scripts/               # Host scripts participants run daily (dev / build-image / check-setup) — sandbox / shell / route are dev subcommands
    internal/            # Host scripts called internally by agent / skill / setup (participants don't touch directly)
  docs/                  # Details extracted from README (setup / parallel / instructor etc)
  rules/                 # Development flow norms (box-ops / worktrees / pr-followup / skills)
  .worktrees/            # Worktrees for stage/* branches (outside git management)
    01-blank/            # = stage/01-blank branch (starting point for exploration, empty)
    02-onepager/         # = stage/02-onepager branch (project itself)
    ...
```

All worktrees share the same `.git`, so commits/fetches anywhere are immediately reflected across all worktrees.

---

## Detailed Reference

| Topic | Location |
|---|---|
| Initial setup details (PAT permissions / cdx-`<NAME>` pair reviewer operation / updates) | [docs/setup.md](docs/setup.md) |
| Parallel development (parallel dev boxes / sandbox boxes / shell / Traefik routing) | [docs/parallel.md](docs/parallel.md) |
| Full development flow (box-primary, PR lifecycle) | [CLAUDE.md](CLAUDE.md) |
| Box / image / authentication / gotchas | [sbx/README.md](sbx/README.md) |
| Codex A2A review internals | [tools/a2a-review/README.md](tools/a2a-review/README.md) / [.claude/skills/a2a-review/SKILL.md](.claude/skills/a2a-review/SKILL.md) |
| Traefik configuration details | [tools/parallel-dev/box-routing/README.md](tools/parallel-dev/box-routing/README.md) |
| Box ops norms | [rules/box-ops.md](rules/box-ops.md) |
| Worktree norms | [rules/worktrees.md](rules/worktrees.md) |
| PR flow norms | [rules/pr-followup.md](rules/pr-followup.md) |
| Skill layers | [rules/skills.md](rules/skills.md) |
| HOTL monitoring (viewing inside box from host) | [.claude/skills/box-session-context/SKILL.md](.claude/skills/box-session-context/SKILL.md) |
| GitHub ruleset / merge gate | [docs/repo-settings.md](docs/repo-settings.md) |
| Design decisions adopted (ADR) | [docs/decisions/](docs/decisions/) |
| For lecture organizers (new stages / slides / stage checkpoint chains) | [docs/instructor.md](docs/instructor.md) |
