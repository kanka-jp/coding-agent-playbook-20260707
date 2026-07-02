# Parallel development reference (Traefik)

Minimal reference for running multiple branches / services **simultaneously without port conflicts**.
A shared Traefik (reverse proxy) publishes `:80` only once, **routing by hostname**.

## URL convention

```
<service>.<repo>-<branch>.localhost
```

- Example: `web.coding-agent-playbook-stage-02.localhost` / `api.coding-agent-playbook-stage-02.localhost`
- **Each branch** has its own namespace, so parallel branches don't have URL collisions
- Multiple services in one app can be separated by **`web.` / `api.` subdomains**
- `*.localhost` resolves to loopback by default in major browsers, so **no hosts file editing needed** (macOS / Windows / Linux consistent)

## Usage

### 1. Start the shared proxy once only

```bash
docker network create traefik-public   # skip if it already exists (just throws an error)
docker compose -f tools/parallel-dev/proxy.compose.yml up -d
```

Traefik per branch causes `:80` collisions, so share a single proxy. Shared network is `traefik-public`.

> **If shared Traefik (`traefik-public`-based) is already running, skip this step 1**.
> If the existing proxy runs on `--providers.docker.network=traefik-public`, just starting the stack below handles routing.

### 2. Start app stack per branch

Pass `STACK=<repo>-<branch>` (replace branch `/` with `-`). Also use the same value for `-p` to isolate per branch.

```bash
STACK="$(basename "$(git rev-parse --show-toplevel)")-$(git rev-parse --abbrev-ref HEAD | tr '/' '-')"
STACK="$STACK" docker compose -p "$STACK" -f tools/parallel-dev/stack.compose.yml up -d
```

→ Open `http://web.$STACK.localhost` / `http://api.$STACK.localhost` in your browser.

Run the same 2 commands in a different worktree (different branch) to add another URL for that branch (parallel, no collisions).

### Cleanup

```bash
STACK="<repo>-<branch>" docker compose -p "<repo>-<branch>" -f tools/parallel-dev/stack.compose.yml down   # that branch's stack
docker compose -f tools/parallel-dev/proxy.compose.yml down                                               # shared proxy (only if you started it)
```

> If `:80` is in use elsewhere, change `ports` in `proxy.compose.yml` to `8080:80`, etc. (URL becomes `...localhost:8080`).

## Swap in your own app

Replace `traefik/whoami` in `stack.compose.yml` with your build and adjust `server.port` to your listen port:

```yaml
  web:
    build: ./web
    networks: [traefik-public]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${STACK}-web.rule=Host(`web.${STACK}.localhost`)"
      - "traefik.http.services.${STACK}-web.loadbalancer.server.port=3000"
```

> Don't expose internal services like DB to `traefik-public`; add a separate internal network and connect them there (only web/api exposed).

## Relationship with YOLO sandbox

- The `docker.sock` passed to Traefik is **host-side regular docker** in read-only mode; it's **not** inside sbx boxes (microVM · custom docker daemon). Isolation boundaries are not crossed.
- To route by name apps running inside a box, **publish the box's port to host first with `sbx ports <box> --publish`**, then load it into host's Traefik. Box-internal containers run in the microVM's custom docker daemon, so they don't directly connect to the host's `traefik-public` network.
- This docker provider (label) approach only picks up containers on host docker; box ports only published to host don't qualify. For actual config routing box ports by name, use [box-routing/](box-routing/README.md) (file provider approach).
