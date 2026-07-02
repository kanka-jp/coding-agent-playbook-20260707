---
name: codex-review
description: "Asks codex (OpenAI) for a fast second opinion on a file path, diff, or code instruction, and returns its findings as an issue list or LGTM. In a box session (SANDBOX_VM_ID set) automatically delegates to /a2a-review (A2A codex pair) — the caller does not need to detect the environment. In a host session calls the host codex CLI directly. Use when the user asks for a codex review or second opinion, mentions codex review / look at with fresh eyes / have codex review it, or when /pr-ci needs the codex step. A thin wrapper over `codex exec --skip-git-repo-check` on host, or /a2a-review on box (leaf-layer skill per rules/skills.md, not an orchestrator)."
---

# codex-review

Leaf skill ([rules/skills.md](../../../rules/skills.md)) that **directly invokes the codex (OpenAI) CLI installed on host** to get a second opinion on PR diff / file / code snippet. Host counterpart to `/a2a-review` — the role (fast second opinion from 1 codex) and contract (adopt only correctness / security / regression / skip nice-to-have) are identical, **only transport differs** (no A2A pair, directly exec host codex CLI).

For box-native `/pr-codex-ci` flow vs. creating and post-processing PR from host, composed from `/pr-ci` as the codex entry point. A proactively invoked second opinion from host claude; handling of other reviews already posted on PR is separate skill `/pr-review-respond` (don't confuse).

## Prerequisites

- **In box session, automatically delegates to `/a2a-review`** (see step 1). The caller can invoke this skill without being aware of the environment
- **In host session, directly invoke host `codex` CLI**
- **`codex` CLI is pre-installed on host**: `which codex` should return a path. If not installed, HOTL escalate (below)
- **`codex login` is done**: OpenAI subscription authenticated via OAuth login. If not authenticated, CLI fails with auth error
- **Skill that sends data to external AI**: Explicitly warn at startup. Display "⚠️ Sending code / diff to external AI (OpenAI Codex)" before execution

## Usage

Arguments = review target. Repo-root relative file path / `diff` / free-form instruction (Japanese OK). If empty, ask what to review first.

### Procedure

1. **Environment check**:
   - **Box environment → delegate to `/a2a-review` and exit**: Check `printenv SANDBOX_VM_ID || true`; if it has a value, **display "⚠️ Sending code / diff to external AI (OpenAI Codex)" in 1 line then invoke `/a2a-review <argument>` and return its result as-is** (box's `codex` CLI is installed in sbx/Dockerfile but has separate auth context from host; host's `codex login` state doesn't reach box, so don't use host CLI. `/a2a-review` is the box-native equivalent skill):
     > "⚠️ Sending code / diff to external AI (OpenAI Codex)"
     > "Running in box, delegating to `/a2a-review`."
   - Check if host has codex CLI with `which codex`
   - If not, stop this skill and HOTL escalate:
     > "host codex CLI not found. Install with `npm i -g @openai/codex`, authenticate OpenAI subscription with `codex login`, then re-invoke `/codex-review`. Or switch to box session and use `/a2a-review` (box-native equivalent skill) (start with `bash scripts/dev.sh <NAME>`)."

2. **Data transmission warning**: Display "⚠️ Sending code / diff to external AI (OpenAI Codex)" in 1 line.

3. **Assemble instruction** (see "Instruction assembly" below)

4. **Execute**: Pass long-form prompt via stdin redirect. **Temp file may not exist in `.claude/tmp/` in fresh clone, so run `mkdir -p` first; also add unique name (session id short form / PID suffix etc) to avoid parallel invoke collisions**:
   ```bash
   mkdir -p .claude/tmp
   # Write as PROMPT_FILE=.claude/tmp/codex-review-prompt-<unique-suffix>.md
   # codex exec PROMPT positional explicitly uses `-` (stdin) (official CLI ref: `string | -` form)
   codex exec --skip-git-repo-check -s read-only - < "$PROMPT_FILE"
   ```
   If you want to raise reasoning effort (for complex PR diff tasks etc), add `-c 'model_reasoning_effort="high"'` (keep `-s read-only` and `-`):
   ```bash
   codex -c 'model_reasoning_effort="high"' exec --skip-git-repo-check -s read-only - < "$PROMPT_FILE"
   ```
   `-s read-only` is **mandatory**: PR review is inherently a read-only role; don't give codex workspace write permission (structurally block the path where codex might accidentally edit/execute host files during review. `/a2a-review` side has the same sandbox constraint). `-` (positional PROMPT placeholder) is the official-ref-compliant form to explicitly show codex CLI reads prompt from stdin (works without it currently, but required for contract alignment). `--cd` not needed (codex reads current cwd). Delete temp prompt file after execution.

5. **If CLI fails with auth / network error**, stop this skill and HOTL escalate (don't silently stop / don't offer choices):
   > "codex CLI failed with `<error summary>`. Recovery options:
   > - If auth error, re-authenticate with `codex login`
   > - If network error, verify connection then re-invoke `/codex-review`
   > - Switch option: use `/a2a-review` in box session (start with `bash scripts/dev.sh <NAME>`)"

6. See "Result presentation" below

**Instruction assembly**: Turn argument into 1 review instruction. codex reads the repo in cwd by itself, so **pass path/diff in the instruction**:

- File: `review tools/a2a-review/codex-a2a-server/server.py from correctness / edge-case perspective`
- Diff: `review git diff origin/main...HEAD from correctness / security / regression perspective`
- Worktree: `review git -C .worktrees/<NN>/ diff HEAD` — explicitly specify tree with `-C`

Standard prompt for PR diff review (use this when called from `/pr-ci`):

```text
Please review the following PR diff from the perspective of correctness / security / regression / existing contract violations.

base: <base-ref> (example: origin/main)
diff: output of `git diff <base-ref>...HEAD`

Adoption policy:
- Should adopt: clear correctness bug / security vulnerability / regression / existing contract (type / test / spec) violation
- Should not adopt: nice-to-have improvement suggestions / future extensions / refactor recommendations / comment addition recommendations (avoid addition bias)

If LGTM, return that in 1 line. If there are findings, return as bulleted list: file:line + severity (correctness / security / regression / contract) + fix suggestion.
```

**Result presentation**: Summarize codex's final artifact (findings or LGTM) and return to user. codex's findings are **second opinion**; adoption decision is made by claude / user (don't use 1 AI's findings as independent basis). Display results under `## Codex (OpenAI)` heading.

## Troubleshooting

| Issue | Resolution |
|------|------|
| `which codex` is empty | Install with `npm i -g @openai/codex`, then authenticate with `codex login` |
| `codex login` not done / expired | Run `codex login` on host |
| Network error (behind proxy etc) | Check host network settings. If going through socks/http proxy, verify `HTTPS_PROXY` env reaches codex |
| Findings too broad (lots of nice-to-have) | Explicitly state in instruction "skip nice-to-have", "correctness / security / regression only" (see standard prompt above). Raising reasoning effort to `--xhigh` can make output overly detailed; `high` is sufficient for PR review use |
| Invoked this skill inside box | step 1 auto-detects and delegates to `/a2a-review`, no special action needed. If reviewer unreachable error appears after delegation, follow `/a2a-review` troubleshooting |
| Result mixed with tool-use narration (thought process) | codex may include reasoning trace in stream output. Extract only final artifact when displaying |
