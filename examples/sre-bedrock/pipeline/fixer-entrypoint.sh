#!/usr/bin/env bash
# ADR cloud-unattended-sre.md pattern A fixer entrypoint (reference implementation).
# Body run by CodeBuild/Fargate (remediation identity): takes only sanitized triage + broken repo as input,
# creates minimal fix with claude -p on Bedrock, opens PR unattended (merge by human). Reuses spike harness's
# verified startup form (--safe-mode --permission-mode acceptEdits --tools Edit Read Grep --strict-mcp-config),
# does commit→push→gh pr create instead of "answer check". AWS/real repo parts can be disabled with DRY_RUN.
#
# execution prerequisites (fixer-identity-iam.json permissions): Bedrock invoke / GET one triage / own GH token / cannot read app data.
# cwd must be **broken-state checkout of repo to fix** (CodeBuild source). Entrypoint creates fix branch on-the-spot.
#
# env:
#   TRIAGE_PATH     local path of sanitized triage JSON (not needed if TRIAGE_S3_URI specified)
#   TRIAGE_S3_URI   s3://bucket/triage/<incident-id>.json (only input observation passes via event. fetched with aws s3 cp)
#   BACKEND         bedrock (default, production) / anthropic (direct key, verification)
#   AWS_REGION      for bedrock (default us-east-1)
#   ANTHROPIC_MODEL bedrock=inference profile id (default us.anthropic.claude-opus-4-8) / anthropic=direct ID (claude-opus-4-8)
#   FIX_BRANCH      name of fix branch to create (default sre-fix/<incident-id|epoch>)
#   PR_BASE         PR base branch (default: origin's default branch)
#   DRY_RUN         if 1, output diff and skip commit/push/PR (for verification without AWS/real repo)
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
BACKEND="${BACKEND:-bedrock}"

