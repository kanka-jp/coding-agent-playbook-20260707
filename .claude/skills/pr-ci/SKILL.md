---
name: pr-ci
description: "Runs the post-PR pipeline: gets a codex (OpenAI) second-opinion review of the PR diff, applies a CI gate, and loops fixing codex findings and CI failures until the PR is review-clean and CI is green (or no CI configured). In a box session (SANDBOX_VM_ID set) automatically delegates to /pr-codex-ci (box-native, A2A codex pair) — the caller does not need to detect the environment. In a host session uses /codex-review (host codex CLI direct). Use after creating a PR, when the user asks to review a PR with codex and watch CI, or mentions PR review + CI / post-PR handling. Orchestrates /codex-review (or /pr-codex-ci on box) + gh pr checks + /pr-review-respond."
---

# pr-ci

Post-PR pipeline of **codex review + CI gate**. **In box session (SANDBOX_VM_ID set), automatically delegates to `/pr-codex-ci`**, and in host session works directly with host's `codex` CLI. Judgment quality is equivalent for both (1 codex's second opinion + CI + bot review chain advancing to final merge-ready).

**Caller can invoke this skill without being environment-aware** — step 0's auto-delegation absorbs environment differences:

## Autonomy (trigger and proceed without intermediate confirmation)

This skill **is invoked immediately after `gh pr create` without requesting confirmation** (see [../../../rules/pr-followup.md](../../../rules/pr-followup.md) "When to trigger"). After skill startup, **don't stop at offering choices** like "continue?", "adopt codex findings?", "re-push?". Adoption decision is auto-determined by this skill's judgment criteria (adopt only correctness / security / regression / existing contract violations).

Stop explicitly only for:
- **Final merge-ready report** (local gate: zero codex findings to adopt + CI green or unset / remote gate: all threads resolved + new review settled both AND) — return status to user and stop. Merge execution is user judgment (`gh pr merge` only on explicit instruction). **Don't stop at just local gate clean** (step 5 checks remote gate after). 
- **HOTL escalate** (unsolvable situation) — codex CLI unreachable / CI failure unfixable / conflict auto-resolve impossible / `/pr-review-respond` adjudication/fix impossible etc (check terminal hang during `/pr-review-respond` execution is escalated in `/pr-review-respond` leaf-side 30-min bound, not here in step 3, since caller is blocked waiting for leaf return). **Clearly state what happened + necessary human action + restart command in 1-2 lines** (message form: see [../../../rules/pr-followup.md](../../../rules/pr-followup.md) "HOTL escalate when unsolvable"). Prohibit "silently stuck" or "what's next?"

## Prerequisites

- **In box session, step 0 auto-detects and delegates to `/pr-codex-ci`** (see procedure below). Caller doesn't need to judge
- **In host session, uses host `codex` CLI**: if not installed / not authenticated, `/codex-review` HOTL escalates in step 2
- `gh` available. CI assumes GitHub Actions (`gh pr checks`)
- Environment setup details in [tools/a2a-review/README.md](../../../tools/a2a-review/README.md) (codex config)

## Arguments

PR number. If omitted, resolve current branch's PR with `gh pr view --json number`.

## Steps (loop until merge-ready)

0. **Check box environment → delegate to `/pr-codex-ci` and exit**: Check `printenv SANDBOX_VM_ID || true`; if it has a value, **don't execute further steps of this skill; instead invoke `/pr-codex-ci <PR-number>` and return its result as-is** (inside a box, `/codex-review` → host codex CLI is unavailable, so forward to box-native `/pr-codex-ci`. Don't execute steps 1–5 after):
   > "Running inside a box; delegating to `/pr-codex-ci`."

1. **Resolve PR**: **Always execute** `gh pr view <PR-number> --json number,baseRefName,headRefName,headRefOid` regardless of argument presence to get PR number + base / head names + head SHA (if arguments omitted, omit `<PR-number>` too to resolve from current branch). Even with arguments, skip next step's `<base>` placeholder resolution only if base/head are resolved.

