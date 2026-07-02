# pipeline: 500 alert → unattended fix PR wiring design

Reference that **breaks down ADR decision 3 (architecture & approval gate) and the "safety" section (identity isolation) into implementable design** ([cloud-unattended-sre.md](../../../docs/decisions/cloud-unattended-sre.md)). Following [spike/](../spike/) demonstrating "can remediation identity fix from triage?", this solidifies the **trigger wiring + identity boundary** built on top (ADR phases 2–3).

This directory is a cross-cutting reference on main (design of auth/execution foundation + IAM templates + repo-independent fixer entrypoint reference implementation). **IaC implementation, Lambda triage body, and demo app (with seeded bugs) are placed in stage branches** ([CLAUDE.md](../../../CLAUDE.md) "Stage branch conventions"). Details of placement are in the "Implementation placement" table below.

## Overall wiring (concrete realization of ADR decision 3)

```text
CloudWatch  (ALB/API GW 5XX alarm  or  Logs metric filter for ERROR/5xx)
   └─ Alarm ─ SNS ─ Lambda(triage)            ← observation identity (observe-identity-iam.json)
                      │ ① Retrieve relevant logs via Logs Insights
                      │ ② actionable judgment (noise not spawning agent, recorded in internal state only. issue creation outside observation scope — see "optional: issue layer" below)
                      │ ③ sanitize to fixed schema (no raw logs/secrets)
                      ▼ ④ PUT to s3://TRIAGE_HANDOFF_BUCKET/triage/<incident-id>.json (only verified). Observation output ends here
   S3 event ─ EventBridge rule ─ StartBuild/RunTask   … startup is infra (not observation credentials). key is event-derived, no override
        ┌─────────────────────────┬─────────────────────────┐
        ▼ Pattern A                ▼ Pattern B          ← remediation identity (fixer-identity-iam.json)
   CodeBuild / Fargate          AgentCore Runtime
   claude -p on Bedrock         Claude Agent SDK on Bedrock
        │ GET triage from S3 (clone repo). AWS read not allowed beyond this (IAM Deny)
        └─ triage + repo → runbook(Skill) → minimal fix → gh pr create (unattended)
                      │ merge by human (approval gate)
```

**Observation identity does not directly start fixer** (not given `codebuild:StartBuild`). StartBuild can carry env/source overrides, so observation could use it to load raw logs/secrets and exfiltrate via fixer's GitHub egress. Thus startup is segregated into **S3 event → EventBridge rule → StartBuild/RunTask**, an infra-side trigger, with fixer receiving only **event-derived object key** (no override path). Triage content is passed **only as an S3 object that passed schema validation in ④**. Fixer entrypoint also reads no env override, taking only the S3 object from the key as input. This realizes the ADR principle "dispatch boundary itself becomes sanitization gate" (preventing smuggling raw data via env override).

## Two identities (breaking lethal trifecta with IAM)

Implements ADR constraint "observation (AWS read + one-way dispatch) and remediation (repo-write, no AWS read) in separate identities" with two least-privilege policies. Placeholders (`REGION` / `ACCOUNT_ID` / `*_NAME` etc.) are replaced per environment.

| Concern | observation identity ([observe-identity-iam.json](observe-identity-iam.json)) | remediation identity ([fixer-identity-iam.json](fixer-identity-iam.json)) |
|---|---|---|
| app/incident logs read | ✅ Logs Insights (app log group scope) | ❌ **explicit Deny** (`DenyIncidentAndAppDataRead`) |
| Bedrock inference | ❌ explicit Deny | ✅ scoped to Anthropic model/profile (global cross-region is 3 ARNs) |
| GitHub write | ❌ no network egress | ✅ `gh pr create` with repo-scoped token from Secrets Manager |
| triage handoff | ✅ PutObject to S3 `triage/*` (write only) | ✅ GetObject from S3 `triage/*` (read only) |
| startup direction | Ends at S3 PutObject (`StartBuild` **not granted**). Startup handled by S3 event→EventBridge | Started only (cannot call back observation, receives only event-derived key) |
| credential broker | ❌ `sts:AssumeRole*` Deny | ❌ `sts:AssumeRole*` Deny |

