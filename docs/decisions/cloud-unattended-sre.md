# Decision Record: Execution platform and authentication for cloud-resident unattended SRE automation (CloudWatch → agent → PR)

**Status: Proposed (2026-06-29)** — Design for execution platform (Amazon Bedrock), authentication (AWS IAM), and 2 patterns (`claude -p` / Agent SDK) are finalized. Real-world spike (production deployment verification) not yet passed; will update to Accepted after passing.

## Background: "Operations & maintenance" has two separate axes

Operations & maintenance / bug-fix phase has two distinct execution models that must not be confused.

| | Local investigation (existing) | **Cloud-resident (this record)** |
|---|---|---|
| Trigger | **Human** initiates locally | **CloudWatch event** (5xx alarm, etc.) initiates |
| Execution site | Local sbx observe box | **Resident on AWS** (Fargate / AgentCore Runtime) |
| Human position | At keyboard (HOTL) | Away from keyboard (HOTU) |
| Role | Read-only, **investigate** root cause | First response: triage → **self-run to fix PR** |
| Rules | [box-personas.md](../../rules/box-personas.md) US3 / [examples/observe](../../examples/observe/runbook.md) | This record |

These are **complementary** (local = human deep-dives / cloud = unattended first response), not competitive. [box-personas.md](../../rules/box-personas.md) observe box is **local HOTL investigation tool** and does not constrain this record's cloud resident pattern. This record decides only cloud-side execution platform and auth.

## Decision 1: Execution system is `claude -p` on Bedrock and Agent SDK (not `ant` / Managed Agents)

Three candidates for agentic "investigate → fix → PR" flow on cloud.

| Candidate | Can run on Bedrock (AWS-contained) | Decision |
|---|---|---|
| Anthropic **Managed Agents** (`ant beta:sessions`) | **No**. Anthropic Platform-only feature; Bedrock only provides raw model inference (Bedrock's "Managed Agents" is separate, not Anthropic's) | **Exclude** |
| **`claude -p`** (Claude Code headless) | Yes (`CLAUDE_CODE_USE_BEDROCK=1`) | **Adopt = Pattern A** |
| **Claude Agent SDK** (self-loop agent process) | Yes. Skills / subagents / MCP work as-is, runs on AgentCore Runtime | **Adopt = Pattern B** |

Not adopting `ant` (Managed Agents) because this pattern's first requirement is **AWS-contained, IAM billing**. Managed Agents require Anthropic Platform pay-as-you-go API key, incompatible with this requirement. Deploy both patterns side-by-side for comparison (A = light shell-pipe style / B = custom tools, approval gates via code).

## Decision 2: Auth/billing via Bedrock (IAM). Do not use subscription

| Auth | Applicable in this pattern | Rationale |
|---|---|---|
| Subscription OAuth (`claude setup-token` / `CLAUDE_CODE_OAUTH_TOKEN`) | **No** | Consumer ToS §3.7 prohibits "automatic / non-human means of access except via API key". Anthropic Help Center explicitly states "shared production automation must use Platform API key". Subscription limited to "ordinary, individual usage"; cloud-resident unattended infrastructure does not qualify |
| Anthropic Platform API key (`sk-ant-api03-`) | Possible but not adopted | Billed outside AWS. Deviates from AWS-contained requirement |
| **Amazon Bedrock (AWS IAM)** | **Adopted** | IAM billing within AWS account (no external key to Anthropic). `CLAUDE_CODE_USE_BEDROCK=1` + `AWS_REGION` + `ANTHROPIC_MODEL`=Bedrock inference profile id. **If wanting to contain in VPC, additionally** use `bedrock-runtime` Interface VPC Endpoint (PrivateLink) (IAM auth alone routes via regional service endpoint, not VPC-contained) |

**Subscription's correct place is local side** ([box-personas.md](../../rules/box-personas.md) dev box / observe box where humans run interactively). Do not embed subscription token in cloud-resident unattended pipeline; it violates ToS and has enforcement history (server-usage token blocking). Not adopted.

> Note (supporting rationale, not part of decision): Not adopting subscription is **based on §3.7 (automation prohibition)**, independent of billing pool handling (2026-06-15 "separate `claude -p` / Agent SDK from subscription pool" change and its hold). Regardless of billing outcome, this decision stands.

## Decision 3: Architecture and approval gate

```text
CloudWatch (ALB/API GW 5XX alarm  or  Logs metric filter ERROR/5xx)
   └─► Alarm ─► SNS ─► Lambda(trigger + triage) … observation identity (AWS read + one-way dispatch only, no external egress)
                          │  Fetch relevant logs via Logs Insights → judge actionable → sanitize triage
                          ▼ only actionable, handoff sanitized triage (AWS read ends here)
        ┌────────────────────────────┬────────────────────────────┐
        ▼ Pattern A                    ▼ Pattern B             … fix identity (repo-write, no AWS read)
   Fargate / CodeBuild             AgentCore Runtime
   claude -p on Bedrock            Claude Agent SDK on Bedrock
        └─► triage result + repo investigation → runbook(Skill) → fix → open PR ◄─┘
                          │
              Open PR unattended / merge by human (approval gate)
```

