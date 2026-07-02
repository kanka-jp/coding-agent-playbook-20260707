# Cloud-resident unattended SRE automation (Bedrock) reference

This directory is a self-contained reference for the
**cloud-resident (HOTL) pattern** defined in the decision record [docs/decisions/cloud-unattended-sre.md](../../docs/decisions/cloud-unattended-sre.md)
— CloudWatch 5xx → agent → automatic fix PR.

The **local (HOTL) pattern** where humans conduct read-only investigation at hand is covered in [examples/observe](../observe/runbook.md) and
[rules/box-personas.md](../../rules/box-personas.md) US3. These are complementary on different axes (local = human deep-dive / cloud = unattended first response).

## Contents

| path | Role |
|---|---|
| [spike/](spike/) | Harness that validates the ADR's core hypothesis: "**Can an agent on Bedrock derive appropriate fixes from sanitized triage?**" with minimal cost without building infrastructure. Gate for advancing ADR from `Proposed → Accepted` |
| [pipeline/](pipeline/) | Built on top of spike: **trigger wiring + identity boundary design** (CloudWatch 5xx → Lambda triage → fixer → PR). Two least-privilege IAM templates for observation/remediation, handoff design that makes dispatch a sanitization gate. IaC/implementation belongs to stage branches |

## Phases

Build order following ADR's "residual / undecided" items:

1. **spike** ([spike/](spike/)) — Validation of core hypothesis. ← Completed (first PASS with direct Anthropic key)
2. **trigger wiring + identity design** ([pipeline/](pipeline/)) — CloudWatch 5XX alarm → SNS → Lambda triage, IAM boundary for observation/remediation identities. ← Current phase (design)
3. Pattern A (Fargate / CodeBuild with `claude -p`) → B (AgentCore Runtime with Agent SDK) end-to-end
4. Course material (stage 06→07 demonstration of pipeline + operations/maintenance phase in `slides/`)

Pipeline implementation from phase 2 onwards and seeded bugs are placed in demo app (stage branches). This directory is confined to being a cross-cutting reference (auth/execution foundation, validation harness) on main ([CLAUDE.md](../../CLAUDE.md) "Stage branch conventions").
