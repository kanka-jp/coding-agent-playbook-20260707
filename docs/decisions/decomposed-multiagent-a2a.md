# Decision Record: decomposed multi-agent (1 agent 1 box + native auth + A2A coordination)

**Status: Accepted (2026-06-19, implementation is staged)** — Passed verification gate (spike) on real hardware. On top of the sbx microVM platform adopted in [parallel-hotl-execution.md](parallel-hotl-execution.md), decided to **decompose multiple agents into "1 box 1 agent" and coordinate via A2A**. Due to young spec + non-trivial build, implementation rolls out in stages 1-3. **This ADR evolves execution topology (agent placement in box); sbx adoption from [parallel-hotl-execution.md](parallel-hotl-execution.md) is unchanged.** The current co-located (Claude+Codex co-resident) model remains valid as current implementation until Stage 1 lands; this ADR's decision defines target end-state.

## Background

[parallel-hotl-execution.md](parallel-hotl-execution.md) adopted sbx as the execution platform. Currently **Claude+Codex reside in one box as built-in Claude agent**, with Claude shell out to Codex for mutual review (see [../../sbx/README.md](../../sbx/README.md)). This satisfies "safely parallel HOTL" but hits a wall on:

- **Extensibility**: Adding agents like Gemini / Grok or non-agent services (DB, search, tools) does not scale cleanly in a 1-box co-resident model.
- **Codex auth friction**: In a co-resident box, Codex subscription OAuth is not proxy-injected (agent-gating: injection is built-in agent only). This requires transferring `~/.codex/auth.json` from host to each box; in parallel multi-box scenarios, refresh token rotation leaves 401 risk (see security note in [../../sbx/README.md](../../sbx/README.md)).

Owner's updated goal: **Show trainees an extensible multi-agent development architecture where they can add Gemini/Grok or non-agent services later**.

## Decision axis: Extensibility requires "separation of concerns"

To make "adding agent / service" declarative, the approach is **1 box 1 concern (microservices philosophy) + coordination via standard protocols**. The industry converges on **A2A (agent ↔ agent) + MCP (agent → tool)**; extension becomes "publish Agent Card / register MCP server". A co-resident monolith structurally lacks this growth path.

## Decision (Accepted)

1. **Decompose into 1 agent 1 box**. Each box authenticates as built-in agent natively (Claude = path C Anthropic OAuth secret / Codex = OpenAI OAuth secret / subsequent agents use their native paths). **Discontinue auth.json transfer**. Token-in-box handling is asymmetric per agent: Codex's OpenAI OAuth secret **does not put token in box** via proxy injection (spike #1), but Claude path C provisions `~/.claude/.credentials.json` in-container (see auth section in [../../sbx/README.md](../../sbx/README.md)). Security tradeoffs detailed under "Residual" below.
2. **Target A2A (agent ↔ agent) for coordination**. Wrap each agent as A2A server (Executor shell-outs to CLI + advertises capability via Agent Card).
3. **Use MCP for adding non-agent / tools** (different layer from A2A, not mutually exclusive). Current playbook registers only `chrome-devtools` MCP server (see `.mcp.json`); Docker MCP Gateway not yet deployed. When adding non-agent service in Stage 2, consider Docker MCP Gateway.
4. **Future: place Agent Gateway on host side (egress control + discovery checkpoint)** (target end-state, implement in Stage 3). Current sbx controls egress with default-deny + allowlist (anthropic / github / npm / docker, etc.) + `gateway.docker.internal:3128` HTTP proxy (see egress note at end of "Verification Gate" in [parallel-hotl-execution.md](parallel-hotl-execution.md)). Stages 1-2 open necessary holes in current allowlist and coordinate via host broker; Stage 3 transitions to real Agent Gateway (agentgateway, etc.) unifying egress + discovery.
5. **Implementation is staged** (do not build full mesh at once = YAGNI):
   - **Stage 1**: Minimal real A2A slice. Make Codex an A2A server (`code-review` capability) → Claude / host throw review tasks as A2A clients and receive artifacts. Demonstrate Agent Card discovery + JSON-RPC task works between 2 boxes.
   - **Stage 2**: Add Gemini / Grok box as A2A server + Agent Card each. Add non-agents as MCP servers. Show "adding = Agent Card / MCP registration" works.
   - **Stage 3**: Once mesh matures, unify egress + discovery with real Agent Gateway (agentgateway, etc.).

