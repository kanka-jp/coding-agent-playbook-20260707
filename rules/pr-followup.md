# PR Follow-up Flow (codex review + CI after PR creation)

After creating a PR, without waiting for user confirmation, run **orchestrator skill** to advance codex review + CI gate to merge-ready. In box-primary operations, don't stop at "PR created" as intermediate result; keep all post-processing in one continuous stream. Detailed version of the PR post-creation rules from [CLAUDE.md](../CLAUDE.md) "Commit / PR Operations."

Two orchestrator channels by execution environment:

- **box session** (inside dev box from `bash scripts/dev.sh`) → **`/pr-codex-ci`** (calls codex of cdx-`<NAME>` pair via A2A. Composes `/a2a-review` leaf)
- **host session** (no dev box, host claude creates PR directly) → **`/pr-ci`** (directly exec host-installed `codex` CLI. Composes `/codex-review` leaf)

The two differ only in **transport**; judgment quality (codex second opinion + CI gate + bot review chain) is equivalent. CI gate + bot review chain (compose `/pr-review-respond` leaf) is shared by both orchestrators.

## When it Fires

This chain **auto-fires at 2 boundaries without asking for confirmation** (instantiation of CLAUDE.md "Commit / PR Operations" autonomy rule):

1. **Boundary when editing is done (pre-PR)**: When implementation / docs editing is complete, do NOT ask the user "Should I create a PR?" — instead, continuously execute the following in the worktree: `git add -A` (or explicit pathspec to stage target files) → `git commit -m "<subject>"` (omitting `-m` / `-F` opens an editor and hangs interactively) → `git push -u origin <branch>` (the `-u` flag is required; new branches have no upstream set, so bare `git push` fails under `push.default=simple`) → **pre-PR sweep** (run `/comment-sweep` to check newly added comments against [rules/code-comments.md](code-comments.md) norms; if violations exist, after user approval fix them with Edit and amend / create a new commit → run `git push` once. `/co-evolve-check` / `/extension-bloat-sweep` only run if the project has TS/JS / Python marker files, otherwise silently skip, so **it's safe to run all three in parallel by default**. This main checkout has no marker files, so the latter two skip immediately.) → `gh pr create --base <base-branch> --title "<subject>" --body "<body + footer from CLAUDE.md 'PR Body Footer' section required at end>"` (both `--title` and `--body` are required; omitting them opens an interactive prompt and hangs, and the PR Body footer may be missing. `--base` also must be explicit; omitting it targets the default branch, which causes accidents like stage worktree PRs going to `main`. The `--body` footer MUST include the footer format from CLAUDE.md's "PR Body Footer" section). Execute these continuously (worktree-first is assumed. Details: [worktrees.md](worktrees.md). Bare `git add` does nothing without a pathspec, so always pass `-A` or pathspec. If you accidentally edited in the main checkout: **(a)** verify that all dirty changes in the main checkout are **solely from the agent's current work** (if user's WIP is included, do not retreat — HOTL escalate) → **(b)** `git stash push -u -- <pathspec-to-fix...>` (when passing pathspec, the `push` subcommand is required; the shorthand `git stash -u <pathspec>` fails. If you confirm no non-agent work, bare `git stash push -u` without pathspec is okay) → **(c)** `git worktree add --relative-paths <worktree-path> -b <branch> <base-branch>` (explicitly include `--relative-paths` + `<base-branch>`. This repo assumes relative links. Omitting `<base-branch>` branches from the current HEAD = main, breaking the base in stage PRs.) → **(d)** `git -C <worktree-path> stash pop` then commit in the worktree. `git stash pop` expands relative to cwd, so use `git -C <worktree-path>` to avoid re-dirtying the main checkout. `git worktree add` itself does not move uncommitted changes).
2. **Boundary at PR creation (post-PR)**: Immediately after `gh pr create`, launch the orchestrator without asking for confirmation. **For box sessions: `/pr-codex-ci <PR-number>`; for host sessions: `/pr-ci <PR-number>`** (see the opening "orchestrator operates in 2 channels by execution environment" for the decision axis). **Both internally invoke `/pr-review-respond <PR-number>` as a chain at step 5**, running autonomously until both local gate (codex + CI clean) and remote gate (all threads resolved + new bot review settled) are satisfied. **Invocations are unidirectional: orchestrator → leaf**: the orchestrator ([../.claude/skills/pr-codex-ci/SKILL.md](../.claude/skills/pr-codex-ci/SKILL.md) / [../.claude/skills/pr-ci/SKILL.md](../.claude/skills/pr-ci/SKILL.md)) step 5 calls `/pr-review-respond`, and `/pr-review-respond` ([../.claude/skills/pr-review-respond/SKILL.md](../.claude/skills/pr-review-respond/SKILL.md)) returns a structured result and exits (does not call back the orchestrator; cycle-prevention norm [skills.md](skills.md)). If `pushed_changes: true`, the orchestrator is responsible for re-evaluating from step 1. **Do NOT stop at intermediate milestones like "PR created" or "local gate clean"**. Return the final merge-ready report to the user only when both local and remote gates are clean (a prior accident: misread "codex + CI clean" as merge-ready and stopped, missing a bot review that arrived later).

