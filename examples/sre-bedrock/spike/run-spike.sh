#!/usr/bin/env bash
# ADR cloud-unattended-sre.md core hypothesis spike: can claude -p
# derive appropriate fix from only sanitized triage + broken repo, without infrastructure.
# Two paths via BACKEND=bedrock (default, production auth track) / BACKEND=anthropic (direct Anthropic key,
# decouple gate from AWS approval wait). See spike/README.md for prerequisites.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# Resolve repo root via git to work even in worktree (committed script works even when mounted at different paths)
REPO_ROOT="$(git -C "$HERE" rev-parse --show-toplevel)"

TARGET_BRANCH="${TARGET_BRANCH:-stage/06-readings-drift-broken}"
ANSWER_BRANCH="${ANSWER_BRANCH:-stage/07-readings-drift-fixed}"
TRIAGE="${TRIAGE:-$HERE/triage.json}"
REGION="${AWS_REGION:-us-east-1}"
# backend: bedrock (default) = AWS IAM billing / anthropic = direct Anthropic key (requires ANTHROPIC_API_KEY).
# Spike measurement "can agent fix?" is backend-independent, so can run gate with direct key while waiting AWS approval.
BACKEND="${BACKEND:-bedrock}"
# Model default differs per backend (Bedrock is inference profile ID / direct key is Anthropic model ID)
# resolved in backend dispatch. If explicit ANTHROPIC_MODEL present, both backends prefer it.

command -v claude >/dev/null || { echo "ERROR: claude CLI not in PATH" >&2; exit 1; }
[ -f "$TRIAGE" ] || { echo "ERROR: triage not found: $TRIAGE" >&2; exit 1; }

# ADR's sanitized handoff constraints (size-limited / fixed schema / no raw logs/secrets) also enforced in harness.
# If TRIAGE override allowed arbitrary raw file load, ADR boundary recreation would collapse.
TRIAGE_BYTES="$(wc -c < "$TRIAGE" | tr -d ' ')"
[ "${TRIAGE_BYTES:-0}" -le 8192 ] || { echo "ERROR: triage too large (${TRIAGE_BYTES}B > 8192). sanitized handoff is size-limited." >&2; exit 1; }
if grep -qiE -- '-----BEGIN|aws_secret_access_key|PRIVATE KEY' "$TRIAGE"; then echo "ERROR: detected secret-like content in triage (no raw logs/secrets)." >&2; exit 1; fi
# Fixed schema: actually parse JSON and validate top-level shape (not substring) to reject malformed JSON or
# extraneous payload. Make python3 mandatory and fail fast (degrading to grep when missing would relax
# sanitized handoff boundary verification).
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required for triage schema validation." >&2; exit 1; }
python3 - "$TRIAGE" <<'PY' || exit 1
import json, sys
allowed = {"schema_version", "_note", "incident", "constraints"}
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    sys.exit("ERROR: triage が valid JSON でない: %s" % e)
if not isinstance(d, dict):
    sys.exit("ERROR: triage の top-level が object でない")
extra = set(d) - allowed
if extra:
    sys.exit("ERROR: triage に未知の top-level キー: %s" % sorted(extra))
if "schema_version" not in d:
    sys.exit("ERROR: triage に schema_version がない")
inc = d.get("incident")
if not isinstance(inc, dict) or "signature" not in inc:
    sys.exit("ERROR: triage に incident.signature がない")
PY

# Validate backend and resolve model (fail-fast, no side effects). env setup and config isolation after trap established.
case "$BACKEND" in
  bedrock)
    MODEL="${ANTHROPIC_MODEL:-us.anthropic.claude-opus-4-8}"
    BACKEND_LABEL="Bedrock ($MODEL @ $REGION)"
    FAIL_HINT="Check Bedrock model access / AWS credentials / region."
    ;;
  anthropic)
    [ -n "${ANTHROPIC_API_KEY:-}" ] || { echo "ERROR: BACKEND=anthropic requires ANTHROPIC_API_KEY." >&2; exit 1; }
    MODEL="${ANTHROPIC_MODEL:-claude-opus-4-8}"
    # If ANTHROPIC_MODEL previously exported for Bedrock (inference profile ID *.anthropic.*) leaks to direct API,
    # fails with invalid model (direct ID is form like 'claude-opus-4-8'), so reject it.
    case "$MODEL" in
      *anthropic.*) echo "ERROR: BACKEND=anthropic given Bedrock-format model ID ($MODEL). Direct API uses IDs like 'claude-opus-4-8'. Unset ANTHROPIC_MODEL or specify direct ID." >&2; exit 1 ;;
    esac
    BACKEND_LABEL="Anthropic API ($MODEL)"
    FAIL_HINT="Check ANTHROPIC_API_KEY / model ID ($MODEL)."
    ;;
  *)
    echo "ERROR: BACKEND must be bedrock or anthropic (specified: $BACKEND)" >&2; exit 1
    ;;
esac

# Deploy broken stage to detached worktree (detach to avoid double checkout of same-named branch).
# Immediately after clone, stage may not be in local refs (only origin/<branch>), so resolve commit-ish.
resolve_ref() {
  # Resolve with explicit refs/heads → refs/remotes/origin to avoid picking up same-named tags etc.
  if git -C "$REPO_ROOT" rev-parse --verify --quiet "refs/heads/$1^{commit}" >/dev/null 2>&1; then printf '%s' "refs/heads/$1"
  elif git -C "$REPO_ROOT" rev-parse --verify --quiet "refs/remotes/origin/$1^{commit}" >/dev/null 2>&1; then printf '%s' "refs/remotes/origin/$1"
  else return 1; fi
}
TARGET_REF="$(resolve_ref "$TARGET_BRANCH")" || { echo "ERROR: cannot resolve $TARGET_BRANCH in local or origin. After clone, run 'bash scripts/internal/setup-worktrees.sh' to deploy stages." >&2; exit 1; }
ANSWER_REF="$(resolve_ref "$ANSWER_BRANCH")" || { echo "ERROR: cannot resolve $ANSWER_BRANCH in local or origin." >&2; exit 1; }

