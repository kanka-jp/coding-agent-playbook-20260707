# Decision Record: Place devcontainer sandbox as foundation in main

**Status: Superseded (2026-06-18)** — [parallel-hotl-execution.md](parallel-hotl-execution.md) accepted sbx (Docker Sandboxes) as the execution platform, and the devcontainer sandbox (`.devcontainer/`) from this record was removed from the repo. Soft boundary (self-made firewall is not hard boundary against compromised agents; see "Limitations" below) is structurally insufficient for parallel HOTL. What follows remains historically for reference before removal.

## Decision

Place a **devcontainer sandbox (`.devcontainer/`) as foundation in main** to safely run Claude Code in an isolated environment. Not stage-specific.

Rationale: `stage/*` are merely forks from base branch; sandbox is shared execution infrastructure across the playbook, so it should exist in main (the fork origin) from the start. This updates the initial premise (construction premise in `CLAUDE.md`) of "main contains only lecture-progression files" by owner decision. `.devcontainer/` is neither lecture content nor project code of a specific stage, but **repo-wide execution environment**.

## Technology selection conclusion (summary)

- Requirements: ① Claude Code ② VM/container isolation ③ Safe in YOLO/auto-mode ④ Mac/Windows both
- Conclusion: **Official dev container (with egress firewall)**. Same on Mac/Windows via Docker Desktop, whole-process isolation, safe to run `--dangerously-skip-permissions`. If cloud: Claude Code on the web is alternative (managed VM, zero config). 
- Not adopted / limited: Built-in Bash sandbox alone (only Bash constrained, insufficient for YOLO), sandbox-runtime (no native Windows, beta), kernel isolation like Edera (Linux/K8s only).

## Real-world verification (2026-06-14, macOS arm64 / Docker 29.3 / `@devcontainers/cli` 0.87)

`up` → postStart auto-applied, verified:

- Claude Code 2.1.177 installed (claude-code feature, PATH managed correctly)
- Non-root (uid 1000 node) / vanilla (`~/.claude` absent) / host FS invisible (`/Users` absent)
- Egress default policy DROP; unauthorized `example.com` → HTTP 000 blocked, authorized `api.github.com` → 200
- Simulated AWS key POST to unauthorized host → blocked (injected key does not leak)

## Findings and hardening (official as-is is unsafe)

Official `init-firewall.sh` aborts before DROP if one allowlist domain resolution fails = **fail-open**. Triggered on `statsig.anthropic.com`. Hardening: ① non-fatal domain resolution failure (skip) ② fail-closed trap on abnormal exit. To avoid fail-open feature bundle version, renamed `firewall.sh`.

## Egress firewall via Squid domain allowlist (2026-06-17)

Initial IP-based ipset allowlist (resolve domains on startup, pin IPs + GitHub CIDR) could not follow **Docker Hub registry/blob CDN IP rotation** (cloudflare/cloudfront); in-container `docker pull` failed with `dial tcp <ip>:443: i/o timeout`. Replaced with **Squid explicit forward proxy allowing by domain**, not IP:

- Run Squid as explicit forward proxy on `127.0.0.1:3128`, judge CONNECT hostnames against `dstdomain` allowlist and **blind tunnel without decryption** (no MITM/CA/ssl-bump needed). Transparent intercept not used because SO_ORIGINAL_DST becomes local on same-host OUTPUT.
- iptables default DROP on box OUTPUT, **only allow Squid (proxy uid) outbound 80/443**. Direct egress without proxy blocked (fail-closed). QUIC (udp443) DROP, IPv6 disabled via sysctl + ip6tables DROP backstop.
- Box tools via `HTTPS_PROXY` env, dockerd via `daemon.json` proxy to Squid.
- **DinD coexistence**: firewall does not flush/delete dockerd chains (DOCKER-FORWARD, etc.) — breaking them causes `docker network create` / compose to fail. Nested container egress containment placed in DOCKER-USER chain referenced by dockerd; nested↔nested traffic allowed, external only DROP.
- **Hardened via 5-AI debate-review (Claude/Codex/Antigravity/Cursor/Grok)**: ① ip6tables backstop ② eliminate fail-open window (policy DROP before flush) ③ limit Squid bind to loopback ④ prefix telemetry/login domains with dot ⑤ fix DinD chain destruction. Real-world verification (arm64): docker pull / network create / nested↔nested / nested→external blocked / box egress containment all confirmed.

## Limitations

- **Egress firewall is defense-in-depth, not hard boundary against compromised agents**. The `node` process in-container has passwordless root sudo and Docker privileges, so compromised agents can destroy firewall with `sudo iptables -F` / `sudo -u proxy <cmd>` / `docker run --network host ... iptables -F` and exfil injected keys to any host. **In normal operation (non-compromised), egress is contained, but against serious attack, firewall is powerless**. Since key holders (root/docker) reside in the same container as the boundary, structurally impossible to seal in-container. True containment requires host-side firewall / separate netns sidecar / VM isolation (Claude Code on the web, etc.) **out-of-container enforcement**. Official Anthropic devcontainer has the same nature. This container accepted as defense-in-depth for teaching workshop purposes.
- Exfiltration via allowed domains is inevitable (GitHub allowed → gist, etc.). DNS (udp/tcp 53) open; DNS tunneling remains (accepted residual). Broad RFC1918 directly permitted, so corporate/VPC can reach internal hosts (dev laptop only operation assumed).
- Squid does not limit upstream dst IP, so allowed domains resolving to internal IPs could be relayed by Squid (debate-review R2 note). Non-concrete threat on dev laptop (requires trusted DNS control or root), so not implemented; **but if operating on cloud VM, add dst-deny to IMDS (169.254.169.254) / loopback / RFC1918 in `squid.conf`**.
- Container isolation, not VM-grade. Untrusted code needs VM / web. Injected keys recommend short-lived / scoped tokens.

## How changes were applied and git reconstruction premise

At the time this change was applied, repo policy was **no PR needed** (direct commit / push to main), so this change went directly to main. **Policy was later revised to require PR** (current `CLAUDE.md` "Commit / PR operations": changes via PR, no direct commit / push to main).
Commit / branch relationships across directories will later be reorganized by owner via **git history rewriting**, and `.devcontainer/` is expected to be reconstructed in a state of "existing in main from the start." History rewriting itself is owner work.
