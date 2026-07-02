# triage-lambda: Observe-side triage reference implementation

The **observe identity (Lambda)** body from [pipeline/README.md](../README.md). CloudWatch 5xx alarm → SNS triggers,
pulls relevant logs via Logs Insights → **actionability judgment** → assembles **sanitized triage** → dedup in DynamoDB →
**PUTs to S3** (observe output stops here). Never touches GitHub (identity boundary). Subsequent trigger:
S3 event → EventBridge → fixer ([fixer-entrypoint.sh](../fixer-entrypoint.sh)).

| File | Role |
|---|---|
| `triage_core.py` | Pure logic (**boto3-independent**): schema validation / secret redaction / dedup key / actionability judgment / size limit. Kept equivalent to spike / fixer |
| `handler.py` | Lambda handler: wraps `triage_core` with boto3 I/O (Logs Insights / S3 / DynamoDB) |
| `test_triage_core.py` | Unit test (stdlib `unittest`, **no AWS needed**). Run: `python3 -m unittest test_triage_core` |

## Design points

- **Observe has no GitHub egress**. No issue creation / PR submission (see [pipeline/README.md](../README.md) "2 identities" "optional: issue layer").
- **Sanitize limits data export but doesn't neutralize injection**. `evidence` is redacted + size-summarized, but final injection resistance is guaranteed by "fixer reads only triage" design.
- **Dedup is DynamoDB (signature key), not S3 key**. S3 object key is unpredictable (`uuid4`) to block fixer-side enumeration/guessing.
- **Schema stays equivalent to spike/triage.json and fixer-entrypoint.sh** (drift causes reject on fixer identity side).

## Verified scope (box) vs. remaining (AWS)

- **Verified in box**: `triage_core` pure logic unit-tested (schema rejection / secret redaction / dedup slug / actionability threshold / size limit).
- **Integration in AWS needed**: `handler.py`'s Logs Insights query / S3 PutObject / DynamoDB conditional put, and IaC (IAM role at [observe-identity-iam.json](../observe-identity-iam.json); if using dedup, add `dynamodb:PutItem` + `dynamodb:DeleteItem` (claim release) + DynamoDB Gateway endpoint). `_query_logs` signature extraction is **app-dependent**, so adjust for real app (reference implementation).

Python only (Linux Lambda runtime); no PowerShell pair.