The only other stopping point besides "user decides to merge" is HOTL escalation for **situations where autonomous execution cannot continue** (reviewer unreachable / CI failure unfixable / conflict auto-resolution impossible, etc.) (see "HOTL escalation when autonomous execution is impossible" below).

### Prohibited confirmation prompt types (do not stop for intermediate gates)

It is a **norm violation** for the agent to stop by presenting options or asking confirmation questions like the following. When these occur to you, proceed first with the best option (global Autonomy / proceed-first):

- "Should I create a PR? / Should I make this a PR?"
- "What should be the next step?"
- "Should I run `/pr-codex-ci` (or `/pr-ci`) now?"
- "Which option: ① run codex review ② stop with just the PR ③ ...?"
- "Should I proceed as-is?"
- "Should I commit + push?" (pushing for PR creation is within autonomy scope)
- "Should I launch a box?" (if already running a host session, just run `/pr-ci`; box launch is unnecessary)

Exception: If the user explicitly declares a scope like "don't create a PR" or "stop after commit only", follow that. Do not execute merge (`gh pr merge`) without user instructions (stopping at merge-ready report is the default).

### Prohibited self-judgment (do not skip the orchestrator)

Do **not** have the agent-side pre-judge and skip the orchestrator (`/pr-codex-ci` / `/pr-ci`) by determining reviewer absence or CI absence before launch. Reviewer health confirmation is **centralized in the orchestrator's preflight (lease check / reachability confirmation at actual invocation)**, so probing beforehand by the agent only seeds mis-judgment and misses the legitimate escalation path. **Always go through "PR creation → launch orchestrator without confirmation"**.

Specifically, the following are treated as norm violations:

- **Running `ps aux` (or `pgrep`, etc.) inside the current box to find no reviewer process → declaring it down → proposing skip**: The cdx-`<NAME>` reviewer runs in a **different sbx microVM**, so it **fundamentally does not appear** in the current box's PID namespace (output of "none found" is expected and unrelated to reviewer status). Reviewer status can only be determined via **the lease file (`.claude/tmp/cdx-serve-<NAME>.lease`) + agent-card probe to the advertise URL**, which is done by `/pr-codex-ci` steps 1a + 2. **Using `ps aux` as a proxy for reviewer health is itself an error**.
- **Justifying skip by cost-asymmetry framing like "reviewer recovery loses session" or "the change is minor so it's disproportionate"**: Skip eligibility is determined **only by the orchestrator's preflight result + HOTL escalate message**. Don't short-circuit the autonomous chain based on agent-side cost speculation (a breeding ground for motivated reasoning).
- **Looking at `ls .github/workflows/` and finding no CI workflow, so unilaterally deciding to skip the CI gate**: CI gate skip eligibility is determined by orchestrator step 3 (confirming 0 actual checks via `gh pr checks`). Don't decide based solely on file list presence/absence.

