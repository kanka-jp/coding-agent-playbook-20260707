# infra: Pattern A minimal e2e CDK (deploy on host)

CDK (TypeScript) deploying [pipeline/README.md](../README.md) build order step 1 "Pattern A minimal e2e" to real AWS.

```
PUT sanitized triage to S3  ->  EventBridge(Object Created, prefix triage/)  ->  CodeBuild(fixer identity)
   run fixer-entrypoint.sh with BACKEND=anthropic | bedrock (triage + broken repo -> claude -p -> PR)
```

Automatic wiring of CloudWatch alarm → observation Lambda ([triage-lambda/](../triage-lambda/)) is added on top. This stack is
**the phase to verify "fixer runs on real AWS and PR is created"** at minimal cost.

Backend is switchable via context flag `-c backend=anthropic|bedrock` (default anthropic):
- **anthropic** (default): direct Anthropic API key path. Works on accounts without Bedrock model access. Load key into secret
- **bedrock**: via AWS Bedrock (production path). Account must have Bedrock Claude model access. No Anthropic key secret created; fixer role gets `bedrock:InvokeModel` ALLOW for inference profile + foundation model

## Verified / Not verified

- **Verified in box**: `npm ci && npm run build && cdk synth` (CloudFormation generation, type, construct errors). Confirmed 3 IAM Deny policies (`s3:ListBucket` / incident app-data read / `sts:AssumeRole*`), secret fetched in build phase (`gh auth setup-git` leaves no token in `.git/config`), event-derived key override appears in template.
- **Real AWS required (on host)**: actual deploy, claude/gh execution inside CodeBuild, S3 event wiring, actual PR creation. From `cdk deploy` onward: host work under AWS credentials.

## Prerequisites (host)

- Node 18+ / AWS CLI / AWS CDK (`npx cdk` ok too).
- AWS credentials for deploy (permission to create CloudFormation/S3/CodeBuild/IAM/Events/Secrets). **Do not put in dev box** (persona: deploy on host).
- **repo-scoped GitHub token** with push + PR creation to target repo.
- backend=anthropic: direct Anthropic API key (`sk-ant-...`).
- backend=bedrock: account-level access to target Bedrock Claude model (AWS console → Bedrock → Model access).

## Procedure (host)

```bash
cd examples/sre-bedrock/pipeline/infra
npm ci
npm run build                      # tsc (cdk.json runs bin/app.js)

# First time only: bootstrap account/region
npx cdk bootstrap

# deploy (targetRepo required. backend / anthropicModel / targetBranch / prBase optional)
# Default backend=anthropic (direct key path):
npx cdk deploy \
  -c targetRepo=<owner>/<repo> \
  -c targetBranch=stage/06-readings-drift-broken \
  -c prBase=stage/06-readings-drift-broken

# backend=bedrock (production path). anthropicModel is inference profile id (default global.anthropic.claude-opus-4-6-v1):
npx cdk deploy \
  -c backend=bedrock \
  -c targetRepo=<owner>/<repo> \
  -c targetBranch=stage/06-readings-drift-broken \
  -c prBase=stage/06-readings-drift-broken
```

After deploy, **load actual values into Secrets** (not baked into IaC, manual load; logical names from output Secret ARN):

```bash
# For backend=anthropic, load both AnthropicApiKey + FixerGithubToken
aws secretsmanager put-secret-value --secret-id <AnthropicApiKey ARN> --secret-string 'sk-ant-...'
aws secretsmanager put-secret-value --secret-id <FixerGithubToken ARN> --secret-string 'ghp_...'

# For backend=bedrock, AnthropicApiKey not created (IAM allows InvokeModel). Load GitHub token only
aws secretsmanager put-secret-value --secret-id <FixerGithubToken ARN> --secret-string 'ghp_...'
```

### Trigger e2e

Place sanitized triage (same form as [../../spike/triage.json](../../spike/triage.json)) under `triage/` prefix in S3, EventBridge starts CodeBuild:

```bash
aws s3 cp ../../spike/triage.json "s3://<TriageBucket name>/triage/$(uuidgen).json"
# CodeBuild runs, fix PR created in target repo. Logs: CodeBuild console / CloudWatch Logs
```

### Cleanup

```bash
npx cdk destroy
```

## Prerequisites within CodeBuild (buildspec provided)

Against CodeBuild standard image, buildspec loads `@anthropic-ai/claude-code` (pinned version) and `gh` (pinned binary if missing) in install phase, **fetches `GH_TOKEN` (+ `ANTHROPIC_API_KEY` for backend=anthropic) via `aws secretsmanager get-secret-value` in build phase** (no secret exposed to unfixed code during install), authenticates via `gh auth setup-git` leaving no token in `.git/config`, runs `fixer-entrypoint.sh` with env `BACKEND`, `ANTHROPIC_MODEL`, `TRIAGE_S3_KEY` (event-derived). Fixer has **only GET one triage + fetch own secret + (for backend=bedrock) InvokeModel on specified inference profile/foundation model** (bucket enumeration, incident log read, other model calls are IAM Deny / not permitted).

## Difference from production (not done in this stack)

- automatic triage generation via CloudWatch alarm → SNS → observation Lambda (replaced by manual S3 PUT).
- VPC isolation between observation/remediation, PrivateLink ([pipeline/README.md](../README.md) "egress boundary").