2. **Codex review (delegate to `/codex-review`)**: **Target the PR's head SHA obtained in step 1** for diff review (not current local HEAD; prevents correctness accidents when invoking `/pr-ci <PR-number>` from arbitrary worktrees where local HEAD diverges from PR head). Use `gh pr diff <PR-number>` or after `git fetch origin <headRefName>`, use the `origin/<base>...origin/<headRefName>` form:
   ```text
   /codex-review review gh pr diff <PR-number> output for correctness / security / regression aspects
   ```
   Or:
   ```text
   /codex-review review git diff origin/<base>...origin/<head> for correctness / security / regression aspects
   ```
   **Don't pass local `HEAD` directly** (causes accidents reviewing a different ref diverged from PR head). `/codex-review` sends to codex via host `codex exec --skip-git-repo-check -s read-only` and returns findings. **Codex findings are a second opinion**; you judge adoption (don't treat 1 AI's opinion as independent evidence. Don't adopt nice-to-have / future suggestions; only fix clear correctness / security / regression / existing contract violations).

   **If `/codex-review` stops due to host codex not installed / not authenticated / network error**, stop this skill and pass through `/codex-review`'s HOTL escalate message as-is.

3. **CI gate**: Check status with `gh pr checks <PR-number>`.
   - In progress (pending / in_progress) → recheck after an interval. Right after push, stale results from the previous commit may be captured; wait for the new run to start before judging. **No-progress timeout bound**: If the same check shows **no status change for 30+ minutes** (unchanged `pending` / `in_progress` with no step log progress), suspect manual approval pending / queue hang / runner shortage / execution hang and HOTL escalate (loop prevention). Cover **both pending and in_progress with unmoving step logs** under the same bound. Form: "CI run `<id>` has been `<elapsed-minutes>` in `<pending or in_progress>` with no progress. Possible causes: manual approval needed / queue hang / runner shortage / execution hang. Check manually with `gh run view <id> --web`. After fixing, re-run `/pr-ci <PR-number>`."
   - Failed → identify why the check failed. **Pin run-id to a single one**: most reliable is directly from the failed check URL (1-to-1 with run). `gh run list --commit <SHA> --json databaseId,name,conclusion` returns multiple rows for multiple workflows / re-runs of the same commit; filter by `conclusion == "failure"` + `name == <failed-check-name>` then pick one (picking the first without filtering inspects the wrong failure). Pass the pinned run-id to `gh run view <run-id> --log-failed`. Don't use bare `gh run view` as it hangs in interactive TUI.
   - 0 checks → right after push, unconfigured CI may temporarily show 0 checks. If still 0 after a wait, treat as CI unset and skip (avoid mis-judging transient 0-checks as "no CI" and marking merge-ready).

4. **Judgment and loop**:
   - **There are adoptable codex findings or CI failed** → fix (Edit) → confirm diff with `git status --short` → `git add <affected-files...>` (explicit pathspec; bare `git add` stages nothing / `git add -A` may include unintended user changes; list target files one by one) → `git commit -m "<subject>"` (`-m` / `-F` required; bare `git commit` opens editor and hangs) → `git push` → **return to step 2** (re-evaluate with new head). Don't re-adopt findings rejected in the previous round.
     - **If the same finding / CI failure persists after fix, or cannot be fixed**, stop the loop and HOTL escalate (loop prevention). State **what happened + necessary human action**, not "what's next?". Example: "CI check `<name>` still fails after fix for the same reason (`<summary>`). Manual review needed. Failure log: `<URL>`." "Conflict at `<file>` cannot be auto-resolved. Resolve manually in `.worktrees/<branch>/`, then re-run `/pr-ci <PR-number>`."
   - **No adoptable codex findings (LGTM / remaining are rejections only), CI green (or unset)** → **don't stop here; advance to step 5** (local gate = codex + CI passed, but GitHub bot review gate not yet confirmed; final merge-ready not yet). If codex remains non-LGTM but remaining findings are nice-to-have / rejections only, consider local gate clean.

