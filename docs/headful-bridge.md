# headful CDP bridge (operate host's visible Chrome from box)

Opt-in bridge for claude inside box (chrome-devtools MCP) to operate **host's visible Chrome** via CDP. Use when keeping session in box but wanting agent to drive an independent visible browser.

Normally, box sessions run chrome-devtools MCP on **box's headless Chromium** (controlled by `CDP_HEADLESS` in `.mcp.json`). This bridge bridges separately to **host's headful Chrome**.

## When to use / not use

- **Use**: "Want agent to drive visible browser on host screen" / "Want to HOTL while watching browser"
- **Don't use**: Screenshots/DOM-only work use **box headless (default)** fine. Bridge increases attack surface, use only when needed.

## ⚠️ Security (must read)

CDP gives **full browser control**: arbitrary navigate / DOM read / **arbitrary JS execution** / **cookie/localStorage/login session read** / download.

> **Biggest risk**: Connecting to real Chrome profile, box (microVM-isolated) agent can **effectively hijack logged-in sessions** on Gmail/GitHub/AWS etc. Breaks box-primary isolation premise.

This bridge prevents it by design:

| Measure | Details |
|---------|---------|
| **Disposable profile (default)** | Host creates throwaway `--user-data-dir` separate from real profile per `up`, deletes on `down`. Rejects specs pointing to known real profile roots (Chrome/Beta/Canary/Chromium/Edge/Brave, resolves symlinks). Safety net only—can't cover all—so **if `CDP_PROFILE_DIR` explicit, user responsible not to pass real profile** (explicit dir not auto-deleted). Throwaway has no creds, but **not "equivalent" to box headless** (see warning below) |
| **Port preflight** | On `up`, **stops if `localhost:<port>` already speaks CDP**. Prevents exposing non-throwaway existing browser if another process (maybe real Chrome) occupies port when policy allows |
| **Loopback only** | Host Chrome on `127.0.0.1`, box relay also binds `127.0.0.1`. No LAN exposure |
| **Box scope (optional)** | Set `CDP_BOX=<box-name>` to constrain egress `--sandbox` to that box only. Unset: all boxes on host can relay, so specify when running multiple boxes |
| **Tight policy allow** | Only `localhost:<port>` permitted (not `**`) |
| **Opt-in / ephemeral** | Default off. On `up` launch, on `down` stop Chrome + relay + **delete egress rule** |
| **Don't dirty committed config** | Don't modify `.mcp.json`. MCP connection via `claude mcp add-json` (local scope) opt-in |

> **⚠️ Not "equivalent risk" to box headless**: Even throwaway profile, CDP operates **real browser running on host**. Agent can navigate to `http://localhost:<host-service>` or `file://...`, read rendering via CDP. This **bypasses box egress policy (only gates CONNECT tunnels)** to reach host local admin services / dev servers / local files. Box's headless Chromium is microVM-isolated so this path doesn't exist. In environments with sensitive local services on host, `up` only when needed, `down` immediately after use.

**Operations rule**: Bridge's Chrome is "agent's browser"—**don't log real accounts**. Always `down` when done.

## Architecture (why relay is needed)

In this sbx environment, box→host direct link-local (`169.254.1.1` / `fe80::1`) stops at gateway appliance and **doesn't reach host services**. Box→host **via sbx proxy (`gateway.docker.internal:3128`) is the only valid path**, gated by `sbx policy allow`.

Puppeteer (the chrome-devtools-mcp internals) doesn't auto-use `HTTP_PROXY`. So **place socat relay inside box**; puppeteer connects to box localhost (NO_PROXY → direct), socat tunnels via proxy's **HTTP CONNECT** to host Chrome:

```text
[box] chrome-devtools-mcp --browser-url http://localhost:9333
        |  (NO_PROXY: box localhost direct)
        v
[box] socat TCP-LISTEN:9333 -> PROXY(CONNECT) gateway.docker.internal:3128
        |  (sbx policy allow network localhost:9222)
        v
[host] Chrome --remote-debugging-port=9222  (disposable profile / loopback / visible)
```

Verified in practice: HTTP (`/json/*`), WebSocket upgrade, and CDP commands all transit this path. Chrome reflects Host header in `webSocketDebuggerUrl`, so hitting `localhost:<relay>` self-aligns; no Host rewriting or IP literal tricks needed.

## Procedure (recommended: one-liner on host)

