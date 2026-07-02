# CLAUDE.md

A workshop repository. For overview and operations model, see [README.md](README.md). This file defines the **high-level principles and development flow** for when coding agents work, delegating details to `rules/` ([rules/box-ops.md](rules/box-ops.md) / [rules/box-personas.md](rules/box-personas.md) / [rules/worktrees.md](rules/worktrees.md) / [rules/pr-followup.md](rules/pr-followup.md) / [rules/skills.md](rules/skills.md)).

## Workshop Assumption (configuration bundled in project, run on host)

This repository is **workshop material**. It does **not depend on participants' personal global settings (MCP registration in user-level `~/.claude`, dotfiles, personal settings, etc.)**. All required configuration is **committed in the project** so participants just need to clone the repo and everything is ready.

**Execution model (box-primary)**: Fundamentally **run claude / codex inside boxes (sbx = Docker Sandboxes)** (YOLO/isolated. Host both agents equally in a neutral shell-docker base for mutual review). HOTL operations with approval gates removed and parallel execution at hypervisor boundaries with microVM-per-agent is the assumption. Only exit to host when host privileges are needed. **Separate personas by privilege tier for boxes** (dev box=write / observe box=AWS read-only / host=deploy. Don't mix) → [rules/box-personas.md](rules/box-personas.md).

- **Box launch / secret registration / parallel / host escape hatch procedures in [rules/box-ops.md](rules/box-ops.md)**. Key points: build/load image once + register secrets → launch with bind-mount via `sbx run claude -t coding-agent-playbook-sbx --kit ./sbx/playbook-kit .` (parallel via `sbx create --name <box> ... --clone .`). Exit to host only for browser verification / docker operations / when host privileges needed.
- **Place in project (committed)**: `.mcp.json` (chrome-devtools MCP. host=headful / box=headless auto-switch), `sbx/` (custom image + codex egress mixin) / `scripts/` (host helpers) / `tools/` (development tools: a2a-review / parallel-dev) / `.claude/skills/` (Claude skills bundled with project: a2a-review / codex-review / pr-codex-ci / pr-ci / pr-review-respond / box-session-context / box-session-resume / box-session-resume-grant / host-ask / host-answer) / `.claude/settings.json` (shared settings like statusLine). Settings that vary by person go in `.claude/settings.local.json` (local, not committed).
- **Do not depend on (user/host level)**: Participants' personal global Claude settings / personal MCP registration / personal dotfiles / host-specific manual setup.

When adding anything new, always verify "can participants reproduce this with just a cloned repo?"

## Development Flow (one cycle of box-primary)

Implement inside the box, then after PR creation run codex review + CI to advance **to merge-ready** (merge itself is user judgment. Default is report and stop). See delegated rules / skills for details of each step (box-native, codex-only condensation of host-side PR lifecycle operations).

| # | Step | Details |
|---|------|---------|
| 0 | Environment setup (once per machine): image build/load + sbx login + secret registration | [rules/box-ops.md](rules/box-ops.md) |
| 1 | Launch box: enter box with mounted repo (YOLO) | [rules/box-ops.md](rules/box-ops.md) |
| 2 | Start work: create worktree (without dirtying main checkout) | [rules/worktrees.md](rules/worktrees.md) |
| 3 | Implement + consult codex: `/a2a-review` in box, `/codex-review` on host to get codex's second opinion | [tools/a2a-review/README.md](tools/a2a-review/README.md) |
| 4 | PR → auto-run next steps: right after `gh pr create`, orchestrator runs codex review + CI check + **`/pr-review-respond` chain** auto-advancing to final merge-ready (local gate + remote gate AND). Box session: `/pr-codex-ci` (box-native, via A2A cdx-pair), host session: `/pr-ci` (host-native, direct host codex CLI). **Transport differs but judgment quality is equivalent** | [rules/pr-followup.md](rules/pr-followup.md) / [rules/skills.md](rules/skills.md) |
| 5 | GitHub PR review handling: chain launched at orchestrator step 5, `/pr-review-respond` checks bot reviews (Copilot / qodo etc) → accept/reject → fix/reply → resolve (**distinct from local codex review** but linked in chain) | [.claude/skills/pr-review-respond/SKILL.md](.claude/skills/pr-review-respond/SKILL.md) / [rules/pr-followup.md](rules/pr-followup.md) |
| 6 | Merge: **resolve all review threads** then user judgment (default is report and stop) | See "Commit / PR Operations" below / [docs/repo-settings.md](docs/repo-settings.md) |
| 7 | Cleanup: return CWD to main and `git worktree remove` | [rules/worktrees.md](rules/worktrees.md) |

**Note**: Final merge-ready in step 4 = **local gate (codex + CI clean) + remote gate (all threads resolved + new bot review settled) AND**. The chain is implemented at orchestrator step 5 (`/pr-codex-ci` / `/pr-ci` both) as forced skill-internal invocation of `/pr-review-respond` ([rules/pr-followup.md](rules/pr-followup.md)), with steps 4 → 5 as continuous subsequent processes not stopped mid-way (past accident: misread "local gate clean" as merge-ready and stopped, missing bot review arriving later).

Cross-cutting: HOTL monitoring (statusLine session id → transcript from host) / parallel (1 session per box) / cross-platform (`.sh` + `.ps1` pairs) / **bidirectional box↔host context bridge** (`/box-session-context` = transcript pull host→box, `/box-session-resume` = just paste session_id to inject into host / different box and resume with `claude --resume` (host launch direct execution, box launch delegates via host-bridge to `/box-session-resume-grant`), `/host-ask` ↔ `/host-answer` = active ask box→host, `.claude/host-bridge/` visible to both via bind mount) → each rule ([rules/pr-followup.md](rules/pr-followup.md) / [rules/box-ops.md](rules/box-ops.md) / below).

(`stage/*` is not dev flow but lecture checkpoint mechanism. See "Stage branch conventions" below)

Skills are structured in **abstraction layers** (top = abstract / bottom = concrete): **Flow layer (this section) → orchestrator skill (e.g. `/pr-codex-ci`) → leaf skill (e.g. `/a2a-review`) → scripts/tools**. Orchestrator composes leaves, with CI checks and operational systems also being concrete elements orchestrator runs. See [rules/skills.md](rules/skills.md) for granularity, composition rules, and skill layers.

## Structural Assumptions

- **main branch = lecture progression** (README / CLAUDE.md / rules/ / scripts/ / stages/ / slides/). Does not contain the project code itself.
- **`sbx/` = custom image for entire playbook execution environment + codex egress mixin** (Docker Sandboxes). Built-in claude agent + image (claude/codex bundled) + codex mixin, the microVM foundation to safely host claude / codex in parallel even in YOLO / auto-mode, foundation placed on main. Stages are forks from base, so exist in origin main from the start (details: [sbx/README.md](sbx/README.md))
- **`stage/*` branches = project itself**. Orphan lineage not sharing history with main, deployed as worktrees under `.worktrees/<NN-slug>/` (conventions: see "Stage branch conventions" below. Stages are not dev flow but **lecture checkpoint mechanism**)

## Work Location Rules

- Changes to lecture materials (README / CLAUDE.md / rules/ / scripts/ / slides/) and `sbx/` are made in work worktrees (see "Commit / PR Operations" below). Implementation of the project (demo app) itself is done in stage worktrees, **not placing project code in main checkout**.
- How to create/clean worktrees: [rules/worktrees.md](rules/worktrees.md), stage conventions and deployment: see "Stage branch conventions" below.

## Commit / PR Operations

- **Changes go through PRs**. Cut worktree → implement → push → create PR → review / CI check → merge (owner-led workshop repo but keeping changes and reviews as PRs). No direct commits/pushes to main. How to cut worktree: [rules/worktrees.md](rules/worktrees.md) (**don't change main checkout branch with `git checkout -b`**).
- Changes to lecture foundation (README / CLAUDE.md / rules/ / scripts/ / slides/ / `sbx/` etc) also go through PRs. Changes to stage (project itself) also use corresponding branch's PR.
- Since it's a publicly exposed repo, don't include real environment identifiers (real emails, customer names, tokens etc) in commits / pushes / PR bodies.
- **Seamless flow from implementation done to PR follow-up without intermediate confirmation**: Once editing is done, proceed through the following chain **continuously without waiting for confirmation** (specific realization of global Autonomy / proceed-first in this repo). Don't stop at **offering options** like "Create PR?" / "What next?" / "Run `/pr-codex-ci`?" / "Continue?" (only stopping points are merge, HOTL escalate for unrunnable situations, and user-explicitly-specified stopping points. If user says "stop after commit" or "don't push" etc explicitly, follow that).
    1. **Inside worktree**, once implementation is done: `git add -A` (or explicit pathspec to stage target files) → `git commit -m "<subject>"` (worktree-first is assumed. Details: [rules/worktrees.md](rules/worktrees.md). Bare `git add` does nothing without pathspec, so always pass `-A` or pathspec. `git commit` without `-m` / `-F` opens editor and hangs interactively. If accidentally edited in main checkout: **(a)** verify dirty changes in main checkout are **solely from agent's current work** (if user's WIP included, don't retreat—HOTL escalate) → **(b)** `git stash push -u -- <pathspec-to-fix...>` (when passing pathspec, `push` subcommand is required. Shorthand `git stash -u <pathspec>` fails with "subcommand wasn't specified". If confirmed no non-agent work, can do whole `git stash push -u` without pathspec) → **(c)** `git worktree add --relative-paths <worktree-path> -b <branch> <base-branch>` (**explicitly include `--relative-paths` + `<base-branch>`**. This repo assumes relative links. git 2.48+. Omitting `<base-branch>` branches from current HEAD = main, breaking base in stage PRs) → **(d)** `git -C <worktree-path> stash pop` then commit in worktree. `git stash pop` expands relative to cwd, so explicitly use `git -C <worktree-path>` to avoid re-dirtying main checkout. `git worktree add` itself doesn't move uncommitted changes)
    2. `git push -u origin <branch>`
    2.5. **pre-PR sweep**: `/comment-sweep` sweeps newly added comments per [rules/code-comments.md](rules/code-comments.md) norms. If violations exist, after user approval: Edit to fix and add commit → `git push` once. `/co-evolve-check` / `/extension-bloat-sweep` only run on projects with TS/JS / Python marker files (main checkout with no marker silently skips). Details: [rules/pr-followup.md](rules/pr-followup.md) step 1.
    3. `gh pr create --base <base-branch> --title "<subject>" --body "$(cat <<'EOF' ... EOF)"` (**`--title` / `--body` required**. Omitting opens editor / prompts and hangs. `--base` also explicit (omitting selects default branch, causing accidents like stage worktree PR going to `main`. In this repo, PRs from stage worktrees base on the preceding stage). If issue-linked: `Closes #N`, PR Body footer required)
    4. Invoke orchestrator: **box session**: `/pr-codex-ci <PR-number>` (codex + CI gate + bot review chain via A2A), **host session**: `/pr-ci <PR-number>` (direct host codex CLI + CI gate + bot review chain). Both internally launch `/pr-review-respond` chain at step 5, auto-running until both local gate + remote gate are clean.
    5. Receive orchestrator's final merge-ready report (local gate clean + all threads resolved + new bot reviews settled), **report final status to user and stop**. Merge execution is user judgment (run `gh pr merge` only if explicitly instructed).
- **If auto-run is impossible, don't silently stop—HOTL escalate**: If **auto-run can't continue** because `/pr-codex-ci` → `/a2a-review` can't reach reviewer (cdx-`<box-name>` pair not stood up in dev.sh bg pair-serve etc), CI pending long, codex findings can't be fixed, conflicts can't auto-resolve, etc., don't offer options—instead **clarify what happened + necessary human operations + restart command and stop**. Example: "`/a2a-review` can't reach cdx-`<box-name>` reviewer. Recovery order: (1) in box terminal, Ctrl-D / `exit` claude and dev.sh trap cleans up → (2) on host restart `bash scripts/dev.sh <box-name>` → (3) re-run `/pr-codex-ci <PR-number>`. If box hangs and can't exit, on host `sbx rm -f <box-name>` → (2) (state lost)." (before escalating, replace `<box-name>` placeholder with literal value from `echo $SANDBOX_VM_ID` in box. Host shell has no `$SANDBOX_VM_ID` env, empty expansion might become different session. **calling same-named dev.sh on host while active dev session holds lock gets rejected on active-lock detection, so must exit dev.sh in box first**)
- **All review threads must be resolved before merging**: Bot reviews / comments from Copilot / qodo etc require handling + reply + thread resolve—can't merge without all (GitHub ruleset `required_review_thread_resolution` enforces mechanically. Details: [docs/repo-settings.md](docs/repo-settings.md)). This is handled by independent skill `/pr-review-respond` (read → accept/reject → fix/reply → resolve), **chain launched at orchestrator step 5 internally** (`/pr-codex-ci` / `/pr-ci`) (norm-based chains had accidents misreading "local gate clean = merge-ready", so consolidated as forced skill-internal chain). **Distinct from orchestrator's local codex review** (active second opinion agent calls)—don't confuse. Merge is user judgment, but all thread resolution is prerequisite.

## Stage Branch Conventions (lecture checkpoint mechanism)

`stage/*` is a teaching device ("instant access to 'where we're at in the lecture'", 3-minute-cooking style), distinct from the development flow above (box → worktree → PR → merge). The project (demo app) itself lives in this orphan lineage.

- Always create new stages with `scripts/internal/new-stage.sh` / `scripts/internal/new-stage.ps1` (first stage is orphan, subsequent ones branch from prior stage). Don't substitute with raw `git worktree add` or `git checkout --orphan`.
- Don't mix lecture-progression files (README.md / CLAUDE.md / rules/ / scripts/ / stages/ / slides/) into stage branches (maintains orphan separation).
- In stage project docs (project's own README etc) and **code comments**, write **only how to run the project (demo app)**. Don't duplicate playbook host operations (box→host viewing path = `dev.sh route` / Traefik etc, commands assuming main's `scripts/`). Drift hides not just in docs but in `.ts` etc comments, so checking isn't limited to `*.md`. Stages are frozen orphans not sharing history with main—duplicated procedures can't follow main's evolution (e.g. `parallel.sh` → `dev.sh route`), creating **drift** (drift can't be fixed by merge/rebase: no shared files/history). Playbook concerns common to all stages (like box→host viewing steps) belong in main as single source. Project parts propagate via fork chains from prior stages to next stage (`new-stage.sh <new> <prev>`)
- Naming: branches are `stage/NN-<slug>`, worktrees are `.worktrees/<NN-slug>/`
- Delete worktrees with `git worktree remove` (manual rm leaves stale registry). Right after cloning, before expansion, use `bash scripts/internal/setup-worktrees.sh` (Windows: `scripts/internal/setup-worktrees.ps1`) to expand existing `stage/*` under `.worktrees/`.
- **Stages are frozen checkpoints with no sync mechanism (intentional absence)**. (a) Don't rebase/merge main into stages (different axis. Preventing main-side asset drift is "don't duplicate, single-source on main"—not by syncing. See previous point). (b) No auto-sync between stages. Forward propagation is **only at creation time fork chain** from `new-stage.sh <new> <prev>`, no retroactive mechanism to fix upstream stages and push downstream. Always/auto sync would turn checkpoints into moving targets, breaking 3-minute-cooking reproducibility. If retroactive propagation becomes real pain, add **explicit restack helper at work time** (not CI-resident) — adjacent stages share history via fork chain so `git rebase --onto` can restack.

## Cross-platform Requirements

Scripts must work on macOS / Linux / Git Bash (Windows) / Windows PowerShell 5.1:

- **Maintain bash version (`*.sh`) and PowerShell version (`*.ps1`) as pairs**. Don't create behavior differences with single-sided changes.
- Exception: single implementations required across all OS (e.g. statusLine's `scripts/internal/statusline.js`) use `node` alone. `node` is a prerequisite for claude CLI, guaranteed present on all OS (host/box), and single committed command covers all OS/shells. These don't have `.sh`/`.ps1` pairs (lack of pair is correct, not omission).
- Another exception: **ephemeral verification artifacts** (one-time use, serve purpose once, then done. E.g. `examples/*/spike/` ADR gate harnesses) can limit run environment (e.g. mac/Linux host with credentials only), with no pair—single shell implementation (`*.sh` only etc) is fine. Doesn't apply to **permanent tooling** participants run daily (`scripts/` like `dev.sh` / `new-stage.sh` etc). If choosing no pair, explicitly mark artifact README/comments: "ephemeral hence no pair needed (distinct scoped judgment from `node` exception, not omission)" and guide Windows users to run `*.sh` via Git Bash / WSL.
- `*.sh` must have LF line endings (enforced in `.gitattributes`)
- `*.ps1` must be ASCII only (Windows PowerShell 5.1 reads BOM-less files as ANSI)
- Required version: git **2.48+** (uses `git worktree add --relative-paths`. Worktree `.git` becomes relative path so worktree git works even when repo is mounted on different paths like sbx boxes = `git -C .worktrees/<NN>` works inside boxes too)

## Slides

Lecture slides are placed in `slides/<NN-slug>.html` on main **by phase** (5 slides: brainstorm / design / implementation / finalization(parallel issue handling) / operations & bug fixes. Slides correspond to phases not states, so don't match stage checkpoint count. They're lecture material, so don't go in stage branches). Details: [docs/instructor.md](docs/instructor.md) "Slides" "Stages (checkpoint chains)".

- Single self-contained HTML reading reveal.js from CDN. Content is markdown bullet points in `<textarea>` separated by `---`.
- Read CDN at fixed version + SRI (`integrity`). When upgrading reveal.js version, recalculate `integrity` hash (mismatch causes browser to block resource and fail silently).
- New creation: copy `slides/template.html` and fill content (don't touch HTML template, edit only markdown).
- Slide content (bullet points) are written by humans. Agent maintains template `slides/template.html` and doesn't fill in each phase's content.
