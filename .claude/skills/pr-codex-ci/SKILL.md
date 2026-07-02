---
name: pr-codex-ci
description: "Runs the post-PR pipeline: gets a codex (OpenAI) second-opinion review of the PR diff by composing the /a2a-review skill, applies a CI gate, and loops fixing codex findings and CI failures until the PR is review-clean and CI is green (or no CI configured). The box-native, codex-only post-PR follow-up (the in-box counterpart to host-side multi-AI review). Use after creating a PR, when the user asks to review a PR with codex and watch CI, or mentions PR review + CI / show PR to codex / post-PR handling. Orchestrates /a2a-review + gh pr checks; the per-box codex reviewer (cdx-<NAME>) must already be running (auto-provisioned by dev.sh)."
---

# pr-codex-ci

Box-native post-PR pipeline of **codex review + CI gate**. **Delegates codex invocation to `/a2a-review` skill** (consolidates A2A entry to single point, leaves reviewer reachability to `/a2a-review` side) and this skill **focuses on CI gate + fix loop orchestration**. Box has no other AI CLI, so second opinion from 1 codex.

## Autonomy (trigger and proceed without intermediate confirmation)

This skill **is invoked immediately after `gh pr create` without requesting confirmation** (see [../../../rules/pr-followup.md](../../../rules/pr-followup.md) "When to trigger"). After skill startup, **don't stop at offering choices** like "continue?", "adopt codex findings?", "re-push?". Adoption decision is auto-determined by this skill's judgment criteria (adopt only correctness / security / regression / existing contract violations).

Stop explicitly only for:
- **Final merge-ready report** (local gate: zero codex findings to adopt + CI green or unset / remote gate: all threads resolved + new review settled both AND) — return status to user and stop. Merge execution is user judgment (`gh pr merge` only on explicit instruction). **Don't stop at just local gate clean** (step 5 checks remote gate after).
- **HOTL escalate** (unsolvable situation) — reviewer unreachable / CI failure unfixable / conflict auto-resolve impossible / `/pr-review-respond` adjudication/fix impossible etc (check terminal hang during `/pr-review-respond` execution is escalated in `/pr-review-respond` leaf-side 30-min bound, not here in step 3, since caller is blocked waiting for leaf return). **Clearly state what happened + necessary human action + restart command in 1-2 lines** (message form: see [../../../rules/pr-followup.md](../../../rules/pr-followup.md) "HOTL escalate when unsolvable"). Prohibit "silently stuck" or "what's next?"

### Do not manually probe reviewer health before invoking this skill

Reviewer health confirmation is **centralized in this skill's step 1a (lease check) + step 2 (reachability confirmation at actual invocation)**. It's a **norm violation** for the agent to probe processes inside its own box via `ps aux | grep cdx` / `pgrep`, etc. before invoking this skill and judge "reviewer down" (see [../../../rules/pr-followup.md](../../../rules/pr-followup.md) "Prohibited self-judgment"). The cdx-`<NAME>` reviewer runs in a **different sbx microVM**, so it **fundamentally does not appear** in the current box's PID namespace; `ps aux` is not even a valid proxy for reviewer health in principle. Launch this skill immediately after `gh pr create` without confirmation, and delegate reviewer health judgment to step 1a's lease check.

## Prerequisites

