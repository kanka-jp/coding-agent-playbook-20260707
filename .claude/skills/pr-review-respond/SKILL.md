---
name: pr-review-respond
description: "Handles GitHub PR reviews that bots (Copilot / qodo / codex-connector) and humans POST on a pull request: fetches the unresolved review threads, adjudicates each finding on its merits (fixes valid correctness/security/regression issues, replies with a reason for nice-to-have/rejected ones), and resolves the threads — autonomously, by the agent's own judgment. Distinct from /pr-codex-ci, which is a LOCAL codex second-opinion (claude proactively invokes codex); this one reacts to reviews already posted on the PR. Use after a push when GitHub bots have reviewed, and before merge (the ruleset blocks merge while any thread is unresolved). Mentions: PR review handling / resolve GitHub review / handle Copilot and qodo comments / clean up review threads."
---

# pr-review-respond

Fully autonomously processes reviews that GitHub attaches to PR (bot like Copilot / qodo / codex-connector + humans) **by agent's judgment**.

**Different from `/pr-codex-ci`**: that one has claude **proactively invoke codex locally** for second opinion (findings return to claude). This skill **fetches reviews already posted on PR** from GitHub, responds and resolves (reactive, via GitHub thread).

## When to use
- After pushing to PR, when GitHub bot review (Copilot / qodo etc) attaches
- **Before merge**: ruleset's `required_review_thread_resolution` blocks merge with unresolved threads (see [../../../docs/repo-settings.md](../../../docs/repo-settings.md))

## Arguments
PR number. If omitted, resolve current branch's PR with `gh pr view --json number`.

## Procedure (loop until all threads resolved)

