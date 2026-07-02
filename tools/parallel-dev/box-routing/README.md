# Box routing (sbx box → host → Traefik)

> This directory's publish + path generation is automated by `scripts/dev.sh route` subcommand (`up` / `add <box> [port] [name]` / `rm <name>` / `ls` / `down` / `detect`; Windows uses `scripts/dev.ps1 route`). What follows is a reference for **what happens**.

Minimal reference for routing dev servers running inside sbx boxes from the host via **hostname**.
The parent [../README.md](../README.md) targets compose stacks on host docker (docker provider / label), but dev servers inside boxes run in **the microVM's custom docker daemon** and can't directly connect to the host's `traefik-public` network, so docker provider can't pick them up. Instead, we publish the box's port to the host and use Traefik's **file provider** to route.

## Prerequisites

- **Docker Desktop (macOS / Windows) assumed**. `sbx ports --publish` publishes to host's `127.0.0.1:<port>` (loopback); containers reach it via `host.docker.internal`. Docker Desktop resolves this to the host's loopback.
- **Linux native Docker Engine caveat**: `host.docker.internal:host-gateway` resolves to the bridge gateway IP (e.g., `172.17.0.1`), which doesn't reach publish targets listening only on `127.0.0.1`, resulting in **502**. On Linux, publish to all interfaces (` sbx ports <box> --publish 0.0.0.0:18001:3000`; `sbx ports` accepts `[[HOST_IP:]HOST_PORT:]SANDBOX_PORT` format with HOST_IP) so the bridge gateway IP can reach it. Or start the proxy with `network_mode: host` and set dynamic config URL to `http://127.0.0.1:<port>`.
- **`:80` can't be shared with parent proxy**: This proxy binds the same `:80` as the parent `../proxy.compose.yml` (docker provider). The two are **alternatives** for different scenarios (docker provider stack vs. box publish port), not concurrent. When routing box ports, stop the parent proxy and use this one (or change `ports` to `8088:80`, etc.).

## URL convention

```
web.<name>.localhost
```

- Default `<name>` for `scripts/dev.sh route add <box>` is **`<branch>.<repo>`** (from current checkout) → `web.<branch>.<repo>.localhost`. Explicit `<name>` can be arbitrary (allows dot-separated DNS label sequences)
- Branch / repo provides namespace separation, so parallel boxes / multiple stages don't collide on URLs
- `*.localhost` resolves to loopback by default in major browsers, so no hosts file editing needed

## Usage

Steps §2 / §3 below are **executed with this directory as cwd** (parent README uses full paths relative to repo root, but this procedure assumes relative paths):

```bash
cd tools/parallel-dev/box-routing
```

### 1. Publish box's port to host

```bash
sbx ports <box> --publish 18001:3000   # expose box's web(3000) to host:18001
```

### 2. Place dynamic config

Copy `boxes.example.yml` to `dynamic/`, editing box name and published host port:

```bash
cp boxes.example.yml dynamic/box1.yml
# edit Host(...) and host.docker.internal:<port> in dynamic/box1.yml
```

To add boxes, add router + service pairs (or one file per box).

### 3. Start the proxy

```bash
docker compose -f proxy.compose.yml up -d
```

→ Open `http://web.<box>.localhost` in your browser. The `dynamic/` dir is watched, so you can add boxes with just publish + dynamic config addition (no proxy restart needed).

### Cleanup

```bash
docker compose -f proxy.compose.yml down
sbx ports <box> --unpublish 18001:3000
```

## Modes (baseline / own Traefik / piggyback on existing shared Traefik)

Routing is an **optional layer** with 3 variants. `scripts/dev.sh route` subcommand handles the latter two.

1. **Baseline (no Traefik)**: If named URLs aren't needed, Traefik is unnecessary. Publish directly with `sbx ports <box> --publish <port>:<port>` and open `http://localhost:<port>`. **Simplest, works for everyone**.
2. **Own Traefik (default, `dev.sh route up`)**: If `:80` is available and you want named URLs. Start the proxy in this directory and view via `web.<name>.localhost`.
3. **Piggyback on existing shared Traefik (auto-detect)**: If Traefik already runs on host's `:80` (common for multiple projects under one). `:80` can only bind once, so don't start your own; instead **feed routes to that Traefik's file provider destination**. `dev.sh route` **auto-detects :80's file-provider Traefik**, so use without env vars:

   ```bash
   bash scripts/dev.sh route add <box>   # auto-detect :80's shared Traefik and piggyback (no up needed)
   bash scripts/dev.sh route detect      # check detection result (destination volume/dir)
   ```

   Detection: Search `docker ps` for containers with `traefik` in their image name publishing `:80`; read CLI arg `--providers.file.directory=<dir>` and find the mount (named volume / bind source) with that dir as destination. For **Traefik configured with file provider in config file or other auto-detect-incompatible setups**, explicitly specify destination via env:

   ```bash
   BOX_ROUTING_DYNAMIC_DIR=<dir>    bash scripts/dev.sh route add <box>   # watch bind dir
   BOX_ROUTING_DYNAMIC_VOLUME=<vol> bash scripts/dev.sh route add <box>   # watch named volume
   ```

   When piggybacking, `up`/`down` are no-ops (don't manage shared Traefik); only `add`/`rm`/`ls` manipulate the destination (no shared Traefik reconfiguration needed). Since multiple projects share the destination, `<name>` must be globally unique (default `<branch>.<repo>` includes repo, collision-resistant). `rm` only deletes entries with `# box` marker (this subcommand's signature) and won't accidentally erase hand-written config.

## Differentiation from parent reference

| | [../](../README.md) (docker provider) | This directory (file provider) |
|---|---|---|
| Routing target | compose stacks on host docker (auto-detected via labels) | loopback ports sbx boxes publish to host |
| Port reference | Traefik reads container port via docker network | Traefik reads host port from `sbx ports --publish` via `host.docker.internal` |
| Use case | parallel dev on host directly | parallel dev on box-primary (YOLO isolation) |
