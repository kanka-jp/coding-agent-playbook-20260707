---
name: co-evolve-check
description: "Detects retention bias in pre-PR diffs where agents add new versions (interface/class/function wrappers like `FooV2` / `getUserNew`) alongside the old ones, when (a) all callers of the old symbol are touched in the same PR and (b) no public consumer markers exist (no public `package.json` exports / no PyPI metadata / no `openapi.yaml` / `*.proto` / `*.graphql` references / no `@deprecated` annotations). Auto-detects language (TS/JS via `package.json`, Python via `pyproject.toml` / `requirements.txt`) and silently skips when detection fails (project-agnostic, requires nothing from the host project). Outputs structured findings with subtractive questions (\"why retain old version?\"). Non-blocking, report-only. Use when about to create a PR (alongside `/comment-sweep`), or when the user mentions version retention after refactoring / backwards-compatibility shim / simultaneous update possible / co-evolution / dead code from version parallelism / internal API retention bias."
---

# co-evolve-check

Detects the pattern "trying to maintain backwards compatibility even though it's not a public API" from pre-PR diffs as a leaf skill ([rules/skills.md](../../../rules/skills.md)). Mechanically judges the **inverse case** of "external consumers exist = legitimate reason to keep current form" (= no external consumers = simultaneous update possible).

Like `/comment-sweep`, operates as a pre-PR sweep. Detects only without blocking PRs (non-blocking report-only).

## When to use

Primary trigger points:
- Before executing `gh pr create`, launch in parallel with `/comment-sweep`
- Before adding to an existing PR
- Late in work like "refactored", "removed duplication", "organized types", etc.

Typical agent scenarios that are detection targets:
- Running `interface User` and `interface UserV2` / `UserOld` / `LegacyUser` in parallel in TypeScript
- Running `class Foo` and `class FooV2` in parallel in Python
- Function wrapper parallelism (`getUser` + `getUserNew` / `getUserV2`)
- Scene where old version can be deleted in same PR (= all callers touched + no external consumers) but old version is kept

Cases not detected (silent skip / low confidence):
- Public APIs (symbol referenced from public `package.json` exports / PyPI metadata / `*.proto` / `openapi.yaml` etc)
- In intentional deprecation process with `@deprecated` / `Deprecation:` annotation
- Even 1 caller of old symbol not touched in same PR (= possibility of external consumer)
- Project where language auto-detection fails (no marker file for TS/JS/Python)
- Pure revert PR (all commit subjects in base..HEAD start with `^Revert "`)

## Arguments

| Argument | Description |
|------|------|
| `BASE_BRANCH` (positional, optional) | Explicitly specify base ref (e.g., `main`, `develop`). Default resolves via `origin/HEAD` → `main` in order |
| `--staged` | View `git diff --cached` (pre-commit index) |
| `--worktree` | View `git diff HEAD` (tracked, pre-commit, uncommitted changes) |

No args: Sweep current branch's `base..HEAD`.

## Procedure

```text
Co-evolve-check Progress:
- [ ] Step 1: Detect project language (TS/JS / Python / detection impossible)
- [ ] Step 1.5: Auto-skip pure revert PR judgment
- [ ] Step 2: Extract candidate symbols from diff (X1 + X2)
- [ ] Step 3: For each candidate, grep callers and judge co-evolution scope
- [ ] Step 4: Infer public marker (exclude FP)
- [ ] Step 5: Output structured finding
```

Implementation: `scripts/co_evolve_check.py` is SoT, performs above steps in one go. CLI:

```bash
python3 .claude/skills/co-evolve-check/scripts/co_evolve_check.py \
  [BASE_BRANCH] [--base BASE_BRANCH] [--staged | --worktree] [--json]
```

`--json` outputs JSON (machine-readable, for CI integration). Default is human-readable text output.

Exit code:
- 0: Normal exit (regardless of findings presence)
- 1: Argument error
- 2: Git command failed
- 3: Language detection impossible / pure revert PR (silent skip)
- 6: Other errors

### Meaning of each step

**Step 1: Detect project language** — Check marker file at repo root:

- `package.json` exists → TypeScript / JavaScript target
- Any of `pyproject.toml` / `setup.py` / `setup.cfg` / `requirements.txt` / `requirements*.txt` / `Pipfile` → Python target
- None exist → silent skip

If `CLAUDE_SKILL_CO_EVOLVE_CHECK_DISABLE=1` is set, silent skip.

If `CLAUDE_SKILL_CO_EVOLVE_CHECK_LANGUAGES=ts,py` is set, override language auto-detection (csv format).

**Step 1.5: revert PR auto-skip** — If all subjects from `git log --format=%s <base>..HEAD` start with `^Revert "`, silent skip.

**Step 2: Extract candidate symbols from diff** — Obtain diff with `git diff <base>...HEAD` (no args), `git diff --cached` (`--staged`), `git diff HEAD` (`--worktree`). Extract from `+` lines:

- **X1: Type/interface parallelism** — TS `interface (\w+)` / `type (\w+) = ...` additions + same-module version suffix/prefix pairs (`Foo` + `FooV2`, naming regex `(V\d+|Old|New|Legacy|Compat|Deprecated)`). Python `class (\w+)` same type.
- **X2: Function wrapper parallelism** — TS `function (\w+)` / `const (\w+) = (async)? \(` / `export function (\w+)` additions + existing same base name + suffix (`getUser` + `getUserNew` / `getUserV2`). Python `def (\w+)` + `_new` / `_v\d+` / `_old` / `_legacy` suffix.