**Key point**: "permission to read untrusted log content" and "permission to write to GitHub" do **not coexist in same identity**. Observation can read but cannot exfiltrate; remediation can exfiltrate but cannot read incidents (explicit Deny). Fixer's `secretsmanager:GetSecretValue` is **only its own GitHub token**, not incident/app data read (boundary not breached).

## handoff = sanitization gate (schema shared with spike)

JSON written by Lambda triage to S3 is the same fixed schema as [spike/triage.json](../spike/triage.json) (`schema_version` / `incident.signature` required, unknown top-level keys rejected, size limit, `no_raw_logs` / `no_secrets`). Since spike harness ([spike/run-spike.sh](../spike/run-spike.sh)) already implements the same validation, **Lambda-side validation must remain equivalent to spike's validation logic** (no drift). Triage that fails validation is not dispatched (even if actionable, malformed triage is discarded).

**Fixer reads only one triage of its own incident**: Fixer role's `s3:GetObject` has `triage/*` prefix but `s3:ListBucket` is **explicitly Denied** to block bucket enumeration (`DenyTriageBucketEnumeration`). This allows fixer to **only GET the key passed via event**, preventing enumeration and reading of other incidents' sanitized triage. `<incident-id>` should be **unpredictable** (UUID etc.) to block key guessing. For stricter security, startup can pass a **pre-signed GET URL** for that object and remove `s3:GetObject` from fixer role (fixer has no S3 read permission at all).

## optional: issue layer (tracking / dedup, not primary path)

Since PR is already a human-review gate, **issues are not needed for gating** (direct PR is the gate; industry consensus on auto-remediation is "PR is natural review surface"). Issues can be *optionally* added as value-add for **dedup anchor / notification / human tracking**. If added, constraints apply (breaking them resurrects lethal trifecta; GitHub issue comment injection → private exfil is documented):

- **Do not let observation identity create issues** (= no GitHub egress). Issue creation goes to **fixer side, or a thin intake identity with GitHub-issue-write only** (no AWS read, input only sanitized triage object/key). Same reason as removing `StartBuild` from observation.
- **Do not make issue body/comments agent input**. Sanitization gate restricts exfiltration of raw logs/secrets/payload but **does not neutralize command injection** (free-form strings like `evidence` go straight into prompt). Fixer's primary input is **fixed to S3 sanitized triage**; if reading issues, only machine-generated text reconstructed from triage.
- **Dedup source of truth is AWS internal state, not GitHub** (DynamoDB conditional put keyed on `service+signature+resource` etc.). Conditional put is done by observe Lambda (AWS internal write, not GitHub egress, so observe boundary not broken). **If enabling this path, add `dynamodb:PutItem` + `dynamodb:DeleteItem` (dedup table ARN scope; Delete needed for claim release on handoff failure) to observation role, and pair with DynamoDB Gateway VPC endpoint for no-egress** — current [observe-identity-iam.json](observe-identity-iam.json) and endpoint list above are **intentionally excluding DynamoDB** for minimal actionable primary path privilege, requiring addition on activation. Avoid issue-as-dedup as comment edits / label operations introduce external mutable state into control surface, weakening reproducibility and boundary.

Implementation is not finalized at this design stage (keep primary path as direct PR, add with above constraints if needed).

## Pattern A / B (starting with A)