The flow "agent self-judges and skips → present user with 'proceed as-is / run / cancel' options → stop" is treated as the **same norm violation** as the "prohibited confirmation prompt types" `① ... ② ...` above (intermediate stop disguised by form or content).

Exception: Following a HOTL escalate message **output by the orchestrator itself** (detected by preflight as lease missing, etc., in the form of "HOTL escalation when autonomous execution is impossible" below) is the legitimate path. The escalate message itself is skill output, not agent judgment, so it differs from agent self-judgment skip.

## HOTL escalation when autonomous execution is impossible

When the orchestrator chain (`/pr-codex-ci` / `/pr-ci`) encounters a **situation where autonomous execution cannot continue**, the agent must NOT present options; instead, **clearly state what happened + what humans need to do + restart command** in 1-2 lines and stop. "Silent failure" or "what should I do next?" prompts are prohibited.

Representative cases and escalation message forms:

| Situation | Escalation message form |
|------|------------------------|
| Inside box, `/a2a-review` cannot reach cdx-`<NAME>` pair | "`/a2a-review` cannot reach cdx-`<box-name>` reviewer. Recovery steps: (1) Exit claude in box terminal with Ctrl-D / `exit`; dev.sh trap cleans up cdx-pair + lock → (2) Restart `bash scripts/dev.sh <box-name>` on host (new lock + pair-serve re-fork) → (3) Re-run `/pr-codex-ci <PR-number>`. If box hangs and you cannot exit, run `sbx rm -f <box-name>` on host → (2) (state is lost). To debug, check host's `.claude/tmp/cdx-serve-<box-name>.log` (pair-serve output)." (replace `<box-name>` with the literal output of `echo $SANDBOX_VM_ID` inside the box) |
| On host, `cdx-<NAME>` pair is not auto-provisioned | "cdx-`<box-name>` reviewer box not created. Possible cause: openai secret not registered. Recovery: (1) Run `sbx secret set -g openai --oauth` on host, (2) Exit dev.sh in box with Ctrl-D / `exit`, (3) Restart `bash scripts/dev.sh <box-name>` on host (dev.sh runs pair-setup + pair-serve). Then re-run `/pr-codex-ci <PR-number>`." (replace `<box-name>` with the literal output of `echo $SANDBOX_VM_ID` inside the box) |
| On host, `/codex-review` finds no codex CLI installed / authenticated | "`codex` CLI not found on host or `codex login` not done. Recovery: (1) Install with `npm i -g @openai/codex` → (2) Authenticate with `codex login` for your OpenAI subscription → (3) Re-run `/pr-ci <PR-number>`. Or switch to a box session and use `/pr-codex-ci` (box-native) with `bash scripts/dev.sh <NAME>`." |
| CI repeatedly fails in the same run (same symptom after fix) | "CI check `<check-name>` still fails after fix for the same reason (<summary>). Manual review needed. Failure log: <URL>." |
| CI run shows no status change for 30+ minutes (`pending` or `in_progress` with no step log update) | "CI run `<id>` has been `<elapsed-minutes>` in `<pending or in_progress>` with no progress. Possible causes: manual approval needed / queue hang / runner shortage / execution hang. Check manually with `gh run view <id> --web`. After fixing the issue, re-run the orchestrator (`/pr-codex-ci` or `/pr-ci`)." |
| Auto-resolution of conflicts impossible | "Rebase to `<base>` has conflicts in <files>. Attempted auto-resolution but semantic judgment required. Resolve manually in `.worktrees/<branch>/`, then re-run the orchestrator (`/pr-codex-ci` or `/pr-ci`)." |

## Flow (what the orchestrator does)

The box-native `/pr-codex-ci` skill ([.claude/skills/pr-codex-ci/SKILL.md](../.claude/skills/pr-codex-ci/SKILL.md)) / host-native `/pr-ci` skill ([.claude/skills/pr-ci/SKILL.md](../.claude/skills/pr-ci/SKILL.md)) loop through the following until final merge-ready (**final merge-ready = local gate AND remote gate**):