Record candidate symbols as `(old_symbol, new_symbol, file:line)` tuples.

**Step 3: Caller analysis and co-evolution scope judgment** — For each candidate `(old, new)`, extract all references with `grep -rn "<old_symbol>"` and compare each reference's touched state against touched lines in `git diff`:

- All references touched in same PR + no public marker → `Co-evolution scope: confirmed` (`Confidence: high`)
- Any reference not touched → `Co-evolution scope: uncertain (1+ reference not touched)` (`Confidence: low`)
- 0 references → `Co-evolution scope: confirmed (no callers)` (`Confidence: medium`, old version is completely dead code)

**Step 4: Infer public marker (avoid FP)** — Record `Public marker: detected: <kind>` if old_symbol matches:

- TS: `package.json` not `"private": true` + module declaration with old_symbol in `"exports"` / `"main"` / `"types"`, OR `export` present + `tsconfig.json` has `declaration: true` / exposed via `.d.ts`
- Python: `pyproject.toml` `[project]` section present (assuming PyPI publish) / included in `__all__` / public symbol without `_` prefix
- Cross-language: old_symbol referenced from `openapi.yaml` / `swagger.yaml` / `*.proto` / `*.graphql` / `schema.json`, `@deprecated` / `Deprecation:` annotation

**Step 5: Output structured finding** — Each finding takes the format:

```text
Co-evolution opportunity: <X1: Type parallelism | X2: Function wrapper parallelism>
Evidence: <file:line> (old) + <file:line> (new)
Old symbol: <old_symbol>
New symbol: <new_symbol>
Callers of old symbol: <N references>
  - <file:line> [touched in this PR ✓ / not touched ✗]
  ...
Public marker: <none / detected: <kind>>
Co-evolution scope: <confirmed / uncertain (1+ reference not touched) / excluded (public marker)>
Subtractive question: Why retain <old_symbol>? When all callers are touched in same PR and no external consumers exist, old version can be deleted and unified with new version.
Suggested next action: <Concrete step — example: "Delete `interface UserOld` at src/types/user.ts:10 and replace all caller references with `User`">
Confidence: <high (co-evolution scope confirmed) / medium / low>
```

Final summary line:

```text
✅ co-evolve-check: <N findings> (<high> high / <medium> medium / <low> low confidence)
```

If 0 findings: `✅ co-evolve-check: no co-evolution opportunities found`.

## Output example

```text
Co-evolution opportunity: X1: Type parallelism
Evidence: src/types/user.ts:10 (old) + src/types/user.ts:20 (new)
Old symbol: UserOld
New symbol: User
Callers of old symbol: 3 references
  - src/api/legacy.ts:5 [touched in this PR ✓]
  - src/handlers/old.ts:12 [touched in this PR ✓]
  - src/types/index.ts:3 [touched in this PR ✓]
Public marker: none (no export to package boundary; not referenced in openapi.yaml / *.proto / public docs)
Co-evolution scope: confirmed
Subtractive question: Why retain UserOld? When all callers are touched in same PR and no external consumers exist, UserOld can be deleted and unified with User only.
Suggested next action: Delete `interface UserOld` at src/types/user.ts:10 and replace references in src/api/legacy.ts:5 / src/handlers/old.ts:12 / src/types/index.ts:3 with `User`.
Confidence: high

✅ co-evolve-check: 1 finding (1 high / 0 medium / 0 low confidence)
```

## Environment variables (optional toggle)

Not mandatory for project side. Operates with defaults.

| Environment variable | Description |
|---------|------|
| `CLAUDE_SKILL_CO_EVOLVE_CHECK_DISABLE` | Set to `1` to silent disable skill (when you don't want to run it for specific project) |
| `CLAUDE_SKILL_CO_EVOLVE_CHECK_LANGUAGES` | Override language auto-detection with csv (example: `ts,py`). Default is inferred from marker file |

## Integration into PR creation flow

Pre-PR trigger point like `/comment-sweep`. Launched in parallel immediately before `gh pr create` in the autonomy chain of "Commit / PR Operations" in [CLAUDE.md](../../../CLAUDE.md). When combined with `/extension-bloat-sweep` (orthogonal axis: detect unreasonable extension of existing implementation), sweep coverage is complete.

## Troubleshooting

| Issue | Resolution |
|------|------|
| Language detection misidentifies | Override with `CLAUDE_SKILL_CO_EVOLVE_CHECK_LANGUAGES=ts,py` |
| Finding output for public API | Public marker inference missing. Check `@deprecated` / `__all__` / `package.json exports` etc |
| Internal symbol excluded by `Public marker: detected` | False negative. Raise concrete case as issue and narrow script exclusion conditions |
| `grep -rn` reference extraction slow | Proportional to repo size. Option to silent disable skill itself with `CLAUDE_SKILL_CO_EVOLVE_CHECK_DISABLE=1` |
| Naming regex misses agent scenarios | Add suffix/prefix patterns other than `(V\d+|Old|New|Legacy|Compat|Deprecated)` via script modification |
| False finding in revert PR | Step 1.5 auto-skip may not be working. Verify subject with `git log --format=%s <base>..HEAD` |
| Doesn't work in this workshop repo | Correct behavior: repo root lacks `package.json` / `pyproject.toml` etc, so Step 1 silent skips (stage worktree demo app has marker file, so detection runs there) |
