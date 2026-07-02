---
name: extension-bloat-sweep
description: "Detects pre-PR diffs where agents extend existing implementations (file / function / signature) instead of splitting / extracting / replacing. Tier 1: (E1) large file appended (base ≥ 300 lines + added ≥ 50), (E2) signature complexity (param ≥ 4 or ≥ 3 optional), (E6) same function modified ≥ 2 commits in base..HEAD. Auto-detects TS/JS (`package.json`) / Python (`pyproject.toml`), silently skips otherwise. Outputs subtractive questions. Non-blocking. Complements `/co-evolve-check` on the orthogonal axis. Use before creating a PR (alongside `/comment-sweep` and `/co-evolve-check`), or when the user mentions refactoring would be cleaner / forcing into existing implementation / existing file bloat / function signature complexity / extension bloat."
---

# extension-bloat-sweep

Leaf skill ([rules/skills.md](../../../rules/skills.md)) that detects from pre-PR diff the pattern "should be cleaner if split/extracted/replaced, but instead forcing into existing file / function / signature and bloating it".

While `/co-evolve-check` detects "old version retention (version parallelism)", this skill detects **orthogonal-axis "unreasonable extension of existing implementation"**. Both skills are complementary without overlap.

Detects only without blocking PR (non-blocking report-only). LLM judge uses only subtractive questions; prohibits full draft of ideal form (prevent addition bias resurgence).

## When to use

Primary trigger points:
- Before executing `gh pr create`, launch in parallel with `/comment-sweep` + `/co-evolve-check`
- Before adding to an existing PR
- When sensing "refactoring would be cleaner" or "forcing into existing implementation"

Typical agent scenarios that are detection targets:
- Add 100 new lines to end of large file (existing 500 lines), bloating it
- Stack 3 optional params on existing function signature, raising param count to 5
- Keep touching same function 3 times across `base..HEAD`, bloating responsibility

Cases not detected (silent skip / low confidence):
- Project where language auto-detection fails (no marker file for TS/JS/Python)
- Pure revert PR (all commit subjects in base..HEAD start with `^Revert "`)
- When `CLAUDE_SKILL_EXTENSION_BLOAT_DISABLE=1` is set
- Small file additions (base < 300 lines) or minor arg additions (param count < 4)

## Arguments

| Argument | Description |
|------|------|
| `BASE_BRANCH` (positional, optional) | Explicitly specify base ref (example: `main`, `develop`). Default resolves `origin/HEAD` → `main` order |
| `--staged` | See `git diff --cached` (index before commit) |
| `--worktree` | See `git diff HEAD` (tracked uncommitted changes before commit) |

No args: sweep `base..HEAD` of current branch.

## Procedure

```text
Extension-bloat-sweep Progress:
- [ ] Step 1: Detect project language (TS/JS / Python / detection impossible)
- [ ] Step 1.5: Auto-skip pure revert PR judgment
- [ ] Step 2: Extract E1/E2/E6 candidates from diff
- [ ] Step 3: Generate subtractive question for each candidate
- [ ] Step 4: Output structured finding
```

Implementation uses `scripts/extension_bloat_sweep.py` as SoT, performing above steps in batch. CLI:

```bash
python3 .claude/skills/extension-bloat-sweep/scripts/extension_bloat_sweep.py \
  [BASE_BRANCH] [--base BASE_BRANCH] [--staged | --worktree] [--json]
```

`--json` outputs JSON. Default is human-readable text output.

Exit code:
- 0: Normal exit (regardless of findings presence)
- 1: Argument error
- 2: Git command failed
- 3: Language detection impossible / pure revert PR (silent skip)
- 6: Other errors

### Meaning of each step

**Step 1: Detect project language** — Need one of `package.json` (TS/JS) / `pyproject.toml` / `setup.py` / `setup.cfg` / `requirements.txt` / `Pipfile` (Python) at repo root. If none, silent skip. Also silent skip if `CLAUDE_SKILL_EXTENSION_BLOAT_DISABLE=1`. Override language auto-detection with csv via `CLAUDE_SKILL_EXTENSION_BLOAT_LANGUAGES=ts,py`.

**Step 1.5: revert PR auto-skip** — Silent skip if all subjects from `git log --format=%s <base>..HEAD` start with `^Revert "`.

**Step 2: Extract E1/E2/E6 candidates**

- **E1: Large additions to existing large file** — Per changed file: base line count ≥ `CLAUDE_SKILL_EXTENSION_BLOAT_FILE_LINES_THRESHOLD` (default 300) AND `+` line count ≥ `CLAUDE_SKILL_EXTENSION_BLOAT_ADDED_LINES_THRESHOLD` (default 50) → candidate
- **E2: Function signature complexity** — From each changed file's diff, extract function definition lines (TS: `function` / `const ... = (`, Python: `def`): existing same-named function in base + new signature param count ≥ `CLAUDE_SKILL_EXTENSION_BLOAT_PARAM_THRESHOLD` (default 4) OR consecutive optional ≥ 3 → candidate
- **E6: Same file modified multiple times** — Per commit in `git log --format='%H %s' <base>..HEAD`, check file touch with `git show <sha> --name-only`: same file touched in ≥ `CLAUDE_SKILL_EXTENSION_BLOAT_MODIFY_COUNT_THRESHOLD` (default 2) commits → candidate (file-unit low confidence detection; refinement to function definition range not yet implemented)

