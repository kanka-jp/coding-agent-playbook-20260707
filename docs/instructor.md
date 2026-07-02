# For Lecture Organizers

## Operations Model

- **branch / PR**: units where agents actually work. PRs remain as execution logs
- **`stage/NN-<name>` branches**: snapshots of project states it passes through (orphan lineage not sharing history with main). Take each phase's **starting state** as checkpoint, arranged in **chain** so each phase's endpoint becomes next phase's start (ops & bug fix has both "broken" and "fixed" branches, so checkpoint count exceeds phase count. See "Stages" below)
- **git worktree**: immediately open "where we've progressed to" during lecture (3-minute-cooking style)

## Create New Stage

```bash
bash scripts/internal/new-stage.sh 01-blank                 # Project's first stage (orphan)
bash scripts/internal/new-stage.sh 02-onepager 01-blank     # Branch from stage/01-blank
```

Windows (PowerShell):

```powershell
powershell -ExecutionPolicy Bypass -File scripts/internal/new-stage.ps1 -Name 01-blank
powershell -ExecutionPolicy Bypass -File scripts/internal/new-stage.ps1 -Name 02-onepager -Base 01-blank
```

Stage conventions (orphan separation / naming / no lecture-progression files) see [CLAUDE.md](../CLAUDE.md) "Stage branch conventions".

## Slides

Lecture slides go in `slides/<NN-slug>.html` **by phase** (5 slides: brainstorm / design / implementation / finalization(parallel issue handling) / operations & bug fixes. Slides correspond to phases not states, so checkpoint count differs. Single self-contained HTML reading reveal.js from CDN, content is markdown bullet points (`---` separates slides). Humans write slide content.

- **Create**: copy `slides/template.html` to `slides/<NN-slug>.html`, fill `<textarea>` markdown with bullet points (don't touch HTML template)
- **View**: just open HTML in browser (local `file://` works, no build needed)
- **Distribute (planned)**: when public, serve from GitHub Pages URL `/<repo>/slides/<NN-slug>.html`

## Stages (checkpoint chain)

Lecture has **5 phases: brainstorm → design → implementation → finalization(parallel issue handling) → operations & bug fixes**. Each phase: immediately open its **starting state** via worktree and demonstrate (3-minute-cooking style). Each phase's endpoint becomes next phase's start, so stages form a **chain** of project states. Only operations & bug fixes needs both "broken state" and "fixed state", so they have 2 points.

Checkpoints arranged in state chain (✅ = ready / ⬜ = planned):

| stage | state | Which phase / how opened | |
|-------|-------|-------------------------|---|
| `stage/01-blank` | Empty (root commit / 0 files. Starting prompt given verbally during execution) | **Brainstorm** start → create one-pager in demo | ✅ |
| `stage/02-onepager` | Has one-pager | Brainstorm endpoint / **Design** start → write design doc in demo | ✅ |
| `stage/03-design` | Has `docs/design.md` (full-stack + AWS/ECS config) | Design endpoint / **Implementation** start → build MVP in demo | ✅ |
| `stage/04-mvp` | Working MVP (monorepo: web / api / mock / core / infra) | Implementation endpoint / **Finalization(parallel issue handling)** start → fix issues in parallel | ✅ |
| `stage/05-fixed` | MVP polished from issues (healthy state after parallel issue handling) | **Finalization(parallel issue handling)** endpoint | ⬜ |
| `stage/06-*` (broken) | Bugs injected / failures reproduced | **Operations & bug fixes** start (broken state) → fix in demo | ⬜ |
| `stage/07-*` (fixed) | Bugs fixed | Operations & bug fixes endpoint (answer key) | ⬜ |

- Slug describes "what **state** this checkpoint is" (state description, not lesson name). Each stage branches from prior (`stage/01-blank` only orphan).
- **Finalization(parallel issue handling)** phase execution procedure (manual / ultracode parallel) see [parallel.md](parallel.md) "Handle large issue backlogs in parallel".
- **Operations & bug fixes** can't use healthy `05-fixed` directly as start (needs broken state), so branch `05-fixed` to **inject bugs or reproduce operational failures**, creating separate `06-*` (broken·start) / `07-*` (fixed·endpoint). Result: 7 checkpoints `01`–`07` (5-chain + 2 ops pairs), 2 more than 5 phases. Concrete slugs determined at setup.
- Lecture slides correspond to **phases** not states. See "Slides" above.

**Current status (2026-06)**: brainstorm–implementation checkpoints ready. `stage/01-blank` (empty start·root commit / 0 files) → `stage/02-onepager` (one-pager) → `stage/03-design` (`docs/design.md`) → `stage/04-mvp` (working MVP) exist in chain. Remaining:
- Generate `stage/05-fixed` (branch from `04-mvp`. Polish state after parallel issue handling)
- Design `stage/06-*` (broken) / `stage/07-*` (fixed) — pair for operations & bug fixes phase (inject bugs into working MVP or reproduce operational failures)
