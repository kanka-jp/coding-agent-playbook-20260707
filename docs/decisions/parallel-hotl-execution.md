# Decision Record: Execution platform for safely parallelized coding agents and HOTL

**Status: Accepted (2026-06-18)** — Passed verification gate (spike) on real hardware and adopted sbx (Docker Sandboxes) as the execution platform. Correspondingly, the `.devcontainer/` from [devcontainer-sandbox.md](devcontainer-sandbox.md) has been removed (soft boundary is structurally insufficient for parallel HOTL, so we maintain only one system = YAGNI). Verification results are recorded in each item under "Verification Gate (spike)" at the end.

## Background: Clarifying the goal

[devcontainer-sandbox.md](devcontainer-sandbox.md) made the decision to place `.devcontainer/` in main as "an execution platform to safely run Claude Code in an isolated environment," with educational value limited to the boundary condition of "accepted for teaching workshop purposes with defense-in-depth." This record overrides that "self-made sandbox as a safe execution platform" premise with an **updated goal** announced by the owner:

> The goal is **safely parallelized coding agents**, and **HOTL (Human-On-The-Loop)**.

In other words, the goal is not "teaching the primitives of sandboxing" but "**safely running multiple agents in parallel, with humans taking a monitoring and intervention stance (on the loop) rather than sequential approval**" operationally. The learning material is a means to reach that destination.

## Decision axis: HOTL requires "hard boundaries"

The essence of HOTL is **removing the human approval gate for each action** (= extension of existing box-primary YOLO operations). Without the approval gate, safety depends solely on **whether the boundary can withstand a "compromised agent"**. As parallelism increases, constantly watching all agents becomes impractical, so **we need hard boundaries to compensate for thinner monitoring**.

## Current limitations (self-made devcontainer)

A self-made firewall is **defense-in-depth, not a hard boundary**. The `node` process in the container has passwordless root sudo and Docker privileges, so a compromised agent can destroy egress with `sudo iptables -F` / `docker run --network host` (see [devcontainer-sandbox.md](devcontainer-sandbox.md) "Limitations"). **If humans monitored closely**, they would notice, but **in parallel HOTL monitoring becomes thinner**, so soft boundaries are structurally insufficient.

## Candidate comparison

| Aspect | Self-made devcontainer | Docker Sandboxes (sbx) |
|--------|------------------------|------------------------|
| Parallelism | One box per worktree (manual assembly, possible) | Clone mode / multiple microVMs (parallelism is first-class) |
| HOTL safety boundary | **soft** (root agent can break it) → requires dense monitoring | **hard** (hypervisor boundary, cannot be broken even by root in VM) |
| Credentials | In container (constrained by scope) | Out-of-container injection (sentinel + proxy) is default for true isolation. However, proxy injection targets only API keys; subscription auth (Claude subscription = /login in-container, Codex subscription = auth.json transfer) puts tokens in-container (see sbx/README.md security note) |
| Microservices | Can run docker compose in-container via DinD | Can run docker compose in-container via Docker engine in sandbox |
| Distribution | Bundled in repo (clone only) + Docker on host | Separate sbx installation on host (brew/winget) + authentication |
| Maturity | Self-managed | GA 2026-01-30 (new). Commercial pricing unconfirmed |

sbx emphasizes "Run AI Coding Agents **Safely**" with **microVM-per-agent hypervisor boundaries** as its core. The design philosophy directly aligns with the use case of "removing approval gates and running in parallel." However, it requires separate installation and authentication on host, departing from the "clone only" principle.

## Direction (Accepted)