## Why A2A (vs MCP / host-script)

- **host-script broker**: Minimal but lacks dynamic discovery / multi-agent extensibility. Used for PoC (proto-gateway, spike #4 below) but not target.
- **MCP only**: Agent → tool layer. Treats Codex as Claude's "tool", asymmetric for peer mutual review. Used alongside for non-agent service addition.
- **A2A**: Standard for peer agents. Extension is declarative (Agent Card). Shows cutting edge to trainees.

## Residual and tradeoffs

- Cost of building per-agent A2A server wrapper (CLI is not A2A-native).
- Box-to-box connectivity via host + egress policy (opens governed hole in isolation).
- A2A is young spec (churn risk). Implementation staged to localize impact.
- Subscription parallelism ceiling is plan's concurrent session cap (ChatGPT Pro priced for parallelism, within ToS). Rotation structurally avoids copies in box via proxy injection, but sustained refresh behavior requires observation (spike #2).
- **Claude path C token-in-box residual**: As per decision #1, `~/.claude/.credentials.json` is provisioned in Claude box; Claude box compromise could exfil real tokens (Codex's OpenAI OAuth secret stays outside box via proxy injection, asymmetrically absent here). Mitigation: switch Claude to path A (API key proxy-injected) for token-not-in-box; with subscription maintained, accept in-box token as residual (see security tradeoff in [../../sbx/README.md](../../sbx/README.md)).

## Verification Gate (spike) — Results (2026-06-19 passed real-world verification)

Verified on macOS arm64 / sbx v0.33.0 / current `sbx/` custom image.

1. ✅ **Native Codex auth in isolated box (zero transfer)**: `sbx secret set -g openai --oauth` (global) + `sbx create --name <box> codex -t coding-agent-playbook-sbx --clone .` shows on creation `Using stored OpenAI OAuth credentials`, `codex exec` responds with `provider: sandboxd` (proxy-injected). **No auth.json transfer, token stays outside box**. Confirmed Codex auth friction in co-resident box is resolved in Codex-base box.
2. ✅ **Parallelism**: `codex exec` simultaneously on 2 Codex-base boxes, both succeed (no 401). Sustained refresh rotation not stress-tested (proxy injection structurally avoids copies in box).
3. ✅ **Local environment boots in isolated box**: Codex-base box with node v22.x / npm 9.x / Docker 29.x (DinD). Can stand up dev server in-box and expose to host with `sbx ports <box> --publish` (see [parallel-hotl-execution.md](parallel-hotl-execution.md) spike #5; name routing at [../../tools/parallel-dev/box-routing/](../../tools/parallel-dev/box-routing/README.md)).
4. ✅ **Host-mediated coordination PoC (A2A proto form)**: Claude box (path C) generates function → host relays via `sbx cp` Claude box → host → Codex box → Codex box reviews and detects 2 real bugs. Confirmed Claude ↔ Codex across microVMs **can mutual-review with native auth via host mediation**. Stage 1 formalizes this broker with A2A protocol + Agent Card.

## Sources

- [https://github.com/a2aproject/A2A](https://github.com/a2aproject/A2A)
- [https://developers.googleblog.com/en/a2a-a-new-era-of-agent-interoperability/](https://developers.googleblog.com/en/a2a-a-new-era-of-agent-interoperability/)
- [https://github.com/a2aproject/a2a-python](https://github.com/a2aproject/a2a-python)
- [https://modelcontextprotocol.io/](https://modelcontextprotocol.io/)
- [https://www.docker.com/blog/docker-mcp-gateway-secure-infrastructure-for-agentic-ai/](https://www.docker.com/blog/docker-mcp-gateway-secure-infrastructure-for-agentic-ai/)
- [https://agentgateway.dev/](https://agentgateway.dev/)
- [https://arxiv.org/pdf/2505.07838](https://arxiv.org/pdf/2505.07838)
- [https://docs.docker.com/ai/sandboxes/security/credentials/](https://docs.docker.com/ai/sandboxes/security/credentials/)