command -v claude >/dev/null || { echo "ERROR: claude CLI not in PATH" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required for triage validation" >&2; exit 1; }
# For PR-creation path (non-DRY_RUN), check gh first. Discovering gh is missing after expensive claude -p
# means only branch pushed, no PR created. Use DRY_RUN=1 if just want to see generation, gh not needed.
[ "${DRY_RUN:-}" = 1 ] || command -v gh >/dev/null || { echo "ERROR: gh CLI missing (required for PR creation). Generation only with DRY_RUN=1." >&2; exit 1; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "ERROR: cwd not a git repo (run in target repo checkout)" >&2; exit 1; }
# Enforce starting from clean checkout (so later git add -A picks only agent's fix, not pre-existing dirty).
[ -z "$(git status --porcelain)" ] || { echo "ERROR: checkout is dirty (run from clean target checkout)" >&2; exit 1; }

# Get triage. Only via aws s3 cp when S3 specified (read verified object written by observation as sole input).
CLEAN_TRIAGE=""
cleanup() { [ -n "$CLEAN_TRIAGE" ] && rm -f "$CLEAN_TRIAGE" 2>/dev/null || true; }
trap cleanup EXIT
if [ -n "${TRIAGE_S3_URI:-}" ]; then
  command -v aws >/dev/null || { echo "ERROR: aws CLI required to specify TRIAGE_S3_URI" >&2; exit 1; }
  CLEAN_TRIAGE="$(mktemp)"; TRIAGE_PATH="$CLEAN_TRIAGE"
  aws s3 cp "$TRIAGE_S3_URI" "$TRIAGE_PATH" --only-show-errors || { echo "ERROR: failed to fetch triage from S3: $TRIAGE_S3_URI" >&2; exit 1; }
fi
[ -n "${TRIAGE_PATH:-}" ] && [ -f "$TRIAGE_PATH" ] || { echo "ERROR: neither TRIAGE_PATH nor TRIAGE_S3_URI valid" >&2; exit 1; }

# Enforce sanitized handoff constraints on fixer side (size limit / fixed schema / no raw logs/secrets).
# Following spike validation, for unattended cloud fixer also allowlist nested keys in incident/constraints
# to prevent unexpected fields going straight into prompt (sanitization gate stricter than spike). Invalid validation doesn't proceed.
TRIAGE_BYTES="$(wc -c < "$TRIAGE_PATH" | tr -d ' ')"
[ "${TRIAGE_BYTES:-0}" -le 8192 ] || { echo "ERROR: triage が大きすぎます (${TRIAGE_BYTES}B > 8192)" >&2; exit 1; }
if grep -qiE -- '-----BEGIN|aws_secret_access_key|PRIVATE KEY' "$TRIAGE_PATH"; then echo "ERROR: triage に secret らしき内容を検出" >&2; exit 1; fi
INCIDENT_ID="$(python3 - "$TRIAGE_PATH" <<'PY'
import json, sys
allowed = {"schema_version", "_note", "incident", "constraints"}
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    sys.exit("ERROR: triage が valid JSON でない: %s" % e)
if not isinstance(d, dict): sys.exit("ERROR: triage の top-level が object でない")
extra = set(d) - allowed
if extra: sys.exit("ERROR: triage に未知の top-level キー: %s" % sorted(extra))
if "schema_version" not in d: sys.exit("ERROR: triage に schema_version がない")
inc = d.get("incident")
if not isinstance(inc, dict) or "signature" not in inc: sys.exit("ERROR: triage に incident.signature がない")
allowed_incident = {"service", "signature", "http_status", "failing_path", "external_call", "evidence", "first_seen", "count_5xx_window"}
inc_extra = set(inc) - allowed_incident
if inc_extra: sys.exit("ERROR: incident に未知のキー: %s" % sorted(inc_extra))
con = d.get("constraints", {})
if not isinstance(con, dict): sys.exit("ERROR: constraints が object でない")
con_extra = set(con) - {"scope", "no_raw_logs", "no_secrets", "fixer_inputs"}
if con_extra: sys.exit("ERROR: constraints に未知のキー: %s" % sorted(con_extra))
# Stable ID for fix branch / PR subject. Based on signature but triage-derived free string,
# so fold non-[a-z0-9-] to -, slug-ify, prevent whitespace/newline/`..`/`:` etc leaking into branch name/metadata
# (also drop `.`/`_` to structurally prevent invalid refname like `..` = pass through even with weird signature).
import re as _re
raw = "%s-%s" % (inc.get("service", "svc"), inc.get("signature", ""))
slug = _re.sub(r"[^a-z0-9]+", "-", raw.lower()).strip("-")[:48].strip("-")
print(slug or "incident")
PY
)" || exit 1

FIX_BRANCH="${FIX_BRANCH:-sre-fix/${INCIDENT_ID}}"
# After slug, also considering FIX_BRANCH override etc, final check that it's valid git refname format.
git check-ref-format "refs/heads/$FIX_BRANCH" || { echo "ERROR: FIX_BRANCH is invalid branch name: $FIX_BRANCH" >&2; exit 1; }

# Backend dispatch (same form as spike). For anthropic, isolate config to block user's Bedrock settings re-injection.
case "$BACKEND" in
  bedrock)
    MODEL="${ANTHROPIC_MODEL:-us.anthropic.claude-opus-4-8}"
    export CLAUDE_CODE_USE_BEDROCK=1; export AWS_REGION="$REGION"; export ANTHROPIC_MODEL="$MODEL"
    ;;
  anthropic)
    [ -n "${ANTHROPIC_API_KEY:-}" ] || { echo "ERROR: BACKEND=anthropic には ANTHROPIC_API_KEY が要ります" >&2; exit 1; }
    MODEL="${ANTHROPIC_MODEL:-claude-opus-4-8}"
    case "$MODEL" in *anthropic.*) echo "ERROR: 直 mode に Bedrock 形式 model ID ($MODEL)。'claude-opus-4-8' 等を指定" >&2; exit 1 ;; esac
    CLAUDE_CONFIG_TMP="$(mktemp -d)"; export CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_TMP"
    trap 'cleanup; rm -rf "$CLAUDE_CONFIG_TMP" 2>/dev/null || true' EXIT
    unset CLAUDE_CODE_USE_BEDROCK; export ANTHROPIC_MODEL="$MODEL"
    ;;
  *) echo "ERROR: BACKEND は bedrock | anthropic（指定: $BACKEND）" >&2; exit 1 ;;