1. **local: codex review** — delegated to leaves. **On box, `/pr-codex-ci`** calls `/a2a-review` (sends to cdx-pair codex in another sbx microVM via A2A), **on host, `/pr-ci`** calls `/codex-review` (exec the host-installed `codex` CLI directly). Both have the same role of obtaining codex's second opinion; only the transport differs.
2. **local: CI gate** — verify CI with `gh pr checks` (assumes GitHub Actions).
3. **local fix loop** — if there are codex findings to adopt or CI failures, fix → push → re-evaluate. Once these are clean, **local gate clean** (do not stop here; continue to step 4).
4. **remote: GitHub bot review gate** — compose and invoke leaf `/pr-review-respond`. `/pr-review-respond` fetches bot reviews (Copilot / chatgpt-codex-connector / qodo, etc.) → decides accept/reject → replies + resolves → returns structured result (`pushed_changes` / `resolved_count` / `final_unresolved` / `checks_terminal`). **If `pushed_changes: true`, re-evaluate from step 1 with new head** / **if `pushed_changes: false` + `final_unresolved: 0`, re-check CI gate after return, confirm green, then remote gate clean** → final merge-ready report (leaf does not judge CI green, so caller re-checks).

Both orchestrators use a single codex for local review (workshop box has no other AI CLIs, so codex-only; host also requires no other CLIs—codex-only plan). **`/pr-review-respond` is a leaf that does not call back the orchestrator** ([skills.md](skills.md)); the upper orchestrator composes both (cycle prevention).

## Prerequisites

**When using `/pr-codex-ci` in a box session**:
- **cdx-`<NAME>` pair reviewer is auto-provisioned by dev.sh**: When you run `bash scripts/dev.sh` (auto-name) or `bash scripts/dev.sh <NAME>` (explicit name), dev.sh auto-provisions the matching cdx-`<NAME>` reviewer box and bg-forks pair-serve (auto-teardown via trap when claude box TTY exits; per-pair lifecycle, decision 2026-06-27). No need to manually start the server. If openai secret is not registered / setup fails, it fails gracefully (claude box starts but `/a2a-review` is unavailable); `/pr-codex-ci` → `/a2a-review` will direct to "restart dev.sh" and stop (graceful degrade).
- `gh` is available (box uses proxy auth).
- For codex box / openai OAuth secret setup, see [tools/a2a-review/README.md](../tools/a2a-review/README.md).