- This skill assumed to run **inside dev box (`bash scripts/dev.sh` launch bind-mount box)**. dev.sh at startup auto-provisions cdx-`$SANDBOX_VM_ID` reviewer box + bg-forks pair-serve, injects advertise URL into box env (`$A2A_CODEX_URL`) (per-pair lifecycle). `/a2a-review` sees env to reach codex
- If `/a2a-review` returns reviewer-unreachable error, this skill HOTL escalates and stops (pass through `/a2a-review`'s HOTL message as-is)
- `gh` available (box uses proxy auth). CI assumes GitHub Actions (`gh pr checks`)
- Sandbox box (`bash scripts/dev.sh sandbox` launch) has no reviewer pair, so this skill can't be used. Re-attach to existing dev box with `bash scripts/dev.sh attach` or launch new dev box with `bash scripts/dev.sh`

## Arguments
PR number. If omitted, resolve current branch's PR with `gh pr view --json number`.

## Steps (loop until merge-ready)

1. **Resolve PR**: Use arguments; if omitted, get PR number and base branch with `gh pr view --json number,baseRefName,headRefName`.

1a. **Reviewer preflight (detect reviewer absence right after PR creation, not at chain end)**: Check the per-NAME pair's lease (`.claude/tmp/cdx-serve-$SANDBOX_VM_ID.lease`). **Resolve lease path to match the writer (`scripts/internal/a2a-review.sh` pair-serve)** — the writer `cd`'s to the parent of `git rev-parse --path-format=absolute --git-common-dir` (= main checkout root), then writes `.claude/tmp/cdx-serve-<NAME>.lease`. The reader side must also resolve to **the parent of `--git-common-dir`**, not `--show-toplevel` (which returns worktree root in worktree sessions). **Preflight is cheap early detection; don't run TCP probes** (TCP readiness discovery is the responsibility of the next step's `/a2a-review` actual invocation).
   **Before outputting escalate, get the value of `echo $SANDBOX_VM_ID` inside the box and replace the `<box-name>` placeholder in the message with the actual box name (literal)** (host shell has no `$SANDBOX_VM_ID` env; without the literal, empty expansion becomes a different session).
   - Lease missing → HOTL escalate: "per-NAME pair lease (`.claude/tmp/cdx-serve-<box-name>.lease`) not found. Restart `bash scripts/dev.sh <box-name>` on host (dev.sh idempotently attach-or-create the current box name + bg-fork pair-serve). Then re-run `/pr-codex-ci <PR-number>`."
   - Lease exists + `lease.claude_box != $SANDBOX_VM_ID` → HOTL escalate: "Lease is for `<lease.claude_box>`; doesn't match current box `<box-name>` (stale lease remains). Restart `bash scripts/dev.sh <box-name>` on host."

