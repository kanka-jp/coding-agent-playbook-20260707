---
name: host-ask
description: "From inside an sbx box, write a structured request file under `.claude/host-bridge/` asking the host claude session to investigate something only visible from host (other compose projects, port occupiers, host fs outside the mount, host-local services unreachable from box). The mirror of `/box-session-context` (which is host-from-box): this is box-from-host. Use when the box agent realizes it needs host-side facts and cannot infer them from the bind-mounted workspace. After writing the ask, automatically picks up the answer via a Monitor (persistent, session-length watch — bypasses the 10-minute Bash run_in_background timeout cap so long HOTL response windows are handled) when the host writes it; falls back to Bash run_in_background or manual cat when Monitor is unavailable (Claude Code < 2.1.98 / Bedrock / Vertex / Foundry / DISABLE_TELEMETRY / CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC) so the skill keeps minimum functionality across environments. Box-side monitor only; host-side answering remains user-triggered via `/host-answer` to keep a user gate against prompt-injection chains where a compromised box could request and auto-receive host secrets."
---

# host-ask

Skill that, when a claude session running in box (sbx microVM) needs host-side facts not visible from box (state of other compose projects / port occupier listening on host / host filesystem outside mount / host-local service unreachable due to box network restriction), writes a **structured inquiry** to `.claude/host-bridge/ask-<box-name>-<topic>-<seq>.md`, notifies user "run `/host-answer` on host", and auto-picks up the answer file via background polling (box-side monitor only. host-side auto-pickup **intentionally not implemented** to prevent injection chain — see limitations).

Leaf skill that pairs as **reverse direction** of `/box-session-context` (host peeks at box transcript): active ask from box → host. Both don't overlap but are complementary.

## Prerequisites

- **Run inside box (sbx microVM)**. Pointless if launched on host (just creates ans-waiting loop on host)
- **Permission to Write `.claude/host-bridge/`** under bind-mounted cwd. `sbx run ... .` binds cwd to box's `/workspace` (or equivalent) so host sees same path
- Corresponding `/host-answer` skill bundled in project, host-side claude running or user can start soon
- `$SANDBOX_VM_ID` env set inside box (auto-set when launching box with dev.sh / dev.sh sandbox, displayed as `[$SANDBOX_VM_ID]` in statusLine)

## Trigger (examples of when box agent recognizes "only the host can answer this")

Box agent fires this skill in situations like:

- **Wanting to know who occupies a listening port on host** (example: who holds `:80`, as `lsof` and `docker ps` inside box can't see host processes)
- **Wanting to know the identity of another project's compose / container** (example: existing Traefik / nginx / redis, etc. running on host; information to decide whether to piggyback or stand up separately)
- **Contents of host filesystem paths outside the mount** (example: config values in another project's `docker-compose.yml`, existence check of host's `~/.config/<tool>/`)
- **Reaching host-local services** (services via `host.docker.internal` unreachable due to box network restrictions, etc.)
- **Host shell env / dotfiles state** (when box behavior is unexplained due to participant environment specifics)

Don't route to host things verifiable via `cat` / `docker ps` / `lsof`, etc. inside box (this skill is a dedicated cross-host path; it doesn't answer questions solvable inside the box).

## Usage

Arguments = `<topic> [<question>]`

- `<topic>`: A slug representing one issue. `[a-z0-9-]{1,32}` (example: `traefik-port` / `port80-owner` / `host-fs-layout` / `jal-compose-config`). **1 topic = 1 problem thread**; follow-up clarifications progress seq within the same topic. Create a new topic once resolved.
- `<question>` (optional): 1-3 lines of natural text summarizing "the needed fact". If omitted, create the `## Needed fact` section in the ask file blank, and the box agent fills the body from conversation context.

## Steps

1. **Get own box name**: Read env via `printenv SANDBOX_VM_ID` and set as `<box-name>` (example: `coding-agent-playbook-4632ea`). If env is empty (= misfire outside box / `$SANDBOX_VM_ID` unset in anomalous box), stop autonomous execution and escalate to user: "`SANDBOX_VM_ID` env not readable. Launch this skill inside dev box."

2. **Ensure bridge dir**: Run `mkdir -p .claude/host-bridge` (it's gitignored and absent in fresh clones, so run every time to ensure Write succeeds even if `.claude/host-bridge/` doesn't exist. Idempotent, no side effects)