esac

git switch -c "$FIX_BRANCH" >/dev/null 2>&1 || git switch "$FIX_BRANCH" >/dev/null

PROMPT="You are an SRE agent performing minimal fixes for production incidents. The following is sanitized triage passed from observation stage (no raw logs/secrets. repo and this triage are the only inputs, cannot reach AWS or network). Locate the failure signature in the triage within the repo and apply minimal fix. Make no unrelated changes or refactor. After fixing, state the change in one sentence.
--- triage ---
$(cat "$TRIAGE_PATH")"

# Use spike-verified startup form as-is: --safe-mode (block hook/customization auto-execution) +
# --permission-mode acceptEdits (apply Edit in headless mode) + limited --tools + --strict-mcp-config.
echo ">> generating fix with claude -p (backend=$BACKEND)..."
if ! claude -p "$PROMPT" --tools Edit Read Grep --safe-mode --permission-mode acceptEdits --strict-mcp-config; then
  echo "ERROR: claude -p execution failed (check model access / credentials)" >&2; exit 1
fi

# Change detection includes untracked (git diff --quiet misses new files, so stage and see with --cached).
# Started from clean checkout, so staged = only agent's fix.
git add -A
if git diff --cached --quiet; then echo ">> No changes (cannot fix or already fixed). Not creating PR."; exit 0; fi

echo; echo "===== fix diff ====="; git --no-pager diff --cached

if [ "${DRY_RUN:-}" = 1 ]; then echo; echo ">> DRY_RUN: skipping commit/push/PR."; exit 0; fi

# Specify PR base explicitly (omitting it makes gh implicitly adopt default branch, risk of targeting wrong branch).
# If unspecified, resolve target repo's default branch and use it.
PR_BASE="${PR_BASE:-$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null)}"
[ -n "$PR_BASE" ] || { echo "ERROR: cannot resolve PR_BASE (gh repo view failed). Specify PR_BASE explicitly." >&2; exit 1; }

git commit -q -m "fix(sre): minimal fix for ${INCIDENT_ID} (unattended SRE agent)"

# Idempotency: re-trigger of same incident_id doesn't spawn new PRs, updates existing open PR with latest fix.
# force-with-lease protects against concurrent fixer run pushes (safer than raw --force).
git fetch origin "+refs/heads/${FIX_BRANCH}:refs/remotes/origin/${FIX_BRANCH}" 2>/dev/null || true
git push -u origin "$FIX_BRANCH" 2>/dev/null \
  || git push --force-with-lease -u origin "$FIX_BRANCH"

SHORT_SHA="$(git rev-parse --short HEAD)"
PR_BODY_BASE="Minimal fix created by unattended SRE agent starting from observation stage's sanitized triage. **merge after human review** (approval gate).

incident: \`${INCIDENT_ID}\`
fixer: Pattern A (claude -p on Bedrock / remediation identity, no AWS read)
head: \`${SHORT_SHA}\`"

# If existing open PR, update body (don't create new). Ignore closed PRs (drop them, let new PR path take over).
# Beyond --base, filter isCrossRepository == false to exclude same-named head PRs from forks
# (gh pr list --head doesn't distinguish same-repo from fork, so post-filter). Protects both PR_BASE contract and repo boundary.
EXISTING_PR_NUM="$(gh pr list --head "$FIX_BRANCH" --base "$PR_BASE" --state open --json number,isCrossRepository --jq '[.[] | select(.isCrossRepository == false)][0].number // empty')"
if [ -n "$EXISTING_PR_NUM" ]; then
  echo ">> updating existing open PR #${EXISTING_PR_NUM} with head=${SHORT_SHA}, adding superseded note"
  gh pr edit "$EXISTING_PR_NUM" --body "${PR_BODY_BASE}

---
⚠️ This PR was **force-push updated** by a new fixer run. Fix from previous commit is superseded by latest head (\`${SHORT_SHA}\`)."
else
  echo ">> creating new PR"
  gh pr create --base "$PR_BASE" --title "fix(sre): ${INCIDENT_ID}" --body "$PR_BODY_BASE"
fi
