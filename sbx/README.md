# sbx Custom Image / Kit

The execution foundation of the playbook for running coding agents inside **microVM-per-agent hypervisor boundaries** with [Docker Sandboxes (`sbx`)](https://docs.docker.com/ai/sandboxes/). Foundation for safely parallelized coding agent / HOTL (Human-On-The-Loop) operations.

A configuration where **claude and codex coexist** in a neutral `shell-docker` base image, launched with **built-in claude agent** so claude inside the box can call codex for **mutual review**. For verification and rationale that led to this design, see [docs/decisions/parallel-hotl-execution.md](../docs/decisions/parallel-hotl-execution.md) (Accepted).

## Why sbx? (hard boundary)

Custom firewall-based sandboxes (old `.devcontainer/`, removed) are defense-in-depth, not hard boundaries (the `node` inside the box has root sudo / docker privileges, so a compromised agent can breach egress). HOTL with approval gates removed and parallel execution has thin monitoring, so soft boundaries are structurally insufficient. sbx centers on microVM-per-agent hypervisor boundaries and has hard boundaries that can't be broken even by VM-internal root.

## Why built-in claude agent + codex mixin?

Secret proxy injection (injecting auth header on host without putting tokens in box) **is provisioned by sbx on host only when agent position resolves to Docker built-in agent**. With custom (`kind: sandbox`) agents, neither claude nor codex have secret placeholders registered, so proxy injection doesn't work (confirmed by live testing). Note: **with anthropic, only API keys are proxy-injection targets**; subscriptions (Pro/Max) authenticate not via proxy injection but via `/login` inside the box or by registering `claude setup-token` with `sbx secret set` for route C to auto-provision in box (either way, tokens end up in box—see "Authentication" below). Thus:

- **Base image is neutral `shell-docker`** (using `claude-code-docker` as base would privilege claude). Bake claude / codex / chrome into image and pass with `-t`.
- **Agent is built-in `claude`** (`sbx run claude`). With built-in agent, sbx can proxy-inject secrets (**API key** gets auth header injected on host, token doesn't enter box). **Subscriptions (Pro/Max) authenticate not via proxy injection but via `/login` inside box or setup-token secret registration (route C), with OAuth token stored in box** (see "Authentication" below).
- **Codex is a mixin (`playbook-kit/`) that only opens egress**; subscription authentication **transfers host `~/.codex/auth.json` to box** and passes real tokens directly to codex (see "codex subscription authentication" below). Codex proxy injection works only with built-in codex agent, not in claude boxes.
- `shell-docker` is a variant of common base `shell` **with Docker Engine (DinD) added**. Playbook uses compose inside boxes ([ADR](../docs/decisions/parallel-hotl-execution.md) acceptance criterion), so `-docker` lineage is needed. DinD is sbx providing privileged microVM + block volume + dockerd auto-start for `-docker` lineage; **manually adding docker to raw `shell` doesn't give DinD**.

## Prerequisites

- Host has `sbx` CLI (Docker Sandboxes) installed and authenticated with `sbx login`
- Docker is running

## Build image + load into sbx

```bash
docker build --load -t coding-agent-playbook-sbx sbx/   # --load: enters local image store even with non-default BUILDX_BUILDER driver
docker save coding-agent-playbook-sbx -o cap-sbx.tar    # tar for sbx runtime
sbx template load cap-sbx.tar                           # import into sbx template store
```

Base is `docker/sandbox-templates:shell-docker` (neutral base, includes DinD). Add workshop tools (fonts / headless Chromium) and chrome-headless wrapper for chrome-devtools MCP + CDP env vars (`CDP_EXEC` / `CDP_HEADLESS`), and **bake claude / codex from official standalone installers on equal footing**. Install runs on host network at build time, unaffected by runtime egress allowlist, keeping box runtime egress tight.

Claude inside box has default model set to **Opus** (baked in image as `ENV ANTHROPIC_MODEL=opus`). The `opus` alias always points to latest Opus. Since it's baked in image, **doesn't affect host-side claude** (box-only). Baking in env instead of `~/.claude/settings.json`'s `model` field because built-in claude agent rewrites settings.json on startup and drops the baked `model` (confirmed in testing). Box gets no `--model` or other `ANTHROPIC_MODEL`, so this env has sole precedence authority. Running `/model` inside box switches current session immediately (`/model` takes priority over env), but boxes are basically disposable single-sessions, so no real harm from env default.

> ⚠️ **`sbx template load` is required**. sbx's Docker daemon doesn't share host's local image store and pulls from registry; a local image from just `docker build` fails with `pull failed` on box creation ([Templates doc](https://docs.docker.com/ai/sandboxes/customize/templates/)). If Dockerfile changes, rebuild → re-save → re-load.

> ℹ️ **When only updating agent version** (Dockerfile unchanged, just updating claude / codex to latest): the installer `RUN` string doesn't change and Docker cache-hits, **locking to old version**. Change `AGENT_CACHEBUST` ARG (placed right before installer layer) value and rebuild to skip that install layer's cache and refetch:
>
> ```bash
> docker build --load --build-arg AGENT_CACHEBUST=$(date +%s) -t coding-agent-playbook-sbx sbx/
> docker save coding-agent-playbook-sbx -o cap-sbx.tar && sbx template load cap-sbx.tar
> ```
>
> (`bash scripts/build-image.sh` / `scripts/build-image.ps1` condenses these 2 lines to 1)
>
> Upstream heavy apt / Chromium layers before ARG reuse cache (faster than `--no-cache` full rebuild).

## Authentication

### claude

Claude has **3 routes**. For running subscriptions (Pro/Max) **across multiple boxes / in parallel**, **route C (setup-token, all-boxes auto-auth without per-box ops) is recommended**. For quick one-off box startup, route B (`/login` inside box). To keep tokens out of box (minimize), route A (API key). Routes B / C put tokens in box.

#### Route A: API key (proxy injection, token stays off box)

```bash
sbx secret set -g anthropic   # Paste API key (sk-ant-...)
```

Built-in claude agent proxy-injects API key. Secret is stored in host keychain; box only gets sentinel value (`SBX_CRED_ANTHROPIC_MODE=apikey`, real token never enters box).

#### Route B: Subscription (Pro/Max) (`/login` in box, token in box)

**Interactive OAuth flow from `sbx secret set -g anthropic --oauth` is not available** (rejected with `anthropic OAuth cannot be started from sbx secret set; sign in from inside the Claude sandbox`, confirmed v0.33.0). To auto-authenticate all boxes via secret registration, use route C with `claude setup-token` token. For one-off boxes, `/login` inside:

```bash
sbx run <box>      # Once claude starts, do /login (claude.ai OAuth, interactive)
```

On completion, OAuth token is **stored in box at `~/.claude/.credentials.json`** (like codex's auth.json, real tokens end up in box). Unlike route A, there's no token-not-in-box property; codex's security tradeoff applies to claude too.

#### Route C: Subscription + setup-token (secret registration for all-box auto-auth, **recommended for multiple boxes / parallel**)

Route B's `/login` requires interaction per box. For parallel multi-box, **register subscription's long-lived token once in secret**, then new boxes auto-auth on creation:

```bash
claude setup-token             # Once on host (interactive, browser). Outputs long-lived token sk-ant-oat01-...
sbx secret set -g anthropic    # Paste the token (sbx registers sk-ant-oat... as OAuth)
```

`sbx secret ls` showing `anthropic (oauth configured)` means registration is done. Subsequent `sbx create` / `sbx run` boxes **auto-generate `~/.claude/.credentials.json` at creation**, and claude works without `/login` or manual cp (confirmed: `claude -p` succeeds on new box after oauth secret registration).

- **Zero per-box operations**: No box-by-box `/login` from route B, no manual credentials cp
- **Token in box**: Auto-generated credentials go on box filesystem (same security tradeoff as route B). Box access tokens are short-lived (~hours) and refresh; underlying long-lived setup-token stays in secret (host keychain)
- Keeps subscription active (unlike route A's API key, no API billing)

> ⚠️ What you paste to `sbx secret set -g anthropic` is **setup-token (`sk-ant-oat01-...`)**. Pasting API key (`sk-ant-api...`) becomes route A (apikey mode, proxy injection). The `--oauth` flag doesn't work with anthropic (see route B).
> ⚠️ **Untested**: refresh token rotation behavior under heavy parallel multi-box sustained load is not stress-tested. Setup-token is assumed minted independently per box, but if parallel 401s occur, use separate accounts per box or route A (API key).

### codex (subscription, auth.json transfer)

Codex OAuth is not proxy-injected in claude boxes, so transfer real tokens from host to box:

```bash
# 1. On host, subscribe-login to codex (browser). ~/.codex/auth.json holds real token
codex login

# 2. After box creation, transfer auth.json to box and give agent ownership
#    (kit doesn't create .codex on startup, so prepare destination dir first)
sbx exec <box> sudo install -d -o 1000 -g 1000 /home/agent/.codex
sbx cp ~/.codex/auth.json <box>:/home/agent/.codex/auth.json
sbx exec <box> sudo chown 1000:1000 /home/agent/.codex/auth.json
```

Codex talks directly to `chatgpt.com/backend-api/codex` with real tokens from transferred auth.json, auto-refreshing at `auth.openai.com` (mixin allows egress to both hosts, no serviceAuth so proxy doesn't touch auth headers).

> ⚠️ **Parallel box constraint**: transferring same `auth.json` to multiple boxes and running parallel, OAuth provider **rotates refresh token** on one box's token refresh, invalidating other boxes' / host's old refresh tokens → 401s. For stable codex parallel execution, use separate account per box or API key route below.

> ⚠️ **Security tradeoff**: auth.json transfer **puts codex's real tokens (including refresh tokens) on box filesystem**. Loosens sbx's secret-proxy separation (keeping secrets off boxes), so compromised agents can read/exfil tokens → persistent access to ChatGPT subscription account. Hard boundary of microVM itself is unchanged. Using claude on **route A (API key)** keeps claude's tokens off boxes, minimizing real tokens in box to codex alone (**subscription routes B (`/login`) / C (setup-token) put claude tokens in box too**, so minimization doesn't work). On suspicious behavior, rotate real tokens placed in box: codex—sign out / re-login ChatGPT on host; claude on subscription routes—revoke session on claude.ai; **destroy each box's `~/.claude/.credentials.json` (recreate boxes)** (host secret updates only affect future-provisioned boxes; existing boxes' distributed tokens need separate revocation. Route C: re-issue `claude setup-token` on host to expire old token on provider side, then swap secret ※ whether re-issuance bulk-expires existing boxes is untested). For split billing and safer stance, use OpenAI **API key** for codex (then add openai's `serviceDomains`/`serviceAuth` to mixin and proxy-inject `OPENAI_API_KEY`. Auth.json transfer becomes unnecessary).

> ⚠️ Global secrets (`-g`) **take effect at box creation**. After set/change, recreate boxes.

## box-primary (Basic: run inside box)

From repo root, launch with built-in claude agent + image + codex mixin:

```bash
sbx run claude -t coding-agent-playbook-sbx --kit ./sbx/playbook-kit .
```

- agent = built-in `claude` (YOLO `--dangerously-skip-permissions` is baked into built-in claude entrypoint). Claude is driver, shells out to codex for mutual review.
- Before using codex, do auth.json transfer from "codex subscription auth" above.
- `playbook-kit/` is mixin that adds codex egress. If kit changes, recreate box (`sbx rm <name>`).

## Parallel (multiple boxes for separate tasks)

When running multiple boxes in parallel, use **`sbx create` (non-interactive creation) → `sbx run <name>` (attach) in 2 stages**:

```bash
sbx create --name box1 claude -t coding-agent-playbook-sbx --kit ./sbx/playbook-kit --clone .
sbx create --name box2 claude -t coding-agent-playbook-sbx --kit ./sbx/playbook-kit --clone .
```

After creation, attach from separate terminals:

```bash
sbx run box1
```

```bash
sbx run box2
```

- `--clone` = private clone of repo inside box (each box has independent working copy, no collision in parallel). Each box's commits can be recovered from host-side `sandbox-<name>` git remotes
- Multiple `--clone` boxes of same repo can coexist
- For parallel claude subscriptions, **route C (register setup-token as secret) is easiest**: each box auto-fetches credentials on creation, no per-box operations. Using route B (`/login`) requires login per box after attach (see "Authentication")
- Each codex-using box requires auth.json transfer

## HOTL Monitoring (peek at box from host)

Let agent inside box run while host just observes without intervening:

```bash
sbx ls                                    # Running status / published ports
sbx exec box1 sh -c 'git -C /run/sandbox/source log --oneline -8'   # Peek at progress read-only
```

View dev server inside box from host browser (escape hatch):

```bash
sbx ports box1 --publish 3000
```

Open published host `127.0.0.1:<port>` in host's Chrome. `--clone` repo is at `/run/sandbox/source` in box.

To **distinguish dev servers of multiple boxes by name** like `web.box1.localhost` / `web.box2.localhost`, route published host ports via Traefik file provider (avoids remembering port numbers). Production config and steps: [../tools/parallel-dev/box-routing/](../tools/parallel-dev/box-routing/README.md).

## Gotchas

- **`shell` agent mismatch warning is expected**: `sbx create` / `sbx run claude` shows `template "coding-agent-playbook-sbx" was built for the "shell" agent but you are using "claude"` — normal. This template's flavor is `shell-docker` from base (intentionally selected neutral base; verify in `sbx template ls` FLAVOR column), and launching it with built-in `claude` agent triggers sbx's flavor↔agent consistency check, outputting a generic warning (not real harm detection). Box launches normally with claude agent (`sbx ls` AGENT column shows `claude`). Don't follow warning's suggestion to `sbx run -t ... shell` (**if you enter with shell agent, claude isn't driver and built-in claude agent's secret proxy injection stops working**).
- **Cold-start transience**: directly after waking stopped box with `sbx exec`, egress proxy / in-box Docker daemon aren't warmed up; first few seconds may see egress timeouts or DinD command failures. After warming, stable (distinguish from permanent failures).
- **Egress allowlist**: in-box runtime is default-deny + allowlist (`api.anthropic.com` / `**.github.com` / `registry.npmjs.org` / `docker.io` etc allowed, others actively rejected by proxy with 403). Codex's `chatgpt.com` / `auth.openai.com` opened by mixin's `network.allowedDomains`. Build runs on host network, so installer fetching is unaffected.
- **Nested egress also blocked**: direct egress from containers launched inside box Docker is also blocked at VM boundary, can't bypass allowlist.
- **Real tokens placed in box**: codex's auth.json (always) and `~/.claude/.credentials.json` when using claude via subscription routes B (`/login`) / C (setup-token). See security tradeoff above. These are on box filesystem, so don't expose box to untrustworthy input (using claude with route A's API key keeps claude off-box).