**When using `/pr-ci` in a host session**:
- **host has `codex` CLI installed and `codex login` completed**: Install with `npm i -g @openai/codex` → authenticate OpenAI subscription with `codex login`. Same codex CLI on host as in box (workshop's codex config is symmetric across box / host; users choose based on use case).
- `gh` works on host (`gh auth login` completed).
- Box startup is not required (host claude completes via `/pr-ci`). You can create a PR without launching a box and run `/pr-ci` on the host to complete codex second opinion + CI gate + bot review chain all-in-one.


## Default: report and stop without merging (responsibility boundaries)

**Responsibility boundary clarification**:

- **orchestrator SKILL (`/pr-codex-ci` / `/pr-ci`)** runs the local gate (codex review + CI); when local gate is clean, **invokes leaf `/pr-review-respond` as a subordinate at skill-internal step 5** to advance to the remote gate (all threads resolved + new bot review settled). **Final merge-ready report = both local + remote gates clean**; the skill exits at that point (merge execution is user judgment, not automatic).
- **`/pr-review-respond` SKILL as a leaf** handles the actual logic of fetching GitHub bot review threads → deciding accept/reject → replying + resolving, **returns a structured result (`pushed_changes` / `resolved_count` / `final_unresolved` / `checks_terminal`) to the caller and exits** (does not call back the orchestrator to avoid cycles; [skills.md](skills.md)). When code changes are pushed, the caller orchestrator (`/pr-codex-ci` or `/pr-ci`) is responsible for re-evaluating codex/CI from its step 1 upon seeing `pushed_changes: true`.
- **Chain-wide stopping points are**:
    - Local + remote gates both clean = orchestrator's final merge-ready report
    - Autonomous execution impossible = stop in the form of "HOTL escalation when autonomous execution is impossible" section (includes `/pr-review-respond` unable to decide/fix, plus CI hangs where checks don't reach terminal state)

Merge is gated by GitHub ruleset: **you cannot merge until all PR review threads (from Copilot/qodo, etc.) are resolved** (`required_review_thread_resolution`; config details at [docs/repo-settings.md](../docs/repo-settings.md)). **The orchestrator (`/pr-codex-ci` / `/pr-ci`) and `/pr-review-respond` are separate skills with different responsibilities** — the former is active codex second opinion invoked by claude (transport is box A2A or host CLI), the latter is confirmation + accept/reject + resolve of reviews attached to the PR by others. We maintain responsibility separation while composing the chain via forced skill-internal invocation at orchestrator step 5 (norm-based chains had accidents where "local gate clean" was misread as "merge-ready" and stopped, so we give the skill itself chain responsibility).

## Why norms (CLAUDE.md + this rule + skills) rather than hooks?

While a PostToolUse hook could auto-trigger on PR creation, this repository adopts the approach of **having the norm from CLAUDE.md / this rule invoke the skill**. The norm is read as an active trigger point; the agent calls `/pr-codex-ci`. There is no hook machinery dependency (no hook wiring in settings.json / hook script proliferation; behavior is consolidated in norms for readability). Since the box is YOLO (no approval gates), norms allow us to proceed directly to subsequent steps.

## HOTL monitoring (viewing box work from host)

Box claude outputs `[box-name] <session-id>` (+ cdx pair liveness) on statusLine's first line and `model · branch · context usage % · cost` on the second ([.claude/settings.json](../.claude/settings.json) + [scripts/internal/statusline.js](../scripts/internal/statusline.js)). The `<session-id>` (full session ID) is the box-internal transcript filename (`<id>.jsonl`), so from the host you can:

```bash
sbx exec <box> sh -lc 'cat ~/.claude/projects/*/<id>.jsonl'
```

to follow what box claude is doing (PR creation / `/pr-codex-ci` progress / responding to codex findings). For live follow, use `tail -f`.

## Limitations

- **`/pr-codex-ci` (box-native) assumes per-pair lifecycle**: box-internal use requires host-side dev.sh to bg-fork pair-serve. It does not complete entirely within the box (OAuth codex is in another box, so crosses A2A).
- **`/pr-ci` (host-native) requires host codex CLI**: adds 1 setup step for workshop participants' host environment (`npm i -g @openai/codex` + `codex login`). The codex CLI itself is also installed on the box side; host uses the same CLI. If you don't want to install codex on the host, you can use `/pr-codex-ci` in a box session (either one completes the flow).
- **Norms, not enforcement**: assumes the agent follows norms. YOLO + explicit norms make it effectively automatic, but it's not deterministic hook enforcement.
- **Fully host-driven automation** (detecting PRs from outside the box and running everything) is in the Agent Gateway design domain ([docs/decisions/decomposed-multiagent-a2a.md](../docs/decisions/decomposed-multiagent-a2a.md)); this flow stays within **autonomous execution per session** (the chain does not start unless skill invocation runs in either a box session or host session).

## Background

Host-side personal operations have a norm of "after PR creation, proceed directly to review + CI monitoring," but that belongs to personal global config (dotfiles) and doesn't reproduce across teams / other environments. Since this repository is workshop material bundled with the project for "clone and go," we transplanted the same mindset to **project-committed norms (this rule) + project-scoped skills (box-native `/pr-codex-ci` + host-native `/pr-ci`) + codex-only review (`/a2a-review` for box / `/codex-review` for host)**. To support the use case where a host session creates a PR and wants to proceed directly to merge-ready via `/pr-ci` without launching a box (typical when host claude creates a PR from a conversational task), we added `/pr-ci` as the symmetric counterpart to box-native `/pr-codex-ci`.
