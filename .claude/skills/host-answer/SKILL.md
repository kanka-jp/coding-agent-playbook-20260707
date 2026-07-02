---
name: host-answer
description: "On the host side, read the latest ask file from `.claude/host-bridge/ask-<box-name>-<topic>-<seq>.md` written by a box-internal `/host-ask`, investigate the requested host-side facts (other compose projects, host port occupiers, host fs outside the box mount, host-local services), write a paste-ready answer to `.claude/host-bridge/ans-<box-name>-<topic>-<seq>.md`, then touch a done sentinel `ans-<box-name>-<topic>-<seq>.md.done` so the box-side `/host-ask` auto-pickup polling can detect completion race-free (sentinel is created after the ans body write completes, guaranteeing the body is fully flushed when the sentinel appears). Counterpart of `/host-ask` (box-from-host bridge). Use when the user says a box session has written an ask and needs host investigation."
---

# host-answer

Skill that reads on host the inquiry that `/host-ask` inside box wrote to `.claude/host-bridge/ask-<box-name>-<topic>-<seq>.md`, investigates on host side, and Writes a paste-ready answer to `.claude/host-bridge/ans-<box-name>-<topic>-<seq>.md`.

Counterpart to `/host-ask` (box-from-host bridge). Host claude investigates host-side facts not visible inside box (compose of other projects / existing containers / port occupiers / host fs outside mount / host-local services) and returns them to box via proxy.

## Prerequisites

- **Run on host side** (pointless in box)
- Launch from repo root (or cwd where `.claude/host-bridge/` is visible)
- Corresponding box session running on same repo, has already written ask file via `/host-ask`

## Usage

Arguments = `<box-name> [<topic>]`

- `<box-name>`: equals box's `$SANDBOX_VM_ID` env (example: `coding-agent-playbook-4632ea`). Matches ask file name (`ask-<box-name>-<topic>-<seq>.md`). Also visible as `[<box-name>]` in statusLine
- `<topic>` (optional): target topic slug. If omitted, adopt the ask among `ls -t .claude/host-bridge/ask-<box-name>-*.md` that has **no done sentinel (`.md.done`)** and **latest mtime** (= most recent unanswered ask from box). Judgment based on sentinel presence, not ans body presence (body-only generated without sentinel = previous `/host-answer` launch partially failed after body Write without touching sentinel; this also needs reprocessing as unanswered)

## Procedure

