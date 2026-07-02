# Box Personas and Permission Tiers

Conventions for running coding agent **separated by permission tier into distinct boxes / identities**.
Never mix normal development (write) · AWS observability investigation (read-only) · deploy (host privileged).
See [box-ops.md](box-ops.md) for overall execution model, [pr-followup.md](pr-followup.md) for PR lifecycle.

## Why Separate (Principles)

Apply principles common to industry SRE/agent security practices (AWS DevOps Agent's read-first · Agent Space per environment,
PagerDuty's Review/Autonomous gate, WorkOS's agent identity isolation, CoSAI's JIT permissions,
Simon Willison's lethal trifecta, Grafana MCP's opt-in read-only) to this playbook.

- **P1 read-first / write-gated**: Investigation (read) runs autonomously; fixes and re-deploy (write/remediation) require human approval.
- **P2 distinct identity and credential per persona**: Don't reuse one broad credential / don't borrow user's credential.
- **P3 no standing privileges**: Short-lived, task-scoped, revoke immediately. Long-term full-access key baked-in is anti-pattern (blast radius).
- **P4 read-only boundary enforced at permission layer (IAM)**: Not at tool layer (CLI/MCP). Enforce read-only via IAM role.
- **P5 observational data (log bodies) is untrusted**: Avoid simultaneous occurrence of lethal trifecta (private data + untrusted content + external comms).
  Observational persona holds private data (AWS read) and untrusted content (logs), so
  **narrow external comms to AWS API endpoints only** to break trifecta.

## Persona Matrix

| persona | execution location | repo | git | AWS cred | network | role |
|---|---|---|---|---|---|---|
| **dev box** | sbx microVM | bind-mount (write) | push/PR | none | github + codex pair + MCP | Normal development, implementation, codex review, PR |
| **observe box** | sbx microVM | **clone copy** (`dev.sh observe` = `--clone .`. No host checkout mount = don't pollute host repo = read-only equivalent, no push. Includes committed runbook) | none | read-only, short-lived session, scoped | **AWS read API endpoint only** (no CDN) | AWS observability investigation (read logs/state) |
| **host** | host | working tree | — | write/deploy | full | deploy/destroy, headful browser confirmation, bridge responses |

**Invariants**:
- AWS cred for write/deploy is **host only**. Observe box is **read-only cred only**. Dev box is **zero AWS cred**.
- Identity is separated into 3 (P2). Observe box's cred is **short-lived session minted by host and injected at runtime**;
  no `AssumeRole` inside box (explicitly Deny `sts:AssumeRole` in IAM. Prevent credential broker role. P3).
- **Don't view apps (CDN/browser) from observe box** (allowing CDN lets exfiltrate observational data via `https://<cdn>/<path>` = trifecta returns. P5). View from credential-less side (host or dev box's headless chrome).

## CLI Default, MCP Optional

Read-only boundary is enforced by IAM (P4), so CloudWatch MCP etc. are **not required**. Observe box defaults to **`aws` CLI**
(minimal, reproducible by clone). MCP is optional only when you want pre-built observational tools (anomaly/analyze) or unified multi-service interface
(MCP tool surface itself adds prompt-injection surface, so minimal excludes it).
See [../examples/observe/runbook.md](../examples/observe/runbook.md) for concrete commands, [../examples/observe/readonly-iam-policy.json](../examples/observe/readonly-iam-policy.json) for read-only IAM.

## User Stories

### US1 Normal Development (dev box) ※ Main
In dev box: worktree → implement → `/a2a-review` → `gh pr create` → `/pr-codex-ci` → merge-ready.
AWS cred doesn't appear in this flow. Most work here.

### US2 Host-side Use Cases (privileged / manual)
- **deploy**: `npm run deploy` on host (write cred host-only) → note output URL (**don't commit** · share via voice/private note).
  Cleanup with `cdk destroy` (stop NAT/ALB/Fargate billing).
- **headful verification**: View deployed URL in host Chrome / from box use cdp-bridge ([headful-bridge.md](../docs/headful-bridge.md)) or
  after `sbx policy allow` CDN, view via dev box's headless chrome-devtools MCP (dev box holds no AWS cred so trifecta fails).
- **bridge**: Box only sees host, so `/host-ask` and host answers with `/host-answer`.

### US3 AWS Investigation (observe box) ※ Production operations/maintenance version
Abnormality in deployed environment (e.g., diagnosis returns 502) → spin up observe box, host-minted read-only session reads
`external_call{kind:upstream,path:...}` from `aws logs filter-log-events` etc. → structured logs directly become diagnostic material → identify root cause.
**read=observe box autonomous / fix=dev box(write) / redeploy=host(privileged)** = read-first, write-gated 3-tier (P1).
Default is **Review-equivalent** (human approves fix/redeploy). Autonomous auto-remediation not covered (safer for teaching materials).

## Public Repository Constraints

Don't **commit** real URLs / account IDs / ARNs / log group names ([../README.md](../README.md) / assumes public repo).
Commit only placeholder-containing templates and runbooks. Real values injected at runtime via env/file, runtime notes placed in
`.claude/tmp/` (gitignore'd).
