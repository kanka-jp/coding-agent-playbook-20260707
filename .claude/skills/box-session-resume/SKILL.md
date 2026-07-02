---
name: box-session-resume
description: "Moves a Claude Code session that ran inside an sbx (Docker Sandboxes) box so it can be resumed elsewhere — on the host or in another box — as the SAME session via `claude --resume`. Auto-locates where the session currently lives, injects the transcript into the destination's ~/.claude/projects/<encoded>/ under the original UUID name, and prints the resume command. Environment-aware: on the host it runs the resume directly; inside a box (host-only work it cannot do itself) it delegates to the host via the host-bridge by writing a request that the user grants with /box-session-resume-grant. One entry point: paste the session_id, optionally name a destination box (omit = host on the host / the current box inside a box). Companion to box-session-context (reference-only). Replaces the old box-session-handoff. A leaf-layer skill per rules/skills.md wrapping scripts/internal/box-session-resume.sh. Use when the user wants to take over / continue / hand off / resume a box session, mentions box session handoff / continue from box session / continue in another box / hand off across boxes / resume in another box / take over box work / hand off box session."
---

# box-session-resume

A skill that makes Claude Code sessions that ran inside an sbx (Docker Sandboxes) box **resumable in the same session with `claude --resume` in a different location (host or another box)**. Auto-locates where the session currently lives, injects the transcript into the destination's `~/.claude/projects/<encoded>/` under the original UUID name, and returns the resume command.

Unlike `/box-session-context` (read-only, "read and summarize and stop"), this skill **continues work**: it runs from the continuation of the session in the destination. Replaces the old `/box-session-handoff` (host-only handoff) and **covers box→host / box→another box / host→box with a single entry point**. A leaf layer ([rules/skills.md](../../../rules/skills.md)) that drives `scripts/internal/box-session-resume.sh`.

## Two execution modes (auto-branched by environment)

The actual transfer only runs on the host (it needs to reach multiple boxes on sbx). This skill **detects the startup environment** and runs directly on the host or delegates to the host if in a box (same environment dispatch as `codex-review`↔`a2a-review`, peer delegation exception in [rules/skills.md](../../../rules/skills.md)):

| Startup environment (`$SANDBOX_VM_ID`) | Mode | Behavior |
|---|---|---|
| **host** (env empty) | host-direct | Directly execute `scripts/internal/box-session-resume.sh` to inject + return resume command |
| **box** (env set) | box-delegate | Write resume request to host-bridge, user grants once with `/box-session-resume-grant` on host to execute → auto-pickup answer with Monitor |

A sibling box cannot be reached from within a box (microVM isolation · sbx unavailable), so the box delegates to the host instead of "executing itself". **The one step where a human runs `/box-session-resume-grant` on the host is the injection gate** (same asymmetric design as `/host-answer`, see limitations below).

## Why resume works (mechanism)

Dev box **bind-mounts the host repo to the same absolute path**. Therefore, the `~/.claude/projects/<encoded>/` directory names match inside the box and on the host, and if we place the transcript (`<session-uuid>.jsonl`) in the same project dir with the original UUID name, `claude --resume <id>` **restores as the same session** (true resume, not context injection).

## Host-side lookup boundary and fallback path for "not found"

