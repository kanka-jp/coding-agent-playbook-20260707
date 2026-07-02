---
name: a2a-review
description: "Sends a file path, diff, or code instruction to a codex (OpenAI) reviewer running in a separate sbx microVM that reads the same live source tree, and returns its findings as an issue list or LGTM. A fast codex-only second opinion to fire mid-implementation. Use when the user asks for a codex review or second opinion on specific code, mentions a2a review / codex review / second look / let codex review it, or to cross-check code with codex before committing. A thin wrapper over scripts/internal/a2a-review.sh (leaf-layer skill per rules/skills.md, not an orchestrator); codex reads the same source claude is editing."
---

# a2a-review

Sets up codex (OpenAI) as an A2A server in a separate sbx microVM, where **codex directly reads the same source tree that claude is editing** to perform reviews. Against multiple external AI reviews, this is a daily tool to fire a **fast codex-only second opinion** during implementation. A thin wrapper that calls the reference implementation in `tools/a2a-review/` via the host helper `scripts/internal/a2a-review.sh` (leaf layer, see [rules/skills.md](../../../rules/skills.md)) and does not re-implement A2A logic.

## Prerequisites (automatically set up from within the box)

This skill is intended to be **called from within a dev box (bind-mount) started with `bash scripts/dev.sh` (auto-name) or `bash scripts/dev.sh <NAME>` (explicit name)**. On startup, dev.sh auto-provisions the corresponding **`cdx-<NAME>` reviewer box**, forks `pair-serve` in the background, and injects the egress permission and advertise URL (`$A2A_CODEX_URL`) into the box's environment (per-pair lifecycle, auto teardown when claude box TTY exits).

One-time setup (host side only):
- `sbx` (Docker Sandboxes) + image `coding-agent-playbook-sbx` is loaded
- OpenAI OAuth secret registered: `sbx secret set -g openai --oauth`

With these in place, the **cdx-`<NAME>` reviewer box is auto-provisioned** when `bash scripts/dev.sh` starts (first run ~30s, reused thereafter). No manual setup beforehand is required.

This skill cannot be used in sandbox box (`bash scripts/dev.sh sandbox`, `--clone .` isolation) because sandbox box does not mount the host checkout and codex cannot see claude's edits. Use dev box (`bash scripts/dev.sh` series) instead.

**Reviewer location (clarified because this is often confused)**: The codex reviewer runs **in a separate sbx microVM** (`cdx-<NAME>`) from the box where claude is running. Running `ps aux | grep cdx` / `pgrep` etc. from within your box (claude box) **will not show the reviewer process** (the microVM's PID namespace is isolated). The reviewer's liveness can **only be determined by an agent-card probe** against the advertise URL in the lease file (`.claude/tmp/cdx-serve-<NAME>.lease`). Running `ps` in your own box before starting this skill and deciding the reviewer is down is incorrect ([../../../rules/pr-followup.md](../../../rules/pr-followup.md) "prohibited self-judgment"). Reviewer health checks are delegated to this skill itself (step 3: `ask` invocation → reachability check) + the caller orchestrator (`/pr-codex-ci` step 1a: lease check).

## Usage

Argument = review target. File path relative to repo-root / `diff` / free-form instruction (English/Japanese). If no argument is given, ask what to review first.

### Procedure

1. **Environment check**: Verify that the box you are running in is a dev box (bind-mount, `$SANDBOX_VM_ID` is set and started with `bash scripts/dev.sh`). If you are inside a sandbox box (`bash scripts/dev.sh sandbox` startup with `--clone .` isolation, box name has `sbx-` prefix), stop this skill and HOTL escalate:
   > "The current box is in sandbox / clone mode (host checkout is not mounted, so invisible to codex). To use `/a2a-review`, you must start from a dev box: either start a new `bash scripts/dev.sh` on the host or `bash scripts/dev.sh attach` to an existing dev box."

2. **Construct the instruction** (see "Construct the instruction" section below)

3. **Execute**: `bash scripts/internal/a2a-review.sh ask "<instruction>"` (Windows: `powershell -ExecutionPolicy Bypass -File scripts/internal/a2a-review.ps1 ask "<instruction>"`). The URL is the `$A2A_CODEX_URL` environment variable (injected by dev.sh's pair-serve) or fallback to `http://host.docker.internal:9999`.

4. **If reviewer is unreachable** (connection failed / "Blocked by network policy" / empty response): Stop this skill and output an HOTL escalate message (do not silently stop / do not offer options). **Before outputting escalate, get the value of `echo $SANDBOX_VM_ID` from within the box and replace the `<box-name>` placeholder in the message with the actual box name (literal)** (the host shell does not have the `$SANDBOX_VM_ID` environment variable; without a literal replacement, empty expansion will switch to a different session):
   > "Cannot reach codex reviewer from within the box (the cdx-`<box-name>` reviewer box may not be running, or there may be no egress permission from `sbx policy allow network`). Recovery sequence **order is important** because the box's dev session and active lock block dev.sh restart:
   > 1. **Press Ctrl-D (or `exit`) at the box terminal** to exit claude and end dev.sh normally (trap runs pair-teardown + lock cleanup)
   > 2. **Restart `bash scripts/dev.sh <box-name>`** on the host (acquire new lock + re-provision cdx pair + re-fork pair-serve)
   > 3. After startup, when claude comes up, invoke the calling skill / `/pr-codex-ci` again
   >
   > If the dev session in the box is hung and you cannot exit, force-kill the box on the host with `sbx rm -f <box-name>` → proceed to step 2 (state will be lost)."

5. See "Present results" section below

**Construct the instruction**: Make the argument a single review instruction. Codex does not receive code snippets but reads the same source directly, so **pass the path/diff in the instruction**:
- File: `tools/a2a-review/codex-a2a-server/server.py review from correctness / edge-case perspective`
- Diff: `review git HEAD diff` (since the box mounts the main checkout root, for worktree diff use `git -C .worktrees/<NN>/ diff HEAD review` to explicitly specify the tree with `-C`)

**Present results**: Summarize codex's final artifact (findings or LGTM) and return to the user. Codex's findings are **a second opinion**; adoption/rejection is decided by claude / the user (do not treat a single AI finding as independent grounds).

## Troubleshooting

| Problem | Solution |
|------|------|
| `Cannot reach codex reviewer from within the box` | Follow the HOTL escalate message above (restart `bash scripts/dev.sh <box-name>` on host. Replace `<box-name>` with the literal value from `echo $SANDBOX_VM_ID` in the box) |
| `cdx-<NAME>` box was not auto-provisioned | Check OpenAI secret registration on host: `sbx secret ls -g \| grep openai`, if not registered run `sbx secret set -g openai --oauth` |
| `server won't start` | Check both host log (`.claude/tmp/cdx-serve-<NAME>.log` = pair-serve sbx ports / policy / startup echo) and box log (`sbx exec cdx-<NAME> cat /tmp/a2a-server.log` = server.py internals) |
| Want to review a different tree (worktree etc.) | Since the box mounts the main checkout root, give instructions using `.worktrees/<NN>/...` as repo-root relative paths |
| Instruction breaks with double quotes | Enclose the entire instruction in double quotes. Use single quotes or Japanese quotation marks「」inside |
