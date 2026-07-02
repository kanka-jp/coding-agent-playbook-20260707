# GitHub Repository Settings (ruleset)

This repo's merge gate is enforced via GitHub **ruleset** (Settings → Rules → Rulesets). Main goal: **can't merge to main without resolving all review threads**. Since agent runs in YOLO/autonomous mode, "How to mechanically prevent mistaken merges while supporting 'auto-merge when asked'" is outlined in "Agent autonomous merge gate design" below.

## Active ruleset (default branch = main)

| Rule | Value | Meaning |
|------|-------|---------|
| `pull_request` | Required | Changes to main must go through PR (pull request) |
| └ `required_review_thread_resolution` | `true` | **Can't merge until all PR review threads resolved** (main purpose) |
| └ `dismiss_stale_reviews_on_push` | `true` | New push dismisses existing review approvals |
| └ `required_approving_review_count` | `0` | Don't require approval count (quality assured by thread resolution. Owner-led repo) |
| `non_fast_forward` | Forbidden | Forbid force-push to main |
| `deletion` | Forbidden | Forbid main deletion |

`enforcement: active` applies to all (no bypass).

Note: `pull_request` rule requires changes via PR; **blocking all direct push (`Restrict updates` rule) is not in this ruleset**. "No direct push to main" is ensured by operations norm in [../CLAUDE.md](../CLAUDE.md) "Commit / PR Operations" (force-push & deletion mechanically blocked by `non_fast_forward` / `deletion` above).

## Prerequisites (plan requirement)

Ruleset / branch protection **requires GitHub Team/Pro plan for private repos** (free for public). This repo is private, so org is on paid plan. Private repos without a plan get `403 Upgrade to GitHub Pro or make this repository public` from ruleset API.

## Checking & Changing

- **Web UI**: Settings → Rules → Rulesets → "main"
- **CLI** (`gh` auto-resolves `{owner}/{repo}` placeholder):

```bash
# List
gh api repos/{owner}/{repo}/rulesets
# Details (<id> from list)
gh api repos/{owner}/{repo}/rulesets/<id>
```

Update by `PUT repos/{owner}/{repo}/rulesets/<id>` with full ruleset (whole replacement not partial, so keep existing rules while changing).

## Relation to workflow norms

Paired with GitHub enforcement (this ruleset), development flow also defines **"address & resolve all reviews before merge"** in [../CLAUDE.md](../CLAUDE.md) "Commit / PR Operations". Ruleset is mechanical gate, norms are operational guidelines for agent / humans, doubly assured.

## Agent autonomous merge gate design (prevent mistakes & enable auto-merge)

Running agent in YOLO/autonomous mode requires both "don't auto-merge without asking" and "auto-merge when asked". Key: **place gate on server (unreachable by agent) side via ruleset, making only conditions agent can satisfy (CI status check) merge requirements**. Below is design basis from confirmed GitHub docs behavior (citations at each section end).

### Principle 1: Self-approve impossible → don't use human approval as gate

**In GitHub, PR creator account can't approve own PR** ([create-pull-request: concepts-guidelines](https://github.com/peter-evans/create-pull-request/blob/main/docs/concepts-guidelines.md)). Agent can't approve own PR via agent account or shared token.

Meaning: **"N approvals required" gate structurally breaks solo agent operation**. This repo's `required_approving_review_count: 0` is this consequence; quality assured by **local codex review ([../CLAUDE.md](../CLAUDE.md) Step 4) + review thread resolution**. Understand: human-approval-required gate and agent autonomy don't coexist.

### Principle 2: gate on server, not client (agent can bypass client)

Trying to prevent mistakes via **agent config or behavior** fails because agent can work around it:

| Defense | Layer | Why weak / strong |
|---------|-------|-------------------|
| Deny `Bash(gh pr merge*)` in `.claude/settings.json` | **client** | Only constrains that session's Bash calls. Agent can bypass via alias, direct `gh api`, web UI etc. Prevents oopsies only |
| "Only use `--auto`, never immediate merge" rule | **behavior (norms)** | Agent switches to immediate `gh pr merge`, breaks the rule. No enforcement |
| **required status check** in ruleset | **server** | GitHub judges regardless of merge path (CLI / `gh api` / web UI). Red/pending rejects merge API itself. **Unbypassable** (except bypass actors, principle 4) |

Bottom line: **"CLI lets it happen so it gets bypassed" is true—hence defense goes to ruleset (server) not CLI (client)**. Server gate applies same criteria whether `gh pr merge` or `gh api`, so command restriction becomes unnecessary ([available-rules-for-rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets): "all required status checks must pass before collaborators can merge changes into the branch").

### Principle 3: required status check as gate, auto-merge for autonomy

Only merge condition agent can satisfy by itself: **CI status check (green)**. Use it for both mistake prevention & autonomous merge:

1. Add **"Require status checks to pass"** to ruleset, make PR CI required → **red/pending blocks all merges** (mistake prevention).
2. Turn on **"Allow auto-merge"** in repo settings (Settings → General → Pull Requests).
3. Agent uses **`gh pr merge --auto`** not immediate `gh pr merge` → **GitHub auto-merges the instant all gates turn green** (autonomous merge). Stays unmerged while red.