- **Pattern A (build first)**: Run `claude -p` with nearly same form as spike on CodeBuild/Fargate. With `CLAUDE_CODE_USE_BEDROCK=1` + IAM authentication in fixer role, just add `gh pr create` to the verified startup form from spike: `--safe-mode --permission-mode acceptEdits --tools Edit Read Grep --strict-mcp-config`. Reference implementation = [fixer-entrypoint.sh](fixer-entrypoint.sh) (read triage from path/S3 → fix branch → `claude -p` → PR. `DRY_RUN=1` to test before PR, `BACKEND=anthropic` for direct key verification). Linux CodeBuild/Fargate only so sh only (no `.ps1` pair — [CLAUDE.md](../../../CLAUDE.md) ephemeral/limited-environment artifact).
- **Pattern B (compare later)**: Claude Agent SDK on AgentCore Runtime. Grasp custom tools, approval gates in code. Skills/subagents/MCP work as-is. Deploy alongside A to compare "lightweight shell-pipe-like A / B with full control" (ADR decision 1).

## Approval gate and egress boundary

- **Approval gate**: Unattended until PR creation, **merge by human** (ADR decision 3 / aligns with [CLAUDE.md](../../../CLAUDE.md) "merge is user judgment"). Slack notification is auxiliary, follows after.
- **egress boundary (enforced by network, not IAM)**: Observation Lambda has **no external egress** (subnet without NAT/IGW routes). Remediation egresses only via NAT to `github.com` + Bedrock regional endpoint. To keep within VPC, pair with `bedrock-runtime` Interface VPC Endpoint (PrivateLink) (ADR decision 2). IAM Deny constrains "permission", subnet routes constrain "path", dual control.
- **VPC endpoints required on no-egress side (critical — silent timeout if omitted)**: Observation Lambda has no NAT, so **VPC endpoint required per AWS API called** — **S3 Gateway endpoint** (triage PUT) + **CloudWatch Logs Interface endpoint** (Logs Insights query / own log output). Without these, AWS API unreachable causing timeout (CodeBuild endpoint not needed since StartBuild removed from observation). Remediation side, if keeping within VPC, pair **S3 Gateway** (triage GET) + **Secrets Manager / CloudWatch Logs Interface** + **`bedrock-runtime` Interface (PrivateLink)**, leaving NAT only for `github.com` (Bedrock via PrivateLink means only github external egress).

## Implementation placement

| Artifact | Location |
|---|---|
| Wiring design + IAM templates (this dir) | main (cross-cutting reference) |
| **fixer entrypoint reference implementation** (`fixer-entrypoint.sh`) | main (repo-independent tooling like spike harness, parameterized via env) |
| **observation triage Lambda reference implementation** ([`triage-lambda/`](triage-lambda/)) | main (pure logic boto3-independent with unit tests, parameterized via env) |
| **Pattern A minimal e2e IaC** ([`infra/`](infra/) CDK: S3→EventBridge→CodeBuild fixer) | main (`cdk synth` verifiable in box, deploy on host) |
| Full wiring IaC (CloudWatch alarm / SNS / observation Lambda wiring) + Lambda triage live deployment, app-dependent log query tuning | stage branch demo app (next phase) |
| demo app (with seeded bugs) | stage branches (can reuse existing `stage/06`→`07` drift pattern) |

## build order (next steps)

1. **Pattern A minimal e2e**: Deploy [`infra/`](infra/) CDK on host → place triage in S3 → run fixer's `claude -p` in CodeBuild (direct key) → PR created (extension of spike; direct key so no Bedrock approval wait). ← IaC done, deploy on host.
2. **triage wiring**: CloudWatch 5XX alarm → SNS → Lambda (Logs Insights → actionable judgment → sanitize → S3 PUT). Startup separately wired as S3 event → EventBridge rule → StartBuild/RunTask (observation not given StartBuild).
3. **identity tightening**: Apply 2 policies to real roles, confirm on real hardware that observation cannot do Bedrock/secret, remediation cannot read incidents.
4. **Deploy B alongside** A to compare → ADR phase 4 (course material).

As each phase passes, remove ADR "residual / undecided" items, update ADR to `Proposed → Accepted` once stable.
