# A2A code-review: making codex a reviewer on the same source (decomposed multi-agent)

Reference implementation of Stage 1 from [docs/decisions/decomposed-multiagent-a2a.md](../../docs/decisions/decomposed-multiagent-a2a.md), made ready for **actual development use**. **We wrap codex in an A2A server in another box and bind-mount the same source tree that claude is editing so codex can see it**, requesting review via A2A streaming. Codex runs in a separate microVM from claude with zero-transfer OAuth auth.

Design core:

- **Same live source**: Direct-mount claude's work tree to the codex box; codex agentic-ally reads the same files (doesn't paste code snippets in messages).
- **Streaming shows reasoning in progress**: Server relays JSONL events from `codex exec --json` (reasoning / command_execution / agent_message) with WORKING status sequentially; client receives real-time via SSE.
- **No fixed timeout**: Server uses idle timeout (hangs only if progress stops), so even multi-hour autonomous reviews wait as long as progress flows.

> This directory is the **implementation + learning reference** for codex A2A reviewer. **Daily development entry is the `/a2a-review` skill** (`.claude/skills/a2a-review/`, bundled with project); it drives the host helper `scripts/internal/a2a-review.sh` (homomorphic to dev.sh route subcommand). Don't touch `sbx/` or `.mcp.json`. Stage 2/3 (gemini/grok additions · Agent Gateway consolidation) assume this form will be **extended** ([ADR](../../docs/decisions/decomposed-multiagent-a2a.md) `### Decision (Accepted)` section).

## Structure

```
tools/a2a-review/
  codex-a2a-server/       # wrap codex --json as A2A server (runs in codex box)
    pyproject.toml        # a2a-sdk 1.1+ / starlette / uvicorn / sse-starlette
    server.py             # CodexReviewExecutor (JSONL events → WORKING relay) + Starlette
  client-demo/            # A2A client (SSE streaming receives progress + artifacts)
    pyproject.toml
    client.py
```

## Quick start — `/a2a-review` skill (daily development entry)

Inside a box, claude can invoke **`/a2a-review <target>`** to get codex's second opinion (`.claude/skills/a2a-review/`, bundled with project, just clone and use):

```text
/a2a-review tools/a2a-review/codex-a2a-server/server.py for correctness perspective
```

The skill just drives the underlying host helper `scripts/internal/a2a-review.sh ask "<instruction>"`. The reviewer pair (`cdx-<NAME>`) is **auto-provisioned and pair-serve is bg-forked when you start `bash scripts/dev.sh` / `bash scripts/dev.sh <NAME>`**, so no manual setup / separate terminal serve needed (per-pair lifecycle, decision 2026-06-27):

```bash
# on host, once only: register openai OAuth secret (ADR spike #1)
sbx secret set -g openai --oauth

# thereafter, dev.sh auto-manages pair startup/teardown
bash scripts/dev.sh            # auto-named dev box + corresponding cdx-<NAME> pair reviewer auto-start/teardown together
bash scripts/dev.sh foo        # explicit-name foo dev box + cdx-foo pair reviewer (idempotent attach-or-create)
```

The box bind-mounts the main checkout root, so stage code under `.worktrees/<NN>/` can be referenced at those paths. Running `bash scripts/dev.sh` multiple times in parallel / launching different `<NAME>`s means each pair has independent ports and doesn't interfere (per-pair lifecycle).

For manually tracing A2A server / Agent Card / JSON-RPC internals, see the next section.

## Manual execution — understanding A2A internals

### 1. Per-pair lifecycle via dev.sh (production path)

Running `bash scripts/dev.sh` (no args, auto-name) or `bash scripts/dev.sh <NAME>` (explicit name, idempotent attach-or-create) does the following in dev.sh:

1. Create `cdx-<NAME>` reviewer box with `sbx create --name cdx-<NAME> codex -t coding-agent-playbook-sbx <work-tree-absolute-path>` (direct mount)
2. Install `tools/a2a-review/codex-a2a-server/` and `tools/a2a-review/client-demo/` with `uv venv && uv pip install -e .`
3. **Bg-fork `bash scripts/internal/a2a-review.sh pair-serve <NAME>` as a child process** — pair-serve internally:
   - Runs `sbx ports cdx-<NAME> --publish 9999` to get a host port via **kernel ephemeral allocation**
   - Reads back the host port from `sbx ports cdx-<NAME>` output
   - Starts server.py in foreground with `A2A_ADVERTISE_URL=http://host.docker.internal:<host-port>`
   - Allows claude box egress with `sbx policy allow network --sandbox <NAME> "localhost:<host-port>"`
   - Writes pid / port / boxes JSON to `.claude/tmp/cdx-serve-<NAME>.lease` (statusline / check-setup reads it)
