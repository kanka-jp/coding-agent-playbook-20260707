# spike: Can an agent on Bedrock derive fix from triage?

Validates the core hypothesis of ADR [cloud-unattended-sre.md](../../../docs/decisions/cloud-unattended-sre.md),
**without creating CloudWatch / Lambda / Fargate at all**.

> Given `claude -p` (on Bedrock) only "**sanitized triage** (structured diagnosis from observation stage) + **broken repo**",
> can it derive minimally the fix close to **known correct fix**?

## Why this form?

- **Use test case with known correct answer**: `stage/06-readings-drift-broken` (broken) and `stage/07-readings-drift-fixed` (fixed)
  already exist. Bug in 06 is upstream contract drift (readings API returns `{data:{readings:[…]}}` but contract expects
  `{readings:[…]}`), 07 is the fix. Can measure quality by comparing agent output with 07.
- **Recreate ADR identity boundary as-is**: pass agent only triage (no raw logs/secrets) + repo. **No AWS read**
  (fixer = remediation identity). Triage is fixed-schema sanitized handoff ([triage.json](triage.json)).

## Prerequisites (choose backend)

The spike measurement "**can agent fix?**" is backend-independent (billing/auth path for inference). So gate is choosable from 2 paths via `BACKEND` env (default `bedrock`):

| `BACKEND` | Requirements | Role |
|---|---|---|
| `bedrock` (default) | Below "AWS prerequisites" (1–5) | **production auth track**. For cloud-resident unattended, Bedrock with IAM role gating model access is correct. AWS credentials for billing |
| `anthropic` | `ANTHROPIC_API_KEY` + `claude` CLI (+ `python3` for triage validation) only | **Shortcut decoupling gate from AWS approval wait**. Not blocked by new-account Bedrock quota=0 (item 2 chicken-and-egg below), validate core hypothesis now. Direct key billing |

`anthropic` path does not recreate ADR identity boundary (gating model by IAM), but spike does not carry hard boundary guarantee anyway (see "boundary limitations" below), so **gate judgment validity is unchanged**. Once Bedrock approval arrives, re-run same harness with `BACKEND=bedrock`, validating also production path.

For `anthropic` to avoid interference with existing Bedrock environment, harness guards 2 points: (1) `ANTHROPIC_MODEL` requires **direct ID** (`claude-opus-4-8` etc.). Rejects remaining Bedrock inference profile ID (`global.anthropic.…` etc.). (2) Launches `claude` with **isolated empty `CLAUDE_CONFIG_DIR`**, preventing reading user's `~/.claude/settings.json` Bedrock config (`CLAUDE_CODE_USE_BEDROCK=1` etc.) (process env unset alone can be overridden by settings env override).

### AWS prerequisites (`BACKEND=bedrock`, executor-provided)

Real invoke requires Bedrock. Harness is scaffolded to work without it, will run once ready:

1. **Enable Anthropic model access**. Anthropic is via AWS Marketplace, so official prerequisites require **3 AND conditions** ([official docs](https://docs.aws.amazon.com/bedrock/latest/userguide/model-access.html)):
   - **(a) AWS Marketplace permissions**: setup identity needs `aws-marketplace:Subscribe` / `aws-marketplace:Unsubscribe` / `aws-marketplace:ViewSubscriptions` (background auto-subscription runs at first invoke, required; runtime identity after completion is invoke-only OK)
   - **(b) valid payment method**: prerequisite for AWS Marketplace purchase
   - **(c) Anthropic First Time Use (FTU) form submission**: **once per account/org** (spanning commercial regions, submit from org management account inherited by child accounts; opt-in regions need re-submit per region). **UI**: Bedrock console → Model catalog → select Anthropic model → form appears on first invoke/playground start. **CLI**: `aws bedrock put-use-case-for-model-access --form-data fileb://<path-to-json>` ([`PutUseCaseForModelAccess` API ref](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_PutUseCaseForModelAccess.html)). For fully programmatic access enable: Step 1 [`ListFoundationModelAgreementOffers`](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_ListFoundationModelAgreementOffers.html) → Step 2 `PutUseCaseForModelAccess` (Anthropic only) → Step 3 [`CreateFoundationModelAgreement`](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_CreateFoundationModelAgreement.html) → Step 4 [`GetFoundationModelAvailability`](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_GetFoundationModelAvailability.html) ([SDK/CLI steps](https://docs.aws.amazon.com/bedrock/latest/userguide/model-access.html#model-access-modify)). For setup role `AmazonBedrockFullAccess` policy is quickest
2. **Request Anthropic Claude model token quota**. New/unused accounts may initialize Anthropic TPD/TPM to `0` or low values (AWS official [docs](https://docs.aws.amazon.com/bedrock/latest/userguide/quotas-runtime.html) says "new accounts might receive reduced quotas"; this validation account observed all Anthropic Claude models at `Value: 0.0`). Check Service Quotas console, request increase if insufficient (match inference profile type: for `global.*` profile request `Global cross-Region model inference tokens per minute for Anthropic Claude <model>`; for `<region>.*` profile request `Cross-region model inference tokens per minute for ...`; raising on-demand TPM alone won't unthrottle cross-region path, must request per-path quota) ([bedrock quotas docs](https://docs.aws.amazon.com/bedrock/latest/userguide/quotas.html)). **Cross-region / Global cross-region TPM (per-minute) is `Adjustable=True`** (on-demand TPM and TPD may be `Adjustable=False`, but Support offers all 3 together when approving Cross-region TPM). **Submittable at Basic Support tier**. New accounts face "priority will be given to customers who generate traffic that consumes their existing quota allocation" ([quotas-runtime docs](https://docs.aws.amazon.com/bedrock/latest/userguide/quotas-runtime.html)) chicken-and-egg, so state **concrete use case + small token amount + short runtime** in request. If Opus 4.x hits `not available for this account`, AWS entitlement-plane / Anthropic runtime sync bug is known ([https://github.com/anthropics/claude-code/issues/51183](https://github.com/anthropics/claude-code/issues/51183)). Practical approach: approve Sonnet first, re-request Opus later
3. **Set correct inference profile ID to `ANTHROPIC_MODEL`**. Exact ID varies per account/region; if default (`us.anthropic.claude-opus-4-8`) doesn't match, confirm with `aws bedrock list-inference-profiles`, set accordingly. For ap-northeast-1: `global.anthropic.claude-sonnet-4-6` / `jp.anthropic.claude-opus-4-8` etc
4. **AWS credentials** (in execution environment). **For runtime invoke**, IAM actions are `bedrock:InvokeModel` / `bedrock:InvokeModelWithResponseStream` / `bedrock:ListInferenceProfiles` / `bedrock:GetInferenceProfile` (Converse / ConverseStream APIs also use these InvokeModel actions — `bedrock:Converse` / `bedrock:ConverseStream` are not separate IAM actions in AWS Service Authorization Reference; see AWS official [inference prerequisites](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-prereq.html). Include all for least-privilege policy; missing ones cause Deny at startup/streaming). **Setup identity on separate axis** needs item 1 (a) Marketplace permissions + `bedrock:PutUseCaseForModelAccess` etc (for auto-subscription). Runtime identity after setup is invoke-only OK. **For `global.*` cross-Region inference profile**, least-privilege role requires bedrock authorization on **3 things**: source-region inference profile + regional foundation model + regionless global foundation-model ARN; further, org SCPs must allow `unspecified` requested region (region-restricting SCPs block this). Git/gh for fixer auth goes through box proxy auth.
5. `claude` CLI and `python3` in PATH for triage schema validation

## Usage

```bash
# Default: BACKEND=bedrock, TARGET=stage/06, ANSWER=stage/07, triage=triage.json
bash examples/sre-bedrock/spike/run-spike.sh

# Varying region / model / test case (Bedrock)
AWS_REGION=us-west-2 ANTHROPIC_MODEL='us.anthropic.claude-opus-4-8-v1:0' \
  bash examples/sre-bedrock/spike/run-spike.sh

# Typical ap-northeast-1 (global cross-region inference profile)
AWS_REGION=ap-northeast-1 ANTHROPIC_MODEL='global.anthropic.claude-sonnet-4-6' \
  bash examples/sre-bedrock/spike/run-spike.sh

# Run gate with direct Anthropic key only (decouple from AWS approval wait. Set ANTHROPIC_API_KEY in env)
BACKEND=anthropic bash examples/sre-bedrock/spike/run-spike.sh

# Vary model with direct key (default claude-opus-4-8)
BACKEND=anthropic ANTHROPIC_MODEL=claude-sonnet-4-6 \
  bash examples/sre-bedrock/spike/run-spike.sh
```

> This script is **disposable validation gate run once locally on mac/Linux**, **sh version only**, no `.ps1` pair. This is an intentional scoped judgment **not applying** [CLAUDE.md](../../../CLAUDE.md) `.sh`/`.ps1` pair policy to this ephemeral artifact, distinct from CLAUDE.md's node single-implementation exception (for permanent tooling). To run on Windows host, execute above bash via Git Bash / WSL (no PowerShell 5.1 direct path).

## What it does

1. Deploy `TARGET_BRANCH` (broken stage) to **detached worktree** (don't dirty actual stage worktree)
2. Start `claude -p` per backend (`bedrock` uses `CLAUDE_CODE_USE_BEDROCK=1` + AWS credentials / `anthropic` uses direct `ANTHROPIC_API_KEY`), with only triage + repo as input for minimal fix
   (`--tools Edit Read Grep` limits available tools + `--strict-mcp-config` ignores MCP; no AWS/network tools)
3. Output agent's `git diff`
4. **Answer check**: compare files touched by known fix (`TARGET..ANSWER` diff) with files/keys agent touched (`data.readings`)
5. Clean up detached worktree

Scores (known fix file coverage / minimality = no extraneous changes / fix key detected) are **estimates**. Final judgment is human comparing agent diff with known fix:

```bash
git diff stage/06-readings-drift-broken stage/07-readings-drift-fixed
```

Triage enforces ADR sanitized handoff constraints in harness side too (size limit / **JSON parse to validate top-level shape** [`schema_version`, `incident.signature` required, unknown top-level keys rejected] / reject secret markers). Validation is via `python3` (required), not full JSON Schema validator.

## Boundary limitations (honest note)

This spike **only approximates** ADR identity separation via **`--tools Edit Read Grep` + `--strict-mcp-config` (limit available tools to repo editing, don't read MCP)**, it is **not hard boundary**:

- `claude -p` child process **carries AWS credentials in environment** for Bedrock inference (required for inference). Even if tools are narrowed, process env credentials remain.
- `Read` is **not path-scoped within repo**.

Truly guaranteeing "repo + triage only" is not spike's role but **production pipeline side's** (ADR's observation/remediation identity separation, mount/credential isolation, read confined to observation stage). Spike narrows to "can agent fix?" validation.

## Difference between spike and production pipeline

This spike checks "can agent fix?" only. Production (ADR diagram) adds on top **automatic CloudWatch→SNS→Lambda triage wiring**,
**`gh pr create` + human merge approval gate**, **observation/remediation identity separation**. If spike passes, rest is wiring.

## Judgment update

Once spike stably produces appropriate fixes, update ADR status to `Proposed → Accepted`.
If not (misfix / overfix persists even with varied test cases), review ADR for triage delivery method, allowedTools scope, model selection.
