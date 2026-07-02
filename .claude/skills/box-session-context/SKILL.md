---
name: box-session-context
description: "Pulls a Claude Code session transcript from inside an sbx (Docker Sandboxes) box and presents it as reference context on the host. Use when the host needs to inspect a session that ran inside a box — the typical case is HOTL monitoring where the statusLine of a box-internal session shows a session_id and the host wants to read that session's transcript. A thin wrapper over scripts/internal/box-session-context.sh (leaf-layer skill per rules/skills.md); fills the structural gap that the user-scope session-context skill only reads ~/.claude/projects/ on the host. Use when the user mentions box session, box transcript, HOTL transcript, sbx session, box session, session transcript inside box."
---

# box-session-context

Extracts the Claude Code session transcript jsonl that ran inside an sbx (Docker Sandboxes) box to the host for reference as context. This repository operates **box-primary**, where sessions inside the box do not appear in the host's `~/.claude/projects/`, and the user-scope `session-context` skill (host-only) cannot read them—filling this structural gap. The "HOTL monitoring (statusLine session id → transcript from host)" in CLAUDE.md `## Development Flow` is precisely the use case for this skill.

A thin wrapper that calls `scripts/internal/box-session-context.sh` (leaf layer, [rules/skills.md](../../../rules/skills.md)). It has no A2A logic and focuses solely on transcript extraction + presentation.

This skill is **read-only**. If you want to continue a session on the host / a different box (true resume), use [`/box-session-resume`](../box-session-resume/SKILL.md).

## Prerequisites

- **sbx is available on the host** (this skill is host-only and cannot be used from within a box. To see your own transcript from within a box, the standard `session-context` family is sufficient)
- Target box exists and is in **running** state. If stopped, start it with `sbx run --name <box>` before calling this skill (it will not auto-start)
- Target box was **started with the built-in claude agent** (`sbx run claude ...`). Transcripts from other agents like codex are out of scope

Since skill listing shows this skill to Claude inside the box as well, there is potential for confusion about box-internal invocation. However, the wrapper script fail-fast exits with exit code 5 when `$SANDBOX_VM_ID` is set (stops before proceeding to argument assembly). If claude inside the box receives exit 5, switch to the user-scope `/session-context`.

## Usage

Arguments = `<session_id> [<box_name>]` (`box_name` is optional, auto-detected if omitted).

- `session_id`: UUID format (`00000000-0000-0000-0000-000000000000`) or **leading 8+ hex short form** (`00000000` etc.). Short form is only accepted if it uniquely matches one result in the box's transcript. If multiple matches, request full UUID
- `box_name` (optional): Name from the SANDBOX column in `sbx ls` (e.g., `claude-coding-agent-playbook`). **If omitted, auto-detect: adopt the box if exactly 1 box matches `agent==claude && status==running` in `sbx ls`**. If 0 matches (no running claude box) or multiple (ambiguous in parallel execution), stop with an error asking for explicit specification (strict 1-hit requirement to avoid false positives)

### Procedure

1. **Check box state**: Verify the target box is running with `sbx ls`. If stopped, guide to start with `sbx run --name <box_name>` and stop. If there's only one box (typical for this repo), auto-detect works with omitted arguments
2. **Execute** (on host, cwd = repo root):
   - Unix / macOS / Git Bash: `bash scripts/internal/box-session-context.sh <session_id> [<box_name>]`
   - Windows PowerShell: `powershell -ExecutionPolicy Bypass -File scripts/internal/box-session-context.ps1 <session_id> [<box_name>]`
3. Script internal processing:
   - Search for transcript path: `sbx exec <box_name> ls /home/agent/.claude/projects/*/<session_id>*.jsonl`
   - 0 matches: exit 3 (guide: check session list with `sbx exec <box> ls /home/agent/.claude/projects/`)
   - Multiple matches (short form hits multiple): exit 4 (request full UUID)
   - 1 match: copy to host with `sbx cp <box_name>:<path> .claude/tmp/box-session-<short>.jsonl`
   - Output host save path as one line to stdout
4. Claude reads the output path with the **Read** tool (use `offset` / `limit` for large files), JSON parse each jsonl line, and extract + summarize:
   - Session start / end time (from line's `timestamp`)
   - Key user message / assistant message exchanges
   - Tool calls (which tools were called how many times)
   - Final state (last assistant message)

### Present results

Return a session overview (start time / summary of key exchanges / final assistant message) to the user. Since raw transcript is verbose, present in summary format unless the user says "I want to see all of it".

## Notes

- Transcripts are **stored in the box's filesystem (`/home/agent/.claude/projects/`)**. They are lost if the box is deleted with `sbx rm`. If you want to keep transcripts long-term, copy them to the host with this skill
- The copy destination (`.claude/tmp/box-session-<short>.jsonl`) is outside git management (`.claude/tmp/` is expected in `.gitignore` as a temporary directory), so you can reference it with `Read` even after switching sessions

## Troubleshooting

| Problem | Solution |
|------|------|
| `sbx: command not found` | Install Docker Sandboxes (sbx) on the host following docs/box-ops.md |
| `box <box_name> not found` | Verify the correct box name with `sbx ls` |
| `box <box_name> is not running` | Start with `sbx run --name <box_name>` and retry |
| `no running claude box found` (auto-detect failed) | No running claude agent box. Start with `sbx run claude ... .` or explicitly specify `<box_name>` |
| `multiple running claude boxes (...). Specify <box_name> explicitly` (auto-detect failed) | Multiple boxes running in parallel. Check with `sbx ls` and explicitly specify `<box_name>` |
| `transcript not found for session_id` | Check session list with `sbx exec <box> ls /home/agent/.claude/projects/`. Possible typo or different box |
| `multiple transcripts match short session_id` | 8-hex short form matched multiple. Pass full UUID or verify the exact session_id with `sbx exec <box> ls /home/agent/.claude/projects/*/` |
| jsonl after copy is too large to read with Read | Use Read's `offset` / `limit` to see the beginning/end, or stick to the summary in step 4 |