Auto-merge triggers **"all required reviews are met and all required status checks have passed"** ([automatically-merging-a-pull-request](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/incorporating-changes-from-a-pull-request/automatically-merging-a-pull-request)). Notes:

- Auto-merge becomes **reservation not immediate merge** only if branch protection / ruleset has **at least 1 requirement**. Without, auto-merge queues immediate merge right away, so required status check is prerequisite here too ([enable-pull-request-automerge](https://github.com/peter-evans/enable-pull-request-automerge): "The pull request base must have a branch protection rule with at least one requirement enabled").
- **write-permission holders** enable auto-merge; **write holders & PR author** disable it ([automatically-merging-a-pull-request](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/incorporating-changes-from-a-pull-request/automatically-merging-a-pull-request)).

**Critical prerequisite (protecting gate source itself)**: required status check becomes unreachable by agent **only if agent can't modify the workflow definition (`.github/workflows/*.yml`) that generates it**. If agent can modify workflow, it can **keep the required job name but no-op its contents**, and since `pull_request` workflows run on the merge branch, it can make the modified workflow pass required status green, bypassing `--auto`.

Here's where this repo's token design matters: fine-grained PAT creating/updating `.github/workflows/**` requires **`Workflows: Read and write` separately from `Contents: write`**, but [setup.md](setup.md)'s agent token **doesn't grant `Workflows`** (only Contents / Pull requests = write). So **agent can't modify workflow files**, this no-op path is blocked by current token design. Conversely, protection depends on token design, so **if agent gets `Workflows: write` or separate workflow-editing credential, `.github/workflows/**` must be separately protected** (e.g., CODEOWNERS requires human review, ruleset includes workflow PRs in manual gates only).

### Principle 4: Empty bypass list + agent token least-privilege

**Ruleset doesn't apply to bypass actors** (users/teams/GitHub Apps listed) ([about-rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets)). If ruleset treats admin as bypass, **admin-privileged token can force-merge red CI**, nullifying server gates from principles 2–3. GitHub's new ruleset (unlike classic branch protection) **applies even to admin**. This repo already has **`enforcement: active` / empty bypass list** (noted above in "Active ruleset"), consistent. Never add to bypass list.

**But empty bypass alone is insufficient** — never give agent a token that can rewrite ruleset itself. Ruleset update/deletion requires **`Administration` write** (GitHub REST: update/delete repository ruleset). If agent runs with admin-capable token, it can **delete/relax ruleset via `gh api` before merge** even without bypass listing, circumventing gate. Server enforcement only truly holds when **agent token is least-privilege**. This repo's agent token ([setup.md](setup.md)) is fine-grained PAT: **Contents / Pull requests = write, Actions / Commit statuses = read-only, `Administration` not granted**. Not granting **`Administration` write** is principle 4's other half—agent can't modify ruleset, empty bypass gate stays beyond agent's reach.

Only humans wanting to merge red immediately face asymmetry: **temporarily relax ruleset / add self to bypass** requires **explicit human action (human with `Administration` privilege)**. Goal: accidental immediate merges physically blocked server-side; forced merges require intentional human action.

### Prerequisite & current state: PR-triggered CI needed (not yet in this repo)

Principle 3's required status check gate assumes **CI actually runs per PR**. But this repo's CI workflow currently **`on: workflow_dispatch` only** (to avoid consuming free Actions minutes on private repo. [../.github/workflows/README.md](../.github/workflows/README.md))**—doesn't auto-run on PR**. Thus:

- No existing PR check to specify for required status, gate **not yet active**.
- To enable: first follow [../.github/workflows/README.md](../.github/workflows/README.md) to add `pull_request:` to each workflow's `on:` → then add "Require status checks to pass" to ruleset with check name.
- Until then, merge gate relies on **thread resolution + HOTL judgment ([../CLAUDE.md](../CLAUDE.md) "Commit / PR Operations" norms)**. But **thread resolution is not "unreachable server barrier"** — threads resolvable by **PR opener or write holders**; this repo's agent opens PRs and has **Pull requests: write** ([setup.md](setup.md)), so **agent can resolve bot comments and satisfy gate itself**. So `required_review_thread_resolution` mechanically blocks merge but lacks enforcement against agent; functions as **auditable workflow step (who resolved what stays in thread)**. With CI gate unsatisfied, actual agent restraint is **HOTL judgment** (agent defaults to not merge, reports and stops; merge requires user action. [../CLAUDE.md](../CLAUDE.md) Step 6).

### Summary

- **Prevent mistakes = server ruleset** (required status check + empty bypass). Client denies & norms are bypassable, so not primary defense.
- **Server enforcement holds only if agent token is least-privilege**: don't grant `Administration` write (can rewrite ruleset to bypass). `.github/workflows/**` mods need `Workflows: write`, but this repo's token doesn't have it, so no-op path is blocked (if giving `Workflows: write`, protect workflow defs separately via CODEOWNERS etc).
- **Autonomous merge = `gh pr merge --auto` + Allow auto-merge**. Merges only when green, server rejects when red.
- **Don't use human approval as gate** (PR creators can't self-approve). Quality from local codex review + thread resolution.
- Required status check above assumes **PR-triggered CI active**, not yet in this repo. Current thread resolution is only auditable step agent can self-resolve; actual restraint is **HOTL judgment**.