4. Start claude box `<NAME>` with `sbx run --name <NAME>` (foreground, attach to user's TTY)
5. When user exits TTY, `sbx run` returns and dev.sh's trap:
   - Kills the bg pair-serve child process (foreground server also stops)
   - Calls `bash scripts/internal/a2a-review.sh pair-teardown <NAME>` → deletes `cdx-<NAME>` box + lease

Running `bash scripts/dev.sh` multiple times in parallel (each with a different auto-name) or launching `bash scripts/dev.sh foo` and `bash scripts/dev.sh bar` means `cdx-foo` and `cdx-bar` (plus corresponding auto-name cdx pairs) each have independent ports and don't interfere (per-pair lifecycle, decision 2026-06-27).

> Direct mount is rw, but A2A server's codex is forced with `-s read-only` to **read files only** (no writes).

### 2. Internal mechanics (manual execution for debug / learning)

To manually reproduce pair-serve internals (e.g., test a2a-review.sh):

```bash
# pair-setup equivalent: create cdx-foo box + install
sbx create --name cdx-foo codex -t coding-agent-playbook-sbx /absolute/path/to/checkout
sbx exec cdx-foo sh -lc 'cd tools/a2a-review/codex-a2a-server && uv venv && uv pip install -e .'
sbx exec cdx-foo sh -lc 'cd tools/a2a-review/client-demo && uv venv && uv pip install -e .'

# pair-serve equivalent: publish + policy + server startup
sbx ports cdx-foo --publish 9999          # outputs 127.0.0.1:<ephemeral>->9999/tcp
sbx ports cdx-foo                          # check ephemeral port
sbx policy allow network --sandbox foo "localhost:<ephemeral>"
sbx exec cdx-foo sh -lc 'cd tools/a2a-review/codex-a2a-server && A2A_ADVERTISE_URL=http://host.docker.internal:<ephemeral> .venv/bin/python server.py'

# from another terminal, invoke client (from within box foo)
sbx exec foo sh -lc 'bash scripts/internal/a2a-review.sh ask "review tools/a2a-review/codex-a2a-server/server.py for correctness bugs"'

# cleanup
sbx rm -f cdx-foo
sbx policy ls   # optionally sbx policy rm <id> to clean stale policies
```

> Box image has Python 3.14 + `uv` baked in (`python3 -m venv` is unavailable due to missing ensurepip; use `uv venv`). a2a-sdk imports `sse-starlette` via `a2a.compat.v0_3`, so explicitly list it in pyproject.

The root (CWD) where codex reads review targets with relative paths defaults to **the repo root derived from server.py's location**. Override with `A2A_REVIEW_WORKDIR=<absolute-path>` only if you want another tree. When you see `Uvicorn running on http://0.0.0.0:9999`, startup is complete (listen on `0.0.0.0`; Agent Card advertise specified by `A2A_ADVERTISE_URL`).

Verified behavior: codex agentic-ally reads files multiple times (via `nl` / `rg` / `python` SDK verification), streams progress sequentially, and delivers concrete findings before `TASK_STATE_COMPLETED`.

## Key design points (per-pair lifecycle)

- **Egress allowlist is critical**: sbx boxes default-deny egress. pair-serve opens the path from claude box to reviewer with `sbx policy allow network --sandbox <NAME> "localhost:<port>"` (without this, box→box gets "Blocked by network policy" 403).
- **Allow rules persist after pair-teardown**: `sbx rm -f cdx-<NAME>` removes the box, but `sbx policy allow` rules remain (not revoked). The scope is narrow (`localhost:single-port`), but repeated dev.sh startup/stop accumulates them; periodically check with `sbx policy ls` and clean with `sbx policy rm <id>`.
- **Server held as dev.sh child foreground process**: sbx stops idle boxes, so `nohup` detach is not possible. pair-serve bg-forks as a dev.sh child, tethered to parent PID (no host daemon / launchd / systemd needed = aligns with workshop premise; explicit differentiation from the revert direction in PR #68/#70).
- **Advertise URL is box-reachable form**: Client uses Agent Card's `supportedInterfaces[].url` as POST target, so `A2A_ADVERTISE_URL=http://host.docker.internal:<port>` (default `127.0.0.1:9999` would have client hit its own box). pair-serve auto-configures this.
- **NO_PROXY bracket IPv6**: Box egress proxy config includes `[::1]` in `NO_PROXY`, causing httpx to crash with `Invalid port` (curl is fine). `client.py` removes bracket entries at startup.
- **Same source shared**: cdx-`<NAME>` reviewer box and claude `<NAME>` box **direct-mount the same host path**, so claude's edits are visible to codex. `--clone` boxes (no-arg `dev.sh`) don't mount the host checkout, so invisible to codex (= not eligible for pair reviewer; see "parallel multiple boxes" section above).
- **Port allocation is dynamic ephemeral**: No hash / registry; use `sbx ports --publish 9999` (omit hostport = kernel chooses) + read-back. Same form as `scripts/dev.sh route add`; collision probability 0%.

Fully direct **box↔box + reviewer discovery** (not even involving host publish) is Stage 3 (Agent Gateway, ADR). The above is Stage 1 cross-box form via host publish + egress policy.

## What works (production-verified)

- ✅ **Same live source reference** — direct-mount work tree to codex box; codex agentic-ally reads the same files (16 command_executions)
- ✅ **Zero-transfer auth** — proxy-inject OAuth secret; no tokens left in boxes (ADR spike #1)
- ✅ **Streaming shows reasoning progress** — JSONL events from `codex exec --json` relayed with WORKING status sequentially; client receives real-time via SSE
- ✅ **No fixed timeout** — idle timeout means wait as long as progress flows. `turn.completed` → `TASK_STATE_COMPLETED` + artifact
- ✅ **Codex functions as real reviewer** — reads same source, points out real issues

## Long-running / scale (A2A standard, handled in Stage 2/3)

[A2A streaming & async](https://a2a-protocol.org/latest/topics/streaming-and-async/) defines 3 patterns for long-running tasks, directly supported by `ClientConfig`:

- **streaming (SSE)** — this implementation. Monitor progress while holding connection (official preferred)
- **polling (`tasks/get`)** — `ClientConfig(polling=True)`. Clients that can't maintain persistent connection poll task state by ID
- **push notification (webhook)** — `ClientConfig(push_notification_config=...)`. Very long-running (minutes/hours/days)

This implementation satisfies "wait hours-long as progress flows" via streaming + idle timeout. Operations exceeding SSE connection limits (proxy timeout / disconnection) switch to polling / push notification.

## Not yet handled (Stage 2/3)

- Multiple reviewer Agent Card discovery/selection (discovery mechanism expanding via Agent Card additions for gemini/grok)
- Direct box-to-box communication (currently host relays cross-box). Consolidated at Stage 3 Agent Gateway
- Non-agent service MCP integration (ADR decision #3)
- Production-grade rate-limit / retry / cancel (cancel is currently no-op)

## Known limitations

- **Not auto-start at `sbx create` time** (ADR Stage 2 wiring scope). `scripts/internal/a2a-review.sh` starts the server at review time if not started (once per box lifetime)
- **Wrapper startup check is liveness-only** (skip startup if Agent Card responds). Updating `server.py` itself doesn't hot-reload; after update, restart the box's server (manual kill or box recreate). Review **target** code is unaffected since codex reads it live each time
- **Codex's default CWD is the repo root derived from server.py** (override with `A2A_REVIEW_WORKDIR`)
- **Codex is forced with `--skip-git-repo-check -s read-only --json`** (no write side-effects; review-only)
- **Cancel is no-op** (codex execution runs to completion. A2A executor I/F exists but this implementation covers happy path only)
- **Specifying `A2A_ADVERTISE_URL` required when invoking from host**. Linux native Docker `host.docker.internal` 502 caveat matches [../parallel-dev/box-routing/README.md](../parallel-dev/box-routing/README.md)

## References

- [docs/decisions/decomposed-multiagent-a2a.md](../../docs/decisions/decomposed-multiagent-a2a.md) (ADR defining Stage 1)
- [https://a2a-protocol.org/latest/topics/streaming-and-async/](https://a2a-protocol.org/latest/topics/streaming-and-async/) (streaming / polling / push usage)
- [https://developers.openai.com/codex/noninteractive](https://developers.openai.com/codex/noninteractive) (codex exec --json non-interactive event stream)
- [https://github.com/a2aproject/a2a-python](https://github.com/a2aproject/a2a-python) (v1.1.0, 2026-05-29)
- [https://github.com/a2aproject/a2a-samples/tree/main/samples/python/agents/helloworld](https://github.com/a2aproject/a2a-samples/tree/main/samples/python/agents/helloworld) (reference implementation)