As workshop material, **host-side lookup defaults to single-profile `~/.claude/projects/`** (without assuming the attendee's environment, respecting the boundary in [CLAUDE.md](../../../CLAUDE.md) `## Workshop Prerequisites`). If you manage multi-profile switching with `CLAUDE_CONFIG_DIR` (like `~/.claude-personal`), you hit the case where the session jsonl is outside the default `~/.claude` and `box-session-resume.sh` returns exit 3 (not found).

We don't embed multi-profile lookup or env hooks in the script to avoid bringing user-scope personal operation structure into the project. Instead, **when exit 3 is output, we have an agent-discipline fallback path**:

1. If the agent (claude) sees a **user-scope helper handling Claude Code session logs** (generic helper for session search/extraction) in the available-skills listing, call it to resolve the **absolute path** of the target session jsonl
2. Extract the **encoded directory name** from the resolved path (path's parent dir basename = workshop dir name like `-Users-...-coding-agent-playbook`)
3. **Manually copy to the host's default profile**:
   ```bash
   mkdir -p "$HOME/.claude/projects/<encoded>" && cp <found-path> "$HOME/.claude/projects/<encoded>/<uuid>.jsonl"
   ```
4. **Explicitly specify `source=host`** and re-run the script → now it's in the default profile so exit 0 + resume command outputs (if the jsonl after completion still exists on the box side, omitting the 3rd argument = auto-detect will judge "exists on both host and box" and return exit 4 ambiguous, so explicitly specifying `host` is necessary)

The agent runs these 4 steps on its own. In a typical attendee environment, there's no such user-scope helper so step 1 is a no-op, and it stays at exit 3 with the default (= the fallback path for personal operation doesn't impact the attendees' graceful degradation).

## Usage distinction

| Use case | Skill | Behavior |
|---|---|---|
| **Want to reference a box session** | [`/box-session-context`](../box-session-context/SKILL.md) | Read transcript, summarize overview, and **stop** |
| **Want to continue a box session** (on host / in another box) | **`/box-session-resume`** (this skill) | Inject into dest project dir → present `claude --resume` |

## Arguments

`<session_id> [<dest>] [<source>]`:

- `session_id`: UUID format or **leading 8+ hex short form**
- `dest` (optional): **If started on host, omit = host**; **if started in box, omit = that box itself** (`$SANDBOX_VM_ID`). Pass a box name for that box, pass `host` for host
- `source` (optional): Current location of transcript. If omitted, auto-detect host + running claude box. Specify only if multiple locations match

---

## Procedure A: host-direct (started on host)

1. **Check state**: Verify with `sbx ls` that the target box is running. If dest is a stopped box name, guide to start with `sbx run --name <dest>`
2. **Execute** (cwd = repo root):
   - Unix / macOS / Git Bash: `bash scripts/internal/box-session-resume.sh <session_id> [<dest>] [<source>]`
   - Windows PowerShell: `powershell -ExecutionPolicy Bypass -File scripts/internal/box-session-resume.ps1 <session_id> [<dest>] [<source>]`
3. Script auto-detects source → injects into dest's `~/.claude/projects/<encoded>/<uuid>.jsonl` → outputs resume command to stdout (exit code: 1=arg / 3=not found / 4=ambiguous / 6=sbx failure)
4. **Resume in dest**: Run the output `claude --resume <uuid>` in dest (if dest's main claude holds another session, exit it first or pick from `/resume` picker)

> The human **does not need to run this script themselves**. When you type `/box-session-resume <args>` in the host claude session, this skill (claude) runs the above script. `scripts/internal/` is the implementation; the entry point is this skill.

---

## Procedure B: box-delegate (started inside a box)

Since the box cannot perform the transfer itself, it writes a request to the host and waits (same bridge mechanism as `/host-ask`):

1. **Get own box name**: `printenv SANDBOX_VM_ID` → `<box-name>`. If empty, escalate "run from within a box" and stop
2. **Resolve dest default**: If argument `dest` is omitted, use `<box-name>` (= this box itself, "continue here") as dest. If explicit, use that value (box name / `host`)
3. **Resolve bridge dir to absolute path**: The bridge must be placed under **main checkout root** with the same absolute path bind-mounted by host and box (gitignore and host grant read expect this). If relative to cwd, worktree / subdir startup writes to `<cwd>/.claude/host-bridge` and host cannot pick it up, plus gitignore doesn't apply. Resolve from the parent of git common dir, not cwd (same root as staging root / cdx lease):
   ```bash
   BRIDGE="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/.claude/host-bridge"
   mkdir -p "$BRIDGE"
   ```
   All subsequent bridge file operations (ls / rm / Write / Monitor cat) use **this `$BRIDGE` absolute path** (the `.claude/host-bridge/` below is interpreted as `$BRIDGE/`)
4. **Calculate next seq**: `ls "$BRIDGE"/resume-req-<box-name>-[0-9][0-9][0-9].md 2>/dev/null | sort | tail -1` → If none, `001`; if exists, +1 zero-padded to 3 digits (don't use `sort -V` as it's not supported in BSD sort)
5. **Preventively delete stale ans/sentinel → Write req**:
   ```bash
   rm -f "$BRIDGE"/resume-ans-<box-name>-<seq>.md \
         "$BRIDGE"/resume-ans-<box-name>-<seq>.md.done
   ```
   Then Write `$BRIDGE/resume-req-<box-name>-<seq>.md` in the format below
6. **Start Monitor for ans wait (persistent)**: Poll the done sentinel and cat the body when detected (box-side only auto-pickup). Replace `<BRIDGE>` with the literal absolute path resolved in step 3, and **always wrap in double-quotes** (so polling doesn't break if checkout path contains spaces):
   ```text
   Monitor({
     command: "until [ -f \"<BRIDGE>/resume-ans-<box-name>-<seq>.md.done\" ]; do sleep 30; done; cat \"<BRIDGE>/resume-ans-<box-name>-<seq>.md\"",
     persistent: true,
     description: "resume ans wait for <box-name>/<seq>"
   })
   ```
   In Monitor-unavailable environments (Claude Code < 2.1.98 / Bedrock / Vertex / Foundry / DISABLE_TELEMETRY / CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC), use the same fallback as `/host-ask` step 5 (Bash `run_in_background` → manual cat)
7. **Notify user and wait**:
   ```text
   📤 Wrote resume request: <BRIDGE>/resume-req-<box-name>-<seq>.md
      Will resume session <session_id> at dest=<dest>.

   Run the following on host-side claude (this is the injection gate):
     /box-session-resume-grant <box-name>

   Auto-pickup on completion (Monitor persistent).
   ```
8. **After taking in ans**: Read the ans returned by Monitor (`resume-result` fence). If successful, guide to resume in dest:
   - If dest is **this box itself**, run `/resume` in this session and pick the target session (= box-c's claude takes over box-a's session), or `claude --resume <uuid>` in another shell in box-c
   - If dest is **another box / host**, run `claude --resume <uuid>` in that dest (command output in ans)

### resume-req file format

```markdown
# Box session resume request

- **from**: box `<box-name>`
- **seq**: `<seq>`
- **ts**: `<iso8601 UTC>`
- **session_id**: `<session_id>`
- **dest**: `<dest>`
- **source**: `auto`   (omit = auto-detect. Specify only if explicit: box name / `host`. `auto` converts to "no 3rd argument" on grant side — script treats non-empty 3rd argument as box name, so passing `auto` as-is fails)

## Intent (1 line)

<why continue at dest>

## Command run on host (executed by grant)

bash scripts/internal/box-session-resume.sh <session_id> <dest>   # source=auto has no 3rd argument
```

## Notes

- **True resume at dest=host takes over the current session**: If you only want to bring in context while preserving the current session, don't resume; use `/box-session-context` instead
- **Resume before the source box disappears**: The transcript lives in the box's filesystem and is lost if you `sbx rm`
- **Prerequisite for successful resume = source and dest share the same repo mount path**: The encoded project dir name is derived from the repo's absolute path, and this skill reuses the dir name from source in dest (it doesn't re-implement the encoding rules). This only works correctly for host + `bash scripts/dev.sh` series dev box (same absolute path bind-mount). The following cases have mismatched encoding and fail `claude --resume` even if transfer succeeds:
  - **clone box (`bash scripts/dev.sh sandbox`)**: Clone at different path (`/run/sandbox/source` etc.)
  - **Windows host**: host path is `C:\...`; box has Linux mount path
- **Reliable resume path: dev box ↔ dev box / dev box ↔ host (macOS/Linux) sharing the same mount path**

## Limitations / Caveats

- **box-delegate: monitor on box side only · user-trigger on host side** (`/box-session-resume-grant`). Same asymmetric design as `/host-ask`↔`/host-answer`: box can easily import untrusted sources and become an injection path, so human actively invokes on the host side to break the chain. However, unlike `/host-answer` which only reads host fs, grant **executes state changes (writes transcript to dest box)**, so display the request contents (session/dest/source) on grant side before executing (so humans can see abnormalities and abort)
- **Request file lifecycle**: `resume-req-*` / `resume-ans-*` / `.done` are gitignore targets but not auto-deleted. To clean up: `find .claude/host-bridge -maxdepth 1 \( -name 'resume-req-*.md' -o -name 'resume-ans-*.md' -o -name 'resume-ans-*.md.done' \) -delete`

## Troubleshooting

| Problem | Solution |
|------|------|
| `sbx: command not found` (host) | Install sbx following docs/box-ops.md |
| Running raw script in box gives `exit 5` | Using this skill auto-delegates on box side. Don't run raw script in box. On host shell, `echo $SANDBOX_VM_ID` should be empty |
| ans never arrives in box-delegate | Verify `/box-session-resume-grant <box-name>` was executed on host (host is user-trigger). Check Monitor with `TaskList`. If taking long, `TaskStop` |
| `transcript not found` (exit 3) | Typo in session_id or source box stopped. Check `sbx ls` / `ls $HOME/.claude/projects/*/` |
| `exists in multiple locations` (exit 4) | Same session exists in multiple locations (already relayed etc.). Explicitly specify `<source>` |
| `claude --resume` can't find session in dest | Verify dest shares same mount path as source (clone box / Windows see notes above) |
