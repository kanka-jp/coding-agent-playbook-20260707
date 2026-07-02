# Skills (granularity and layers)

Skills / capabilities are organized **by abstraction layer**. Higher layers are more abstract (what / when), lower layers are more concrete (how / implementation), and each layer knows only "one level below," hiding lower details and delegating to concrete implementations (homomorphic to SOLID's "depend on abstractions"). This rule is the SoT for skill structure in this repo. For overall flow, see [CLAUDE.md](../CLAUDE.md) "Development Flow"; for the assumption of bundled skills, see [CLAUDE.md](../CLAUDE.md) "Workshop Assumption".

## Layers

| Layer | Abstraction | Role | Example |
|---|---|---|---|
| **Flow layer** (CLAUDE.md + rules/) | Most abstract | Lifecycle and "when/which skill fires." Not a skill itself; always-present context | "Development Flow" overview |
| **orchestrator skill** | Mid | Composes phases, composes leaf skills + runs operational checks | `pr-codex-ci` |
| **leaf skill** | Concrete | Single-purpose. Does not call up. Adds **one layer of abstraction** to raw tools (context judgment, normalization, etc.) | `a2a-review` |
| **scripts / tools** | Most concrete | Implementation that skills drive | `scripts/internal/a2a-review.sh` / `server.py` |

Example: Flow "after PR creation, run review + CI" → orchestrator has 2 variants by execution environment (`pr-codex-ci` = box / `pr-ci` = host) with "review = `/a2a-review` or `/codex-review`·CI check (including stale/run-id judgment)·loop" → leaf `a2a-review` "send from box via A2A to cdx-pair" / `codex-review` "directly exec host CLI" → tool `internal/a2a-review.sh` "launch codex via A2A" / `codex` CLI itself. At each step, one layer of abstraction is peeled off and made concrete.

## Composition rules

- **Calls are top→bottom only** (flow layer → orchestrator → leaf → tools). **No cycles** (lower layers don't know about higher layers).
- **Skill→skill only orchestrator → leaf** (leaves don't call other skills, or minimally). Claude Code actually supports skill→skill via the Skill tool (`pr-codex-ci` calling `/a2a-review` is the example). **Calls are not gated by the calling skill's `allowed-tools`**, so orchestrator `allowed-tools` doesn't need to list called leaves.
- **Environment dispatch exception (peer calls allowed)**: When the same role has different skill implementations on box vs. host (`codex-review` ↔ `a2a-review`, `pr-ci` ↔ `pr-codex-ci`), you may detect the execution environment and delegate to the appropriate skill. Conditions: **unidirectional** (delegate skill doesn't call back the caller) and **no loops**. This delegation becomes leaf→leaf / orchestrator→orchestrator, but we interpret it as implementing a flow-layer judgment as a skill-internal safety check. Ideally, detection happens at flow layer (CLAUDE.md / check `printenv SANDBOX_VM_ID` before invoke); skill-internal is a secondary safety net.
- **Each skill's layer uses the "Current Mapping" table in this rule as SoT** (avoid duplicate declarations in skill files to prevent drift). Skill descriptions must not use the words `orchestrator` / `leaf` in a way that **contradicts the skill's own layer** (example: don't use "orchestration" in a leaf skill's description).
- **Layers must mean something as abstractions**. Don't create leaf skills that just pass-through raw tools (no tool-wrappers without purpose). If you're adding nothing, don't make it a skill—call the tool directly from the orchestrator.
- **Minimal layer count** (current flow / orchestrator / leaf / tools = 4 is sufficient; don't add more).

## Current Mapping

| Skill | Layer | Description |
|---|---|---|
| `a2a-review` | **leaf** | **box-native** codex review, single invocation. From within a box, sends to the cdx-`<NAME>` pair codex via A2A, adding context judgment (sandbox box exclusion) and reviewer reachability. Equivalent to superpowers' `requesting-code-review` |
| `codex-review` | **leaf** | **host-native** codex review. Directly execs the host-installed `codex` CLI to obtain second opinion on PR diffs / files / free-form instructions. Host symmetric to `/a2a-review` (only transport differs; contract is the same) |
| `comment-sweep` | **leaf** | Pre-PR sweep. Judges newly added comments against [rules/code-comments.md](code-comments.md) norms → presents violation table → fixes via Edit after user approval. Default is `origin/HEAD...HEAD` diff; supports `--staged` / `--worktree` / `BASE_BRANCH` args |
| `co-evolve-check` | **leaf** | Pre-PR sweep. Detects retention bias (lingering old versions = `interface UserOld` + `User` running parallel / `getUserNew` wrapper, etc.). Caller without touching all + no public marker = `Confidence: high`. Non-blocking, report-only |
| `extension-bloat-sweep` | **leaf** | Pre-PR sweep. Detects forced expansions of existing files / functions / signatures (E1: appending to existing large file / E2: param ≥ 4 or optional ≥ 3 / E6: multiple modifies to same file). Non-blocking, report-only |
| `pr-codex-ci` | **orchestrator** | **box-native** post-PR phase. **Local** codex review (composes `/a2a-review`) + **CI check** + **remote gate composing `/pr-review-respond`** + fix loop |
| `pr-ci` | **orchestrator** | **host-native** post-PR phase. Composes `codex-review` (host codex CLI direct) + **CI check** + **remote gate composing `/pr-review-respond`** + fix loop. Host symmetric to `pr-codex-ci` |
| `pr-review-respond` | **leaf** | Fetches **PR reviews posted to GitHub** (bot + human from Copilot/qodo, etc.) → decides accept/reject → fixes/replies → resolves. Directly drives `gh api`, doesn't call sub-skills. Returns structured result (`pushed_changes` / `resolved_count` / `final_unresolved` / `checks_terminal`) to caller orchestrator (`pr-codex-ci` / `pr-ci`) and exits (**avoids cycles by not calling back the orchestrator**). Independent from orchestrator (codex second opinion invocation); also available for standalone invocation |
| `host-ask` | **leaf** | When inside a box needing host-side facts (other compose project / existing container / port holder / host fs outside mount / host-local service), Writes structured ask to `.claude/host-bridge/ask-<box-name>-<topic>-<seq>.md` and escalates to user. `<box-name>` obtained from `$SANDBOX_VM_ID` env (hook-independent). Reverse direction of `/box-session-context` (host → box transcript) for active ask (box → host); they complement each other. `<topic>` enables parallel asks (multiple physical issues in 1 box simultaneously) |
| `host-answer` | **leaf** | On host, reads ask file written by `/host-ask`, runs host-side investigation (docker / lsof / other compose config read-only), Writes paste-ready answer to `.claude/host-bridge/ans-<box-name>-<topic>-<seq>.md` (` ```host-ctx ``` ` fence) and escalates to user. Counterpart to `host-ask` |
| `box-session-context` | **leaf** | Pulls Claude session transcript from inside box on host, summarizes **read-only**. Drives `scripts/internal/box-session-context.sh`. Fills box-primary HOTL monitoring gap (statusLine session id → verify on host). Pairs with `/box-session-resume` (continuation) |
| `box-session-resume` | **leaf** | Injects box-internal session into host / another box and **resumes as the same session** via `claude --resume`. Auto-detects source → places in dest's project dir under original UUID name. **Environment dispatch**: host invocation directly runs `scripts/internal/box-session-resume.sh`, box invocation writes resume-req to host-bridge and delegates to `/box-session-resume-grant` (box→host peer delegation, homomorphic to `codex-review`↔`a2a-review`). Replaces old `box-session-handoff`. Pairs with `/box-session-context` (reference) |
| `box-session-resume-grant` | **leaf** | On host, reads box resume-req (`.claude/host-bridge/resume-req-<box>-<seq>.md` written by `/box-session-resume` box-delegate), displays contents (injection gate), execs `scripts/internal/box-session-resume.sh`, Writes `resume-ans-<box>-<seq>.md` + done sentinel. Resume version of `/host-answer`, but **executes a state change** (differs from read-only). Host-side counterpart of `/box-session-resume` box-delegate mode |

## Positioning of operational checks (CI check, etc.)

**Operational checks like CI check / dynamic verify are also leaf-level capabilities**, concrete elements the post-PR orchestrator composes. In flow, they're embedded as "post-PR = review + CI check + ..." ([CLAUDE.md](../CLAUDE.md) "Development Flow" step 4 / [rules/pr-followup.md](pr-followup.md)).

- **CI check** is implemented inline in step 3 (CI gate) of both `pr-codex-ci` and `pr-ci` orchestrators. Not raw `gh pr checks`, but with abstraction: stale detection right after push, run-id resolution, TUI hang avoidance, distinction between transient 0-checks and unconfigured CI ([.claude/skills/pr-codex-ci/SKILL.md](../.claude/skills/pr-codex-ci/SKILL.md) / [.claude/skills/pr-ci/SKILL.md](../.claude/skills/pr-ci/SKILL.md)).
- **Currently inline duplicate**. Once consumers reach 2 (`pr-codex-ci` + `pr-ci`), the norm would be to promote to a leaf skill (`/ci-gate`, etc.), but we left it as inline duplicate across both orchestrators temporarily when `pr-ci` was added. **Leaf extraction happens in a follow-up PR** (file a CI-gate extract issue at [https://github.com/kanka-jp/coding-agent-playbook/issues](https://github.com/kanka-jp/coding-agent-playbook/issues)). The decision axis is not "presence of abstraction" but **presence of independent reuse**, and we maintain the decision to extract based on reaching 2 consumers (homomorphic to how verify / deploy-watch are skill-ified in dotfiles).

## Future addition guidelines

- New skills should be added **at the phase (practice) level**, not tool-wrappers as leaves (superpowers has no tool-wrappers; all are phase skills).
- Orchestrator composes leaves, leaves stay single-purpose. **Connect as steps to the flow layer (CLAUDE.md)** (orchestrator = flow step).
- Before adding a skill, note in this rule's mapping "which layer / what to delegate one level down / what abstraction to add."
- **Minimize frontmatter (`name` / `description` only)**. `allowed-tools` is a standard Claude Code field, but since the box is YOLO (`--dangerously-skip-permissions`) and bypasses permissions, it's not load-bearing; don't write it. `maturity` and `[EXPERIMENTAL]` prefix in description are **dotfiles-specific, not standard Claude Code**, so don't use them (project is dotfiles-independent).

## Background

obra/superpowers ([https://github.com/obra/superpowers](https://github.com/obra/superpowers)) uses a flat fine-grained skill (phase-level) structure that composes and auto-triggers via Basic Workflow, with no tool-wrappers. This repo builds on that and the dotfiles principle "CLAUDE.md = norms / rules = details / skills = execution," and **handles granularity via abstraction layers, positioning CLAUDE.md's development flow as the composition layer (most abstract)**. Rather than bundling skills large, we organize fine-grained skills by layer and have the orchestrator compose leaves.