1. **Resolve owner/repo**: `gh repo view --json nameWithOwner -q .nameWithOwner` (graphql can't use `{owner}/{repo}` placeholder, needs explicit value).

2. **Fetch unresolved threads → handle immediately if any, judge done if none**: List PR's unresolved review threads with `gh api graphql` (id / path / line / each comment's author / body):
   ```bash
   gh api graphql -f query='{ repository(owner: "<owner>", name: "<repo>") {
     pullRequest(number: <PR-number>) { reviewThreads(first: 50) {
       pageInfo { hasNextPage endCursor }
       nodes { id isResolved path line comments(first: 20) { nodes { author { login } body } } }
     } } } }'
   ```
   Target only nodes with `isResolved == false`. If `pageInfo.hasNextPage == true`, fetch next page with `after: <endCursor>`, and **tally unresolved across all pages** before judging zero (don't miss any in PRs exceeding 50 threads). For long threads with comments exceeding 20, follow the thread individually and read full context before deciding.

   ### Settlement judgment (event-based timing, not time-polling)

   **No time-based polling** (e.g., "poll N minutes waiting for 0-count stability"). Two reasons: (1) Most reviewers you'd wait for **don't re-review on push** (see "reviewer push-time behavior" below), so time-waiting is a miss. (2) **Clean reviews without findings don't generate review comments** (CodeRabbit just sets commit status to `success`), so "waiting for bot review comments" as a primitive can't observe clean reviewers. Instead, **handle unresolved immediately if any; if none, judge done via check completion (event)**:

   - **If even 1 unresolved thread exists, don't wait; proceed to step 3** (decide / fix or reply → resolve). After responding, return to step 2's start and re-fetch (new arrivals may appear while responding = pipelining fills wait time with work).
   - **If 0 unresolved, judge done? via check state (event)**: Check `gh pr checks <PR-number>`. **Here, check serves only as a timing signal ("have reviewers/CI appeared?")** (pass/fail merge eligibility = CI gate is not this leaf's responsibility but caller orchestrator's).
     - `pending` / `queued` / `in_progress` remains → reviewer/CI **in progress**. Wait for terminal state, then re-run step 2 (★not a time floor but check state transition. CodeRabbit signals review completion via `pending` → `success`/`failure`, so this is the "commit status reviewer completion" signal).
       - **Leaf-side timeout bound**: Caller orchestrator is blocked waiting for this leaf's return, so caller's 30-minute CI bound **can't fire during this leaf's execution**. Thus, check-wait hang is bound by this leaf itself: starting from the first time any CI reaches terminal, if no terminal progress for 30 minutes (or perpetually pending), HOTL escalate ("PR #<num> check hasn't reached terminal for 30+ minutes. Verify with `gh pr checks <num>` / `gh pr view <num> --web`, then re-run `/pr-review-respond <PR-number>`").
     - All checks terminal (`pass` / `fail` / `skipping` / `neutral` only, or 0 checks = CI unset) + 0 unresolved → **reviewers complete, threads clean**. Go to step 5 (return structured result. **Don't judge CI green here**; delegate to caller — caller re-checks its CI gate after this leaf returns. This leaf's settlement wait may cross CI state transitions).

   **Reviewer push-time behavior (background for "who to wait for" judgment)**:
   - **CodeRabbit**: Incremental review + commit status (`pending`→`success`) per push → **check state signals settlement**
   - **qodo**: Default `handle_push_trigger = false` (`handle_pr_actions = ['opened','reopened','ready_for_review']`) → **doesn't re-review on push** (PR open only). No point waiting after push.
   - **chatgpt-codex-connector**: Auto-review on PR open / `@codex review` is baseline; push-per-review not guaranteed. No commit status, comment-only → **no progress-observable signal**

   **Comment-only reviewer tail arrival (known limitation, intentionally tolerated)**: Reviewers without check status, comment-async like codex, have no signal for "in progress", so comments arriving late after `all checks terminal + 0 unresolved` aren't caught here (no time-wait policy). This relies on **merge being human judgment (HOTL) + late arrivals remaining as new threads for next pass / human handling** (codex without push-trigger baseline rarely arrives on push, making wait cost unjustified).

   **When unresolved threads appear**, proceed to step 3 (return to step 2 after resolve).

3. **Judge each thread** (same criteria as `/pr-codex-ci`'s codex findings; **don't treat 1 AI's opinion as independent evidence**):
   - Clear **correctness / security / regression / existing contract violations** → adopt. Fix (Edit → `git add` → `git commit` → `git push`)
   - **Nice-to-have / future extensions / false positives / already intentional** → reject
   - **Don't resolve mechanically**. Always read content and decide (rubber-stamping resolve just to merge is prohibited)
   - Bot-supplied "Agent Prompt" for remediation (qodo, etc.) is reference only; you decide adoption

4. **Reply + resolve**: Reply to each thread with **response content** (adopt = summary of fix commit / reject = reason), then resolve:
   ```bash
   gh api graphql \
     -F threadId='PRRT_...' \
     -F body='<response or rejection reason>' \
     -f query='mutation($threadId: ID!, $body: String!) {
       addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $threadId, body: $body}) { comment { id } }
       resolveReviewThread(input: {threadId: $threadId}) { thread { isResolved } }
     }'
   ```
   GraphQL mutations execute sequentially but aren't atomic, so **confirm `comment.id` returns from reply** — if reply fails but resolve succeeds, feedback is hidden with no audit trail. If so, review body and repost reply. If you push fixes, new push may trigger bot re-review, so **return to step 2 and repeat until no new unresolved threads**.

5. **Complete (return structured result to caller)**: This skill is a **leaf** ([../../../rules/skills.md](../../../rules/skills.md)), so **don't call back** the upper orchestrator (typically `/pr-codex-ci` step 5) (cycle prevention). Return structured result and exit:

   - `pushed_changes: true / false` (did you Edit + commit + push code at step 3?)
   - `resolved_count: N` (number of threads resolved from skill launch to exit)
   - `final_unresolved: 0` (or `> 0` for HOTL escalate path)
   - `checks_terminal: true` (all checks reached terminal at step 2's done judgment. **Don't include individual check pass/fail** — CI green judgment is caller's responsibility)

   If `pushed_changes: true`, the new SHA is unverified by codex/CI; caller orchestrator is responsible for re-evaluation (`/pr-codex-ci` step 5 sees `pushed_changes` and restarts from its step 1). If `pushed_changes: false`, this leaf's settlement wait may cross CI state transitions, so **caller must re-check its CI gate after this leaf returns before merge-ready judgment** (leaf doesn't guarantee CI green; see step 2's check judgment). If this skill is called standalone (no caller orchestrator), report to user "all threads resolved; final CI green check before merge (leaf doesn't judge CI green)" and stop.

## Important notes
- **Resolve always after adjudication**. This is the core of "don't rubber-stamp review feedback" (GitHub reviews are others' writing on the PR, so treat more carefully than local codex consultation)
- Avoid addition bias in judgment; narrow to correctness / security / regression / existing contract violations
- If reply/resolve fails (reviewer unreachable, etc.), don't force resolve; report to user and stop
- **Maintain leaf nature**: don't call `/pr-codex-ci` / other orchestrators from this skill. Re-evaluation after fix push at step 3 is **caller orchestrator's responsibility** (just convey push presence via structured result)