WORK="$(mktemp -d)"
CLAUDE_CONFIG_TMP=""
# Beyond worktree remove, delete temp dir itself (prevent empty/partial dir on add failure). Also anthropic isolated config dir.
cleanup() {
  git -C "$REPO_ROOT" worktree remove --force "$WORK" >/dev/null 2>&1 || true
  rm -rf "$WORK" 2>/dev/null || true
  [ -n "$CLAUDE_CONFIG_TMP" ] && rm -rf "$CLAUDE_CONFIG_TMP" 2>/dev/null || true
}
trap cleanup EXIT
git -C "$REPO_ROOT" worktree add --detach "$WORK" "$TARGET_REF" >/dev/null

PROMPT="You are an SRE agent performing minimal fixes for production incidents. The following is sanitized triage passed from observation stage (no raw logs/secrets. repo and this triage are the only inputs, cannot reach AWS or network). Locate the failure signature in the triage within the repo and apply minimal fix. Make no unrelated changes or refactor. After fixing, state the change in one sentence.
--- triage ---
$(cat "$TRIAGE")"

# Set backend env (after trap established). For anthropic, launch with isolated empty CLAUDE_CONFIG_DIR to prevent
# user's Bedrock settings.json re-injecting CLAUDE_CODE_USE_BEDROCK and reverting direct key path to Bedrock
# (process env unset alone is known to be overridden by settings.json env override, so don't read config itself).
if [ "$BACKEND" = bedrock ]; then
  # Bedrock backend (billing via AWS IAM, not subscription/Anthropic key).
  export CLAUDE_CODE_USE_BEDROCK=1
  export AWS_REGION="$REGION"
  export ANTHROPIC_MODEL="$MODEL"
else
  CLAUDE_CONFIG_TMP="$(mktemp -d)"
  export CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_TMP"
  unset CLAUDE_CODE_USE_BEDROCK
  export ANTHROPIC_MODEL="$MODEL"
fi

echo ">> running claude -p on $BACKEND_LABEL against $TARGET_BRANCH..."
# Limit available tools to Edit/Read/Grep with --tools (--allowedTools is auto-approve only, doesn't restrict).
# --permission-mode acceptEdits: headless -p leaves Edit in approval-wait and fix is lost even if agent can fix, so auto-approve.
# --safe-mode: under auto-approval, Edit/Write hooks in environment (Bash blocked from --tools but shell can run via hook) or
# additionalDirectories in settings can reach outside worktree, so block hooks/plugins/customizations from loading
# (auth/model/permission work normally). Sandbox ensured by --tools + safe-mode + worktree isolation.
# --strict-mcp-config: don't read project's MCP (don't add egress surface). Intent: no AWS/network output.
if ! ( cd "$WORK" && claude -p "$PROMPT" --tools Edit Read Grep --safe-mode --permission-mode acceptEdits --strict-mcp-config ); then
  echo "ERROR: claude -p execution failed. $FAIL_HINT" >&2
  exit 1
fi

echo
echo "===== agent's fix diff ====="
AGENT_DIFF="$(git -C "$WORK" diff)"
echo "${AGENT_DIFF:-（no changes）}"

# Answer check: compare files touched by known fix (TARGET..ANSWER).
ANSWER_FILES="$(git -C "$REPO_ROOT" diff --name-only "$TARGET_REF" "$ANSWER_REF")"
AGENT_FILES="$(git -C "$WORK" diff --name-only)"

echo
echo "===== answer check (estimates; human makes final judgment) ====="
echo "files touched by known fix:"; echo "$ANSWER_FILES" | sed 's/^/  /'
echo "files touched by agent:"; echo "${AGENT_FILES:-  （none）}" | sed 's/^/  /'

# Did agent touch all known fix files? (coverage check)
files_match=1
while IFS= read -r f; do
  [ -z "$f" ] && continue
  printf '%s\n' "$AGENT_FILES" | grep -qxF "$f" || files_match=0
done <<EOF
$ANSWER_FILES
EOF

# Did agent touch files outside known fix? (minimality check; subset-only would miss overfix).
extra_files=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  printf '%s\n' "$ANSWER_FILES" | grep -qxF "$f" || extra_files="$extra_files $f"
done <<EOF
$AGENT_FILES
EOF

# This bug's fix key is correcting readings wrapped by data (data.readings format).
if printf '%s' "$AGENT_DIFF" | grep -q 'data\.readings\|data:'; then key_found=1; else key_found=0; fi

echo
echo "known fix file coverage: $([ "$files_match" = 1 ] && echo OK || echo NG)"
echo "minimality (no extraneous changes): $([ -z "$extra_files" ] && echo "OK" || echo "NG (extra:${extra_files} )")"
echo "fix key (data.readings family) detected: $([ "$key_found" = 1 ] && echo detected || echo not-detected)"
echo
echo "※ read against known fix to make final judgment:"
echo "   git diff $TARGET_REF $ANSWER_REF"