**Approval gate**: Unattended until PR creation, **human merges**. Aligns with playbook's "merge by user decision, default report and stop" ([CLAUDE.md](../../CLAUDE.md)).

**Identity boundary (decision and constraint)**: Log / AWS reads **only in Lambda triage phase (observation identity)**. Observation identity authority limited to **AWS read + one-way dispatch to start fixer (`StartBuild` / `RunTask` / queue publish, etc.), no external egress including GitHub**. However **dispatch payload itself can become indirect exfil channel**: if observer can freely load log-derived data into env override / message body, it can exfil via fixer's GitHub egress, restoring lethal trifecta. Therefore **constrain handed-off triage to fixed schema, allowlist, size limits, ban raw logs/secrets, ban overrides, making dispatch boundary itself a sanitize gate**. Pattern A/B fixers take **only sanitized triage result + repo** as input, with **separate identity without AWS read**. Must not co-resident CloudWatch read and GitHub write in single identity (single Fargate/AgentCore role); breaking this enables lethal trifecta this ADR avoids (see "Safety" below).

## Safety: Collapse lethal trifecta in cloud too

[box-personas.md](../../rules/box-personas.md) P5 principle (avoid simultaneous private data + untrusted content + external comms) lives in cloud too. Unattended agent co-residing **untrusted log body** and **repo write / GitHub egress** in one identity enables trifecta; malicious log body can exfil via PR. How to collapse it (identity separation is **constraint** = Decision 3, rest is reinforcement):

- **Separate observation (AWS read + one-way dispatch only, no GitHub/external egress) and fix (repo-scoped, no AWS read) into different identities**.
- Fix side receives **only structured triage result, not raw logs**. Handoff (dispatch payload) sanitized by **fixed schema, allowlist, size limits**, ban raw logs / secrets / free overrides (prevent this handoff boundary becoming indirect exfil channel).
- Identity opening PR is **repo-scoped, short-lived** (same PAT scope principle as [parallel-hotl-execution.md](parallel-hotl-execution.md)).
- **Human gate on merge** (Decision 3).

Read/write separation enforced via **IAM and GitHub token scope**, not Bedrock layer (independent of tool layer, same philosophy as box-personas P4).

## Residual and undecided

- **Real-world spike not yet passed**: Pattern A (Fargate/CodeBuild with `claude -p` on Bedrock) / B (Agent SDK on AgentCore Runtime) production deployment verification, CloudWatch→Lambda wiring, approval gate Slack integration are follow-up. Will update to Accepted after passing.
- **Fix quality limitations**: LLMs excel at quick-fix PRs but weak on root-cause identification; postmortems tend to top out at "readable 80%". Assume human merge gate, do not auto-merge.
- **Cost**: Bedrock pay-per-use (IAM billing). In triage phase, judge actionable; for noise, start no agent, only log (**if creating GitHub issue, do so outside observation**; if observation identity has GitHub egress, lethal trifecta returns; dedup source of truth is internal state, not GitHub; see [examples/sre-bedrock/pipeline/README.md](../../examples/sre-bedrock/pipeline/README.md) "optional: issue layer") to suppress invocation frequency.
- **Demo app placement**: Pipeline implementation and intentional bugs live on demo app (stage series) side. This record handles only main-side cross-cutting decision (auth / execution platform), does not touch stage project code ([CLAUDE.md](../../CLAUDE.md) "stage branch rules").

## Sources

- [Build an SRE incident response agent with Claude Managed Agents — Claude Cookbook](https://platform.claude.com/cookbook/managed-agents-sre-incident-responder)
- [Run Claude Code programmatically (headless) — Claude Code Docs](https://code.claude.com/docs/en/headless)
- [Running Claude Agent SDK with Skills on Amazon Bedrock — AWS Builder Center](https://builder.aws.com/content/3AC38DtkrFlNL0p076gVNPzSHuw/running-claude-agent-sdk-with-skills-on-amazon-bedrock)
- [Legal and compliance — Claude Code Docs](https://code.claude.com/docs/en/legal-and-compliance)
- [Use the Claude Agent SDK with your Claude plan — Claude Help Center](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan)
- [Claude Credit Overhaul 2026: Anthropic Pauses the June 15 Change — digitalapplied.com](https://www.digitalapplied.com/blog/anthropic-claude-credit-overhaul-june-15-2026)