2. **Codex review (delegate to `/a2a-review`)**: Invoke `/a2a-review` targeting the PR's diff:
   ```text
   /a2a-review review origin/<base>...HEAD diff for correctness / security / regression aspects
   ```
   `/a2a-review` sends to codex via `bash scripts/internal/a2a-review.sh ask` (URL derived from `$A2A_CODEX_URL`) and returns findings. **Codex findings are a second opinion**; you judge adoption (don't treat 1 AI's opinion as independent evidence. Don't adopt nice-to-have / future-looking extensions; only fix clear correctness / security / regression / existing contract violations).

   **If `/a2a-review` returns a reviewer-unreachable error**, stop this skill and output HOTL escalate message in 1-2 lines (don't silently stop):
   > "`/a2a-review` cannot reach cdx-`<box-name>` reviewer. Recovery order is critical because active lock blocks dev.sh restart:
   > 1. **Ctrl-D / `exit`** claude from box terminal and exit dev.sh cleanly (trap cleans up cdx-pair + lock)
   > 2. Restart `bash scripts/dev.sh <box-name>` on host (new lock + pair-serve re-fork)
   > 3. After startup, re-run `/pr-codex-ci <PR-number>`
   >
   > If hanging and can't exit, run `sbx rm -f <box-name>` on host → step 2 (state lost). Replace `<box-name>` with the literal output of `echo $SANDBOX_VM_ID` inside the box."

3. **CI gate**: Check status with `gh pr checks <PR-number>`.
   - In progress (pending / in_progress) → recheck after an interval. Right after push, stale results from the previous commit may be captured; wait for the new run to start before judging. **No-progress timeout bound**: If the same check shows **no status change for 30+ minutes** (`pending` unchanged / `in_progress` with no step log progress), suspect manual approval pending / queue hang / runner shortage / execution hang and HOTL escalate (loop prevention). Cover **both pending and in_progress with unmoving step logs** under the same bound. Form: "CI run `<id>` has been `<elapsed-minutes>` in `<pending or in_progress>` with no progress. Possible causes: manual approval needed / queue hang / runner shortage / execution hang. Check manually with `gh run view <id> --web`. After fixing, re-run `/pr-codex-ci <PR-number>`."
   - Failed → identify why the check failed (get run-id from the failed check URL or `gh run list --commit <SHA> --json databaseId`; see failed log with `gh run view <run-id> --log-failed`. Don't use bare `gh run view` as it hangs in interactive TUI).
   - 0 checks → right after push, unconfigured CI may temporarily show 0 checks. If still 0 after a wait, treat as CI unset and skip (avoid mis-judging transient 0-checks as "no CI" and marking merge-ready).

4. **Judgment and loop**:
   - **There are adoptable codex findings or CI failed** → fix (Edit) → confirm diff with `git status --short` → `git add <affected-files...>` (explicit pathspec; bare `git add` stages nothing / `git add -A` may include unintended user changes; list target files one by one) → `git commit -m "<subject>"` (`-m` / `-F` required; bare `git commit` opens editor and hangs) → `git push` → **return to step 2** (re-evaluate with new head). Don't re-adopt findings rejected in the previous round.
     - **If the same finding / CI failure persists after fix, or cannot be fixed**, stop the loop and HOTL escalate (loop prevention). State **what happened + necessary human action**, not "what's next?". Example: "CI check `<name>` still fails after fix for the same reason (`<summary>`). Manual review needed. Failure log: `<URL>`." "Conflict at `<file>` cannot be auto-resolved. Resolve manually in `.worktrees/<branch>/`, then re-run `/pr-codex-ci <PR-number>`."
   - **No adoptable codex findings (LGTM / remaining are rejections only), CI green (or unset)** → **don't stop here; advance to step 5** (local gate = codex + CI passed, but GitHub bot review gate not yet confirmed; final merge-ready not yet). If codex remains non-LGTM but remaining findings are nice-to-have / rejections only, consider local gate clean.

5. **GitHub bot review gate (compose leaf `/pr-review-respond`)**: When local gate is clean at step 4, **invoke leaf skill `/pr-review-respond <PR-number>` without waiting for confirmation** (orchestrator → leaf rule from [../../../rules/skills.md](../../../rules/skills.md); this skill = orchestrator, `/pr-review-respond` = leaf). `/pr-review-respond` fetches bot reviews posted to GitHub (Copilot / chatgpt-codex-connector / qodo, etc.), decides accept/reject → replies + resolves → **returns structured result and exits**. `/pr-review-respond` itself doesn't call back this skill (cycle prevention).

   Based on `/pr-review-respond`'s return value (structured result), this skill determines next behavior:

   - **`pushed_changes: true`** (committed/pushed code fixes) → new head, so **re-evaluate from step 1** (codex + CI re-evaluated → if findings remain, invoke `/pr-review-respond` again at step 5; orchestrator loop)
   - **`pushed_changes: false` + all threads resolved + new review settled** (only replies/resolves, no code changes, remote gate clean) → **re-check step 3's CI gate** before (because `/pr-review-respond` doesn't judge CI green; settling may cross CI state transitions) **reporting final merge-ready and stopping** (no automatic merge; merge is human judgment). If re-check shows CI failure/regression, return to step 4's CI failure path (fix → re-evaluate from step 1)
   - **HOTL escalate** (`/pr-review-respond` cannot decide / cannot fix, etc.) → stop this skill and pass through escalate message as-is

> **Maintain responsibility separation while orchestrator composes leaf to avoid cycles**: "Actively invoking codex locally for second opinion (this skill = orchestrator)" and "fetching reviews already posted on PR to resolve (` /pr-review-respond` = leaf)" are separate acts, so remain independent skills. Orchestrator calls leaf; leaf returns structured result without calling back (top→bottom only, no cycles per [../../../rules/skills.md](../../../rules/skills.md)). Final `merge-ready` report from this skill = local gate (codex + CI clean) AND remote gate (all threads resolved + new review settled). **Don't mis-read "local gate clean = merge-ready" and stop** (a prior accident: mis-read led to "implementation complete" report → hours of idling → user nudged "bot review arrived" → restart; that was bad).

## Troubleshooting

| Issue | Solution |
|------|----------|
| `/a2a-review` stops, reviewer unreachable | Follow the guidance; restart `bash scripts/dev.sh <box-name>` on host (replace `<box-name>` with the literal output of `echo $SANDBOX_VM_ID` inside the box; host shell has no such env, so empty expansion happens). To debug, check host's `.claude/tmp/cdx-serve-<box-name>.log` (pair-serve output) |
| CI pending for extended time | Re-check `gh pr checks <PR-number>` at intervals. Verify if the run is hanging |
| Codex returns broad improvement suggestions | Don't adopt nice-to-have / future suggestions. Narrow to correctness / security / regression only (avoid addition bias) |
| PR cannot be resolved | Verify current branch is pushed and PR exists. If not, create PR first |
| Running inside a sandbox box | Sandbox box (`bash scripts/dev.sh sandbox`) doesn't mount host checkout, so reviewer doesn't work. Re-attach to existing dev box with `bash scripts/dev.sh attach` or start a new dev box with `bash scripts/dev.sh` |