**Step 3: Generate subtractive question**

| ID | Subtractive question |
|---|---|
| E1 | Can this addition be extracted to separate file? Base file already has `<N>` lines; PR adds `<M>` lines. Consider separating parts with different responsibility to new file |
| E2 | Can function `<func>` arguments be objectified (`{ option1, option2, ... }`) or split function by responsibility? Currently `<N>` params (consecutive optional `<M>`) |
| E6 | Function `<func>` modified `<N>` times. Sign of responsibility bloat. Consider splitting |

**Step 4: Output structured finding** — Per finding:

```text
Extension bloat opportunity: <E1: Existing large file end append | E2: Function signature complexity | E6: Same function multiple modify>
Evidence: <file:line range>
Base state: <base file line count / function param count / commit touch count>
Diff impact: <added line count / new param count / modify count>
Subtractive question: <split/extract/replace suggestion>
Suggested next action: <concrete verification step — not LLM full draft>
Confidence: high (threshold exceeded + clear bloat signal) / medium / low
```

Final summary line:

```text
✅ extension-bloat-sweep: <N findings> (<high> high / <medium> medium / <low> low confidence)
```

If 0 findings: `✅ extension-bloat-sweep: no extension-bloat opportunities found`.

## Output example

```text
Extension bloat opportunity: E1: Existing large file end append
Evidence: src/handlers/user.ts (+131 / -0 (net +131))
Base state: base file is 520 lines
Diff impact: net growth +131 lines (+25% of base)
Subtractive question: Can this addition be extracted to separate file? Base file already has 520 lines; PR adds net +131 lines (131 added, 0 deleted). Consider separating parts with different responsibility to new file.
Suggested next action: If added lines have independent responsibility (example: new feature/area), consider extracting to new file and connecting via re-export/import to existing file.
Confidence: high

✅ extension-bloat-sweep: 1 finding (1 high / 0 medium / 0 low confidence)
```

## Environment variables (optional toggle)

Not mandatory for project side. Operates with defaults.

| Environment variable | Description | Default |
|---------|------|---------|
| `CLAUDE_SKILL_EXTENSION_BLOAT_DISABLE` | Set to `1` to silent disable skill | (not set) |
| `CLAUDE_SKILL_EXTENSION_BLOAT_LANGUAGES` | Override language auto-detection with csv (example: `ts,py`) | Auto-detect |
| `CLAUDE_SKILL_EXTENSION_BLOAT_FILE_LINES_THRESHOLD` | E1 base file line count threshold | `300` |
| `CLAUDE_SKILL_EXTENSION_BLOAT_ADDED_LINES_THRESHOLD` | E1 added line count threshold | `50` |
| `CLAUDE_SKILL_EXTENSION_BLOAT_PARAM_THRESHOLD` | E2 param count threshold | `4` |
| `CLAUDE_SKILL_EXTENSION_BLOAT_MODIFY_COUNT_THRESHOLD` | E6 commit touch count threshold | `2` |

## Relationship with co-evolve-check

| Axis | co-evolve-check | extension-bloat-sweep |
|---|---|---|
| Detection target | Old version retention (version parallelism) | Unreasonable extension of existing implementation |
| Nudge | "Can delete old version and unify?" | "Can split/extract/replace to clean?" |
| Detection signal | Suffix parallelism / function wrapper / caller co-evolution | File bloat / param count / function modify iteration |

Both are orthogonal-axis complementary. Pre-PR sweep assumes launching `/comment-sweep` + `/co-evolve-check` + this skill in parallel.

## Troubleshooting

| Issue | Resolution |
|------|------|
| Language detection misidentifies | Override with `CLAUDE_SKILL_EXTENSION_BLOAT_LANGUAGES=ts,py` |
| Threshold doesn't fit project | Adjust per-project with `CLAUDE_SKILL_EXTENSION_BLOAT_FILE_LINES_THRESHOLD` etc |
| Lots of findings output | Raise threshold or silent disable with `CLAUDE_SKILL_EXTENSION_BLOAT_DISABLE=1` |
| E6 AST analysis not effective | Fallback reports "file-unit 2+ commit touch" as low confidence |
| False finding in revert PR | Step 1.5 auto-skip may not be working. Verify subject with `git log --format=%s <base>..HEAD` |
| New files become targets | E1 targets only "large file existing in base". Splitting to new file is recommended direction, so silent skip is correct behavior |
| Doesn't work in this workshop repo | Correct behavior: repo root lacks `package.json` / `pyproject.toml` etc, so Step 1 silent skips (stage worktree demo app has marker file, so detection runs there) |