1. **Identify target ask**:
   - When topic specified: `ls .claude/host-bridge/ask-<box-name>-<topic>-[0-9][0-9][0-9].md 2>/dev/null | sort | tail -1` to adopt latest seq for same topic (anchored character class `[0-9][0-9][0-9]` avoids topic prefix collision trap where `port` glob hits `port-80`. `<seq>` zero-padded 3 digits so plain `sort` lexicographic order matches numeric order. GNU extension `sort -V` unsupported on macOS/BSD sort = cross-platform violation, so don't use).
   - When topic omitted: Sort `ls -t .claude/host-bridge/ask-<box-name>-*.md 2>/dev/null` by mtime descending, adopt latest lacking corresponding **done sentinel** (`ans-<box-name>-<topic>-<seq>.md.done`) (judge by sentinel presence, not body. Body-only state from previous incomplete finish = unresolved, reprocess). If all complete (sentinel present), tell user "no unresolved asks" and exit
   - If 0 hits (wrong box-name etc), escalate to user and stop

2. **Read ask**: Read target ask file and extract:
   - `## Needed fact` — question to answer on host
   - `## Known` — facts already confirmed box-side (don't duplicate investigation on host)
   - `## Hypotheses` — candidates host should verify
   - `## Done when` — answer completion condition

3. **Host-side investigation**: Use normal host Bash / Read. Common techniques:
   - `docker ps --format '...'` / `docker network ls` / `docker network inspect <name>` / `docker volume inspect <name>` — other projects' container / network / volume state
   - `docker inspect <container> --format '{{json .Config.Cmd}}'` / same `.Mounts` — existing container config
   - `lsof -nP -iTCP:<port> -sTCP:LISTEN` — process occupying host port (use lsof's `-iTCP:<port>` for anchored match. Form `lsof -nP -iTCP -sTCP:LISTEN | grep ':<port>'` has unanchored grep pitfall where `:80` search hits `:8080`, so don't use)
   - `ls -la <path>` / `cat <path>` / `head <path>` — host fs outside mount
   - `curl -sS http://localhost:<port>/...` — reach host-local service
   - If needed, read other projects' compose files (read-only, no writes)

   **No writes**: This skill is read-only investigation only. Don't cause side effects like starting/stopping other projects' containers, editing volumes, changing config (don't modify host environment independent of box session intent). OK to write "change suggestion" as judgment material in ans, but execution is user judgment.

4. **Ensure bridge dir → delete old sentinel → write ans body → touch done sentinel (this order is race-free contract)**: Run `mkdir -p .claude/host-bridge` (needed when skill runs solo on host, idempotent no side effects). Next, for rewriting same ans (reprocessing previous incomplete ask / same seq overwrite), **delete target sentinel first** before writing body, then touch sentinel after write completes. Wrong order re-introduces race window (see below):

   ```bash
   # (a) Delete old sentinel (prevent polling seeing old sentinel during body Write and cat-ing early)
   rm -f .claude/host-bridge/ans-<box-name>-<topic>-<seq>.md.done
   ```

   Next write `.claude/host-bridge/ans-<box-name>-<topic>-<seq>.md` in format below (`<seq>` matches target ask = 1 ask → 1 ans).

   ```bash
   # (b) After body Write completes, touch done sentinel (box-side polling awaits sentinel)
   touch .claude/host-bridge/ans-<box-name>-<topic>-<seq>.md.done
   ```

   **(a) → body Write → (b) order is mandatory**: Write tool may non-atomically write large files (truncate + sequential), box polling `[ -f ans...md ]` directly seeing body risks cat-ing half-written state. Sentinel is **serialization created after ans body Write completes in separate step**, guaranteeing sentinel appearance = body complete (race-free). Reversing order (touch sentinel first / leave old sentinel while writing body) causes polling to **cat old body or half-written new body** early. Fresh ask (no sentinel initially) has (a)'s `rm -f` as no-op (`-f` doesn't error) so idempotent.

5. **Escalate**: Tell user below and stop autonomous execution:
   ```text
   📥 Written host info reply: .claude/host-bridge/ans-<box-name>-<topic>-<seq>.md
      (done sentinel: ans-<box-name>-<topic>-<seq>.md.done)

   Box side (auto-pickup-capable /host-ask) detects sentinel via background polling and auto-ingests (no manual cat needed).
   For box using old /host-answer, manually run:
     cat .claude/host-bridge/ans-<box-name>-<topic>-<seq>.md
   ```

## Answer File Format

````markdown
# Host info reply

- **to**: box `<box-name>`
- **topic**: `<topic>`
- **seq**: `<seq>`
- **ts**: `<iso8601 UTC>`

```host-ctx
<paste-ready block box cat's directly into context>
<facts as bullet points; separate speculation from facts (fact-vs-speculation norm)>
<if needed, include "recommended judgment axes", "obstacles if piggybacking" etc as material>
```

## Notes (optional, host-side commentary)

- <host-side notes not needing box ingestion>
- <investigation limits, unconfirmed items>
````

`host-ctx` fence allows box-side machine extraction via `awk '/^```host-ctx/,/^```$/'` etc (maintain stable format as sentinel).

## Handling Parallel Asks

When 1 box session runs multiple topics simultaneously, host side also returns ans independently per topic (`/host-answer <box-name> <topic>` per topic). Auto-detect without topic uses "latest mtime among unanswered asks," so when multiple unanswered exist, safer to explicitly call topic by topic starting from oldest.

## Limitations / Caveats

- **Read-only only**: Don't write to host environment (start containers, edit volumes, compose up etc). This skill's responsibility ends at providing judgment material; execution is user judgment.
- **Secret / credentials**: Don't paste host credentials / API keys / personal info in ans file (plaintext shared host ↔ box; not persisted by gitignore but in box context). If `docker inspect` output contains env, redact before writing to ans.
- **Fact vs speculation**: ans's `host-ctx` block centers on facts; separate speculation explicitly ([rules/skills.md](../../../rules/skills.md) leaf skill norm + general fact-vs-speculation norm).
- **Lifecycle**: ans file is `.gitignore`'d but **not auto-deleted**. Kept for debug value; if annoying, manually `rm`.
- **Cross-box**: Host-side claude session independent of box-side box-name. Skill takes `<box-name>` as argument, so can sequentially handle multiple boxes (parallel dev etc).

## Troubleshooting

| Issue | Resolution |
|------|------|
| `.claude/host-bridge/` empty / target ask file missing | Verify box-side ran `/host-ask`. Confirm actual files via `ls .claude/host-bridge/` |
| 0 hits with `<box-name>` specified | Compare with box statusLine `[<box-name>]`. May be typo / different box (verify active box names via `sbx ls`) |
| Multiple topics unanswered in parallel | Handle 1 by 1 with explicit topic. Auto-detect uses latest mtime so ambiguous |
| Host investigation needs side effects (start container etc) | Don't execute in this skill. Write in ans "suggested for user: run `docker compose -f <file> up -d <svc>`" and defer to user judgment |
| Box-side follow-up ask in same topic (seq increased) | Re-read new seq ask and write new seq ans (can leave old ans or write new, box side cat's latest seq) |