Passing `--box <box-name>` makes host `up` perform **auto-select port → launch disposable Chrome → permit egress → launch box relay via `sbx exec` → register MCP** in one command.

```bash
# host side (confirm box name via box's `echo $SANDBOX_VM_ID`)
bash scripts/cdp-bridge.sh up --box <box-name>
# Windows: pwsh scripts/cdp-bridge.ps1 up -Box <box-name>
```

- **Auto-select port**: Without `--port` specified, auto-finds empty port even if default 9222 is taken (doesn't touch occupied ports = safety preserves no real profile exposure). Fix with `--port 9223` if desired.
- **Auto-launch box relay**: `sbx exec <box> bash scripts/cdp-bridge.sh up ...` starts box relay. Suppress with `--no-connect` and revert to manual operation.

### Agent-side connection (critical prerequisite)

MCP server **loads only at Claude Code session startup** ([no hot-reload](https://github.com/anthropics/claude-code/issues/46426)). Thus:

- **Existing box session** (claude already running): MCP unchanged. Directly hit relay for operations (`http://localhost:<relay>` CDP HTTP/WS. Example: `curl -X PUT "http://localhost:9333/json/new?<url>"` to navigate).
- **Next box session launch**: `up --box` registers `chrome-devtools-host` MCP available from start (coexists with box headless's `chrome-devtools`).

### Manual (without `--box` / fine-grained control)

```bash
# 1) host: launch Chrome + permit egress (don't start box relay)
bash scripts/cdp-bridge.sh up --no-connect --port 9223
# 2) box: launch relay (pass port host selected)
bash scripts/cdp-bridge.sh up --port 9223
# 3) (for new session) register MCP
claude mcp add-json chrome-devtools-host \
  '{"command":"npx","args":["chrome-devtools-mcp@latest","--browser-url","http://localhost:9333"]}'
```

### Cleanup (mandatory)

```bash
# host: stop Chrome + remove egress rule + delete disposable profile (+ if --box/scope, also stop box relay)
bash scripts/cdp-bridge.sh down
# Windows host: pwsh scripts/cdp-bridge.ps1 down
# If MCP was registered: claude mcp remove chrome-devtools-host
```

When launched via `up --box`, host `down` also folds box relay via `sbx exec ... down` using box scope saved at `up` time. To fold box alone, in box: `bash scripts/cdp-bridge.sh down`.

## Options / Env

Each option specifiable as flag (`--port` etc; Windows `-Port` etc) or env, priority **flag > env > default**.

| flag | env | default | purpose |
|---|---|---|---|
| `--port N` | `CDP_PORT` | `9222` (unless unspecified, auto-selects empty port) | host Chrome remote-debugging port. If explicit and occupied, abort; if unspecified, auto-scan for empty |
| `--relay-port N` | `CDP_RELAY_PORT` | `9333` | box relay listen port |
| `--profile-dir DIR` | `CDP_PROFILE_DIR` | unspecified: per `up`, `mktemp` creates, `down` deletes | disposable profile dir. If explicit, not auto-deleted on `down` (user-owned). Guard rejects known real profile roots but not exhaustive; if explicit, don't pass real profile |
| `--box NAME` | `CDP_BOX` | unspecified (all boxes allowed, relay manual) | at host `up`, (a) narrow egress via `--sandbox <box-name>` to that box only, (b) auto-launch box relay via `sbx exec` |
| `--no-connect` | — | off | suppress auto-launch of box relay on host `up` (Chrome + egress only) |

## Troubleshooting

| Symptom | Resolution |
|---|---|
| box `status` is `no` | verify host `up` ran / check `sbx policy ls` for `localhost:<selected-port>` allow (port shown in host `status`; auto-select doesn't guarantee 9222) |
| `relay started. host Chrome unreachable` | host Chrome down or policy not permitted. Check host `status` |
| `CDP_PROFILE_DIR points to real browser profile` | safety guard. Specify different dir (keep default recommended) |
| `localhost:<port> already has another process listening for CDP` | only appears if `--port` **explicitly set** and that port occupied (respect explicit intent, abort). Close it or specify different `--port`. Without explicit `--port`, auto-escapes to empty port so error doesn't appear |
| egress rule persists | find `localhost:<selected-port>` in `sbx policy ls` and delete (`down` attempts auto-delete. Confirm port via host `status`) |
| Windows host lacks `socat` | relay (box side) assumes bash inside Linux box. Use PowerShell for host-side `up/down` only |