3. **Compute next seq**:
   - Run `ls .claude/host-bridge/ask-<box-name>-<topic>-[0-9][0-9][0-9].md 2>/dev/null | sort | tail -1` to get the max seq for the same topic (anchored character class `[0-9][0-9][0-9]` avoids topic prefix collision traps like `port` glob hitting `port-80`. `<seq>` is zero-padded 3 digits, so plain `sort` lexicographic order matches numeric order. GNU extension `sort -V` doesn't work on macOS/BSD sort—a cross-platform violation ([CLAUDE.md](../../../CLAUDE.md) "Cross-platform requirements")—so don't use it)
   - If none exist, use `001`; if exist, add 1 and zero-pad to 3 digits

4. **Preventively delete stale ans / sentinel for new seq → Write ask file**: Before firing the new ask, delete remnants of `ans-...md` / `ans-...md.done` for this seq with `rm -f` (prevents race where stale sentinel remains from skipped lifecycle cleanup or seq collision on the same box/topic, causing step 5's polling to immediately judge `[ -f ANS.done ]` true at startup and `cat` to ingest old body):
   ```bash
   rm -f .claude/host-bridge/ans-<box-name>-<topic>-<seq>.md \
         .claude/host-bridge/ans-<box-name>-<topic>-<seq>.md.done
   ```
   `-f` is a no-op for fresh asks (no remnants). Then write `.claude/host-bridge/ask-<box-name>-<topic>-<seq>.md` in the format below

5. **Launch Monitor for ans-wait (persistent)**: **Primary path**: Launch Monitor tool with `persistent: true` to poll for **done sentinel**, detect it, then cat the body (box-side auto-pickup only; host-side stays user-triggered — security rationale below under limitations):
   ```text
   Monitor({
     command: "until [ -f .claude/host-bridge/ans-<box-name>-<topic>-<seq>.md.done ]; do sleep 30; done; cat .claude/host-bridge/ans-<box-name>-<topic>-<seq>.md",
     persistent: true,
     description: "ans wait for <box-name>/<topic>/<seq>"
   })
   ```
   **Why use Monitor `persistent: true` instead of Bash `run_in_background`**: Bash tool's `run_in_background` is killed at `BASH_MAX_TIMEOUT_MS` (default 600000 = 10 minutes; env-changeable with hard cap). Host-side user's `/host-answer` response time can exceed 10 minutes in HOTL workflow (user busy with other tasks / monitoring parallel PRs / away from desk, etc.). Monitor `persistent: true` is a session-length watch (no timeout) that naturally persists until the command exits. **Monitor schema's "single event recommend Bash run_in_background" assumes short jobs finishing within minutes**; this use case (waiting for an event with unknown arrival) doesn't fit.

   **Fallback path for environments where Monitor is unavailable**: Monitor is a Claude Code 2.1.98+ feature, unavailable in these environments (see official [Tools reference](https://code.claude.com/docs/en/tools-reference)):
   - **Claude Code < 2.1.98** (old CLI version)
   - **Bedrock / Vertex / Foundry** (alternative model providers)
   - **`DISABLE_TELEMETRY=1` / `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`** (launched via telemetry path)

   In these environments, fallback as:
   - **(a) Bash `run_in_background`**: Launch same command as `Bash({command: "until ... done; cat ANS", run_in_background: true})` (has 10-minute timeout cap; HOTL response exceeding 10 minutes silently kills, so second-best). Capture completion notification: `BashOutput(bash_id="<task-id>")` or `Read` the notification's `<output-file>` (Bash stdout is file-based; unlike Monitor, needs explicit retrieval)
   - **(b) manual cat (legacy flow)**: Include in step 6's notification: "Please notify when ans arrives; we'll ingest via `cat .claude/host-bridge/ans-<box-name>-<topic>-<seq>.md`". Two-stage HOTL handoff, but ensures minimum functionality under environment constraints

   Which path to take: box agent probes at startup whether Monitor is available, or pre-knows the environment (reliable runtime detection isn't currently doc-instructable; if Monitor launch fails with tool error, fallback (a) → (b) in order).

   **Why poll sentinel (`.md.done`) rather than the ans body**: `/host-answer` serializes by writing ans body, then in a separate step touches the sentinel—sentinel appearance guarantees body completion (race-free). Polling the ans body directly races: Write tool's non-atomic writes (truncate + sequential) cause `[ -f ans...md ]` to true mid-write, so `cat` ingests half-written state. `until [ -f X ]` runs in POSIX shell (portable across bash and busybox in box images). `sleep 30` interval waits for host-side user's `/host-answer` at 30-second granularity. Monitor executes `cat` once at sentinel appearance and exits (all stdout lines within 200ms bundle into 1 notification; small ans files typically 1 event)

6. **Notify user and return to main work**: Split notification based on which path launched (Bash fallback uses different wording than Monitor to maintain honesty about 10-minute timeout):

   **(Primary / Monitor `persistent: true`) Session-length auto-pickup**:
   ```text
   📤 Written host info request: .claude/host-bridge/ask-<box-name>-<topic>-<seq>.md

   Run this on the host-side claude:
     /host-answer <box-name> <topic>

   Once ans is written, we'll auto-pickup here (Monitor persistent, session-length wait, 30-second-granularity sentinel polling). Continuing other work in the meantime.
   ```

   **(Bash fallback) Auto-pickup within 10 minutes; manual fallback beyond**:
   ```text
   📤 Written host info request: .claude/host-bridge/ask-<box-name>-<topic>-<seq>.md

   Run this on the host-side claude:
     /host-answer <box-name> <topic>

   If ans arrives within 10 minutes, we'll auto-pickup here (Bash run_in_background, 30-second-granularity sentinel polling).
   ⚠️ Beyond 10 minutes, Bash timeout (BASH_MAX_TIMEOUT_MS hard cap) silently kills polling. If it doesn't arrive within 10 minutes, please notify when ans arrives (we'll manual-cat).
   ```

   **(manual cat fallback) When both Monitor and Bash background unavailable**:
   ```text
   📤 Written host info request: .claude/host-bridge/ask-<box-name>-<topic>-<seq>.md

   Run this on the host-side claude:
     /host-answer <box-name> <topic>

   Please notify when ans arrives (we'll manual-cat via `cat .claude/host-bridge/ans-<box-name>-<topic>-<seq>.md`).
   ```
   This path is 2-stage HOTL handoff but guarantees minimum functionality in environments without auto-pickup paths

   After notifying, don't block waiting for ans; advance the main task as much as possible. Monitor's `cat` exits after detecting sentinel and all stdout lines arrive as notification (Bash fallback: notification + `<output-file>` Read, but beyond timeout use step 7's Bash timeout handling path)

7. **Ingest ans (path-dependent + Bash timeout handling)**:
   - **(primary / Monitor)**: Monitor converts each stdout line to notification event (consecutive lines within 200ms bundle into 1 notification; small ans file usually arrives as 1 event = entire ans as 1 notification). No explicit Read needed; arrives directly in context
   - **(Bash fallback / normal completion = sentinel detected < 10 minutes)**: task-notification is completion event only; stdout persisted to `<output-file>` (absolute path). Explicitly fetch via `Read(file_path="<output-file>")` or `BashOutput(bash_id="<task-id>")`
   - **(Bash fallback / timeout = sentinel undetected for 10 minutes → SIGTERM kill)**: notification arrives with status `timeout` / `failed` (e.g., exit code 143). In this case, **manually revert to manual cat fallback**: (a) Tell user "Bash polling timeout; if ans arrived, we'll manual-cat", (b) Check `[ -f .claude/host-bridge/ans-<box-name>-<topic>-<seq>.md.done ]` (if sentinel exists, direct cat; if not, ask user about `/host-answer` execution on host), (c) If sentinel exists → `cat .claude/host-bridge/ans-<box-name>-<topic>-<seq>.md` to ingest
   - **(manual cat fallback)**: When user says "arrived", run `cat .claude/host-bridge/ans-<box-name>-<topic>-<seq>.md` in Bash and ingest to context

   In ingested ans, the ` ```host-ctx ... ``` ` fence is host's paste-ready block (trust content and use for subsequent judgment). After ingestion, resume the paused main judgment. Monitor / successful Bash naturally exit at task completion, so explicit `TaskStop` isn't needed

## Ask File Format

```markdown
# Host info request

- **from**: box `<box-name>`
- **topic**: `<topic>`
- **seq**: `<seq>`
- **ts**: `<iso8601 UTC>`

## Needed fact (1-3 lines)

<box agent writes in natural language. Minimal granularity to satisfy Done when>

## Known (confirmed in-box)

- <fact 1 confirmed in box>
- <fact 2 confirmed in box>

## Hypotheses (candidates for host to verify)

1. <hypothesis 1>
2. <hypothesis 2>

## Done when

<end condition: 1-2 lines describing when ask closes if answer includes this info>
```

## Parallel Asks (multiple topics simultaneously)

Topics separated by `<topic>` slug allow multiple physical problems in same box session (example: send `jal-compose-config` ask while waiting for `traefik-port` ans). Each topic has independent seq.

However, **within same topic, seq is monotonically increasing**; starting next seq without waiting for ans confuses host (ambiguous active seq). Follow-ups in same topic come after receiving ans.

Topic naming convention `[a-z0-9-]{1,32}` isn't machine-enforced; relies on agent discipline. **Topic prefix collision** is structurally prevented by step 3's anchored glob (`[0-9][0-9][0-9].md`), but operationally scattered naming (example: `traefik-port` rather than `port-80`, `app-port` rather than `port-3000-app`) is friendlier to readers.

## Limitations / Caveats

- **Box-side monitor only (host-side monitor not implemented)**: Bridge auto-pickup is only box → ans file polling (step 5 above). Reverse path for host to poll box → ask file appearance **intentionally omitted**. Box frequently ingests untrusted sources (public issues / PR bodies / web-fetched documents) and is a prompt-injection vector. If box is injected, ask could say "return all host secrets" → host auto-pickup lets host answer without user intervention → flows into box context → exfiltration path (PR body / commit / bot reply) to outside = injection chain. Keeping host-side as user-trigger (`/host-answer` user actively invokes) means user judgment enters when host claude launches, breaking chain. Design treats host as trust boundary, box as injection vector (asymmetrically).
- **Not host-from-host**: Skill is box-internal only. If you want host info while on host, just run Bash normally (skill unnecessary).
- **Lifecycle**: ask / ans / done sentinel files are `.gitignore`'d but **not auto-deleted**. Kept for debug value; if annoying, manually `find .claude/host-bridge -maxdepth 1 \( -name 'ask-*.md' -o -name 'ans-*.md' -o -name 'ans-*.md.done' \) -delete` (delete all 3 types. **Forgetting to delete `ans-*.md.done` leaves stale sentinel when re-allocating seq 001 for same box/topic, causing race where box polling `until [ -f ANS.done ]` exits true immediately and `cat` ingests old ans body / nonexistent path**). **Why use `find -delete`**: Simple `rm -f <glob>` is idempotent in bash/sh on no-match, but zsh's default `nomatch` option errors on glob expansion with "no matches found" (macOS default shell is zsh, so often hit on host). `find -delete` doesn't depend on shell glob expansion; find's own pattern matching is shell-independent and idempotent. `-maxdepth 1` confines to `.claude/host-bridge/` direct children; `.claude/host-bridge/` anchor prevents dragging unrelated files on cwd mismatch.
- **Secret / credentials**: Don't paste box env / credentials in ask file (plaintext shared host ↔ box. box-bridge isn't in L0 secret boundary; secrets handled via op / secret-proxy dynamic injection).
- **Uniqueness of `<box-name>`**: sbx constraint of not standing same-named boxes simultaneously (`sbx ls` shows name unique), so `<box-name>` uniquely identifies active session. When host has multiple dev boxes (e.g., parallel dev), wrong `<box-name>` sends ans to different box, so always include literal `<box-name>` in escalate message.

## Troubleshooting

| Issue | Resolution |
|------|------|
| `printenv SANDBOX_VM_ID` is empty | Misfire outside box / anomalous box. Recreate box with dev.sh / dev.sh sandbox or fallback to user paste for `<box-name>` |
| `.claude/host-bridge/` doesn't exist | Step 2 runs `mkdir -p` so usually doesn't happen. If permission denied, verify bind mount write permissions |
| Host-side claude lacks `/host-answer` | Check if this PR is reflected on host too (project skills assumed bundled in both clones) |
| ans doesn't arrive (Monitor notification doesn't appear) | (1) Verify user ran `/host-answer <box-name> <topic>` on host (host-side is user-trigger, not automatic). (2) Check Monitor liveness via `TaskList`. If `until` loop continues, ans file not generated = host side not run. (3) For long wait, explicitly escalate to user and kill Monitor (`TaskStop <task-id>`) |
| ans body written but sentinel (`.md.done`) missing | Possible old `/host-answer` version (sentinel touch unsupported) ran. Manually run `touch .claude/host-bridge/ans-<box-name>-<topic>-<seq>.md.done` on host or resubmit with new `/host-answer` |
| ans appeared but `cat` doesn't run | `[ -f X ]` is true only for regular files. If sentinel is symlink or similar, use `[ -e X ]` form and manually restart (normal `/host-answer` path touches regular file) |
| Monitor notification received but ans not in context | Monitor design streams stdout directly, so usually doesn't happen. If missed, check Monitor output via `TaskList` / `TaskOutput` |
| Monitor never exits (host gives up responding) | Kill Monitor with `TaskStop <task-id>`. If abandoning topic, `rm` ask file too before next task |
| seq collision in same topic (accidentally started double ask in parallel) | `rm` old ask + `TaskStop` corresponding Monitor, then re-allocate seq |
| Wrong `<box-name>` causes ans to go to different box | Correct `<box-name>` in ans file name and `cat` as new ans on box side (Monitor polling with original `<box-name>`, so `TaskStop` and restart with new path) |