5. **GitHub bot review gate (compose leaf `/pr-review-respond`)**: When local gate is clean at step 4, **invoke leaf skill `/pr-review-respond <PR-number>` without waiting for confirmation** (orchestrator → leaf rule from [../../../rules/skills.md](../../../rules/skills.md); this skill = orchestrator, `/pr-review-respond` = leaf). `/pr-review-respond` fetches bot reviews posted to GitHub (Copilot / chatgpt-codex-connector / qodo, etc.), decides accept/reject → replies + resolves → **returns structured result and exits**. `/pr-review-respond` itself doesn't call back this skill (cycle prevention).

   Based on `/pr-review-respond`'s return value (structured result), this skill determines next behavior:

   - **`pushed_changes: true`** (committed/pushed code fixes) → new head, so **re-evaluate from step 1** (codex + CI re-evaluated → if findings remain, invoke `/pr-review-respond` again at step 5; orchestrator loop)
   - **`pushed_changes: false` + all threads resolved + new review settled** (only replies/resolves, no code changes, remote gate clean) → **re-check step 3's CI gate** before (because `/pr-review-respond` doesn't judge CI green; settling may cross CI state transitions) **reporting final merge-ready and stopping** (no automatic merge; merge is human judgment). If re-check shows CI failure/regression, return to step 4's CI failure path (fix → re-evaluate from step 1)
   - **HOTL escalate** (`/pr-review-respond` cannot decide / cannot fix, etc.) → stop this skill and pass through escalate message as-is

> **Maintain responsibility separation while orchestrator composes leaf to avoid cycles**: "Actively invoking codex locally for second opinion (this skill = orchestrator)" and "fetching reviews already posted on PR to resolve (`/pr-review-respond` = leaf)" are separate acts, so remain independent skills. Orchestrator calls leaf; leaf returns structured result without calling back (top→bottom only, no cycles per [../../../rules/skills.md](../../../rules/skills.md)). Final `merge-ready` report from this skill = local gate (codex + CI clean) AND remote gate (all threads resolved + new review settled). **Don't mis-read "local gate clean = merge-ready" and stop** (a prior accident: mis-read led to "implementation complete" report → hours of idling → user nudged "bot review arrived" → restart; that was bad).

## Differences from `/pr-codex-ci`

`/pr-codex-ci` (box-native) and this skill (host-native) differ only in the following points. **Since this skill auto-detects the box environment at step 0 and delegates to `/pr-codex-ci`, callers don't need to be aware of which to use**:

| Item | `/pr-codex-ci` | `/pr-ci` (this skill, when running on host) |
|---|---|---|
| Execution environment | box (inside dev box) | host |
| Reviewer preflight | yes (cdx-pair lease check) | no (host codex CLI unreachability escalates on `/codex-review` side) |
| Codex second opinion | `/a2a-review` (cdx-pair via A2A) | `/codex-review` (host codex CLI direct) |
| CI gate | inline (step 3 same) | inline (step 3 same) |
| Bot review chain | `/pr-review-respond` (same) | `/pr-review-respond` (same) |
| Final judgment | local (codex + CI) + remote (bot review) AND | same |
| HOTL escalate form | same | same |
| Auto-merge | default off (user judgment) | same |

## Troubleshooting

| Issue | Solution |
|------|----------|
| `/codex-review` stops; host codex not installed | Follow guidance; run `npm i -g @openai/codex` + `codex login` on host |
| `/codex-review` stops with auth error | Re-authenticate with `codex login` |
| CI pending for extended time | Re-check `gh pr checks <PR-number>` at intervals. Verify if the run is hanging |
| Codex returns broad improvement suggestions | Don't adopt nice-to-have / future suggestions. Narrow to correctness / security / regression only (avoid addition bias) |
| PR cannot be resolved | Verify current branch is pushed and PR exists. If not, create PR first |
| Invoked this skill inside a box | Step 0 auto-detects and delegates to `/pr-codex-ci`; no special handling needed. If reviewer-unreachable error occurs after delegation, follow `/pr-codex-ci` troubleshooting |