1. **Adopt sbx as the execution platform**. It is purpose-built for HOTL safety requirements (hard boundary that withstands compromised agents) and ease of parallelism (microVM-per-agent). Place a custom image (with Claude/Codex bundled) with neutral `shell-docker` base and Codex egress mixin in `sbx/`, and launch with **built-in Claude agent** (Claude with API key proxy-injected, subscription /login in-container) via `sbx run claude -t coding-agent-playbook-sbx --kit ./sbx/playbook-kit .`. For Codex subscription, transfer host `~/.codex/auth.json` to the box (see sbx/README.md).
2. **Devcontainer (`.devcontainer/`) has been removed**. Once sbx passes spike and is adopted, there is no default reason to keep the inferior soft-boundary side (YAGNI: do not maintain two sandbox systems). The exception to maintain it (distribution barrier: since sbx requires host installation + authentication, "keep devcontainer that works with Docker only as no-install fallback") does not apply because **the owner determined that barrier as non-issue** (see spike #3), so it was removed. "Keep as teaching material to understand layers" was never a retention reason from the start.
3. **PAT scope narrowing is still essential after sbx adoption**. The hypervisor boundary stops token exfiltration, but it does not stop compromised agents from **misusing git push within scope** (HOTL makes this more important since there is no human gate). Use fine-grained, repo-scoped, short-lived PATs.

## Residual (survives even with isolation)

- **Misuse within scope**: As mentioned in 3 above, even with sbx, malicious commit / PR within token scope remains. Blast radius is constrained by token scope.
- **Exfiltration via allowed domains**: GitHub allowed → gist etc. remains for both configurations.

## Verification Gate (spike) — Results (2026-06-18 passed real-world verification)

Verified on macOS arm64 / sbx v0.32.0 (sbx platform gate. Current configuration: shell-docker base custom image in `sbx/` + multi-agent kit `playbook-kit`).

1. ✅ **sbx installation → clone-mode sandbox launch**: Launch multiple boxes in parallel with `sbx create --name <box> claude -t coding-agent-playbook-sbx --kit ./sbx/playbook-kit --clone .`.
2. ✅ **Parallel YOLO**: Launch multiple boxes independently and run in parallel (1 session per box, attach with `sbx run <box>`).
3. ✅ **Cost / multi-user**: sbx runs locally on each machine (no per-box central billing). Local usage is essentially free (only free Docker account login needed); paid tier is only for unnecessary enterprise governance (Admin Console / AI Governance). Practical parallelism ceiling is each user's RAM, not billing (microVM-per-agent consumes RAM; limit per box with `--memory`). Owner determined cost/scale as non-issue. Residual: official pricing unconfirmed (new product as of GA 2026-01-30).
4. ✅ **Observation and intervention (HOTL requirement)**: `sbx ls` (all box status/ports), `sbx exec` (read-only peek), `sbx run` (attach intervention), `sbx ports --publish` (host browser) are sufficient for one operator to manage several boxes on the loop. No live aggregated dashboard locally (aggregated UI only in paid Admin Console), but that is nice-to-have, not a blocker.
5. ✅ **Viewing in-sandbox dev server from host**: Expose in-container port 8080 to host `127.0.0.1:<port>` with `sbx ports <box> --publish 8080`, verified reachability via host curl / headful Chrome (escape hatch established).
6. ✅ **Compose stack in-sandbox (2 services)**: Docker (29.5.3) + compose (v5.1.4) inside container with nginx + alpine inter-service communication OK. Verified nested container direct egress also blocked at VM boundary (allowlist bypass impossible).

Note (egress boundary): In-container runtime uses default-deny + allowlist (anthropic / github / npm / docker permitted, others actively denied by proxy with 403). TLS interception via HTTP proxy `gateway.docker.internal:3128`. Transient failures appear immediately after cold start as proxy / DinD warm up, but stable once warmed.

## Sources

- [https://docs.docker.com/ai/sandboxes/](https://docs.docker.com/ai/sandboxes/)
- [https://docs.docker.com/ai/sandboxes/security/isolation/](https://docs.docker.com/ai/sandboxes/security/isolation/)
- [https://docs.docker.com/ai/sandboxes/security/credentials/](https://docs.docker.com/ai/sandboxes/security/credentials/)
- [https://docs.docker.com/ai/sandboxes/workflows/](https://docs.docker.com/ai/sandboxes/workflows/)
- [https://github.com/dockersamples/sbx-quickstart](https://github.com/dockersamples/sbx-quickstart)
- [https://github.com/github/gh-aw-firewall/blob/main/docs/api-proxy-sidecar.md](https://github.com/github/gh-aw-firewall/blob/main/docs/api-proxy-sidecar.md)
