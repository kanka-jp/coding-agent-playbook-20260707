---
name: comment-sweep
argument-hint: "[--staged | --worktree | BASE_BRANCH]"
description: "Reviews newly added code comments in a git diff against rules/code-comments.md. Detects identifier paraphrase, WHAT/HOW explanation of next code, comparison comments ('differs from existing X'), change history references (Copilot findings / issue ID prefix / 'added for' / 'fixes URL'), 3+ line blocks compressible to a 1-line WHY, and duplicate sentences within a block. Default scans the diff between the PR base and HEAD for PR readiness. '--staged' scans the index, '--worktree' scans tracked uncommitted changes, BASE_BRANCH (any positional arg) overrides the base ref. Auto-skips when base..HEAD contains only revert commits (subjects all start with 'Revert \"'). Use BEFORE 'gh pr create', or when the user mentions comment check / comment sweep / comment review / unnecessary comments / comment inappropriate."
---

# comment-sweep

Leaf skill ([rules/skills.md](../../../rules/skills.md)) that judges **newly added comment lines** in PR / staged / worktree diff against the norms of [rules/code-comments.md](../../../rules/code-comments.md), reports violations, and guides to fixes. When run as a pre-step to `/pr-codex-ci`, codex review doesn't spend time on low-level findings (unnecessary comments).

## When to use

- **Before PR creation (recommended)**: **Before** `gh pr create`. Right after implementation/testing etc., run sweep before push
- **Before adding to an existing PR**: Also applies to review response and bug fix diffs (after commit, before push in default mode)
- **Right after user points out "comment inappropriate", "unnecessary comment" etc**: Re-sweep against all changed files
- **Even for temporary changes not creating PR**: Can run in `--staged` or `--worktree` mode before commit

## Argument modes

| Argument | Target diff | Purpose |
|------|----------|------|
| (none) | `git diff origin/<HEAD-branch>...HEAD` (HEAD-branch determined from `origin/HEAD` symbolic-ref, see below) | Final sweep before PR creation |
| `BASE_BRANCH` (any 1 arg not starting with `--`) | `git diff origin/<BASE_BRANCH>...HEAD` | When explicitly specifying base (use remote tracking ref) |
| `--staged` | `git diff --cached` (index) | Sweep before commit |
| `--worktree` | `git diff HEAD` (tracked and uncommitted. **untracked not included**) | When wanting all uncommitted tracked changes |

Cannot specify multiple. Any single arg that's not a flag or number is treated as `BASE_BRANCH`. If you want untracked new files included with `--worktree`, first run `git add -N <path>` for intent-to-add before calling.

## Procedure

```text
Sweep Progress:
- [ ] Step 1: Mode judgment and diff acquisition
- [ ] Step 1.5: Lightweight-PR diff detection (default / BASE_BRANCH mode only)
- [ ] Step 2: Extract and block newly added comment lines
- [ ] Step 3: Judge each block against norms
- [ ] Step 4: Present violation table to user
- [ ] Step 5: Fix via Edit after user approval
- [ ] Step 6: Re-sweep to confirm zero remaining violations
```

### Step 1: Mode judgment and diff acquisition

Interpret argument to determine mode. For default mode (no args), use **`origin/HEAD` (default branch)** as base. Using feature branch upstream as base would make `git diff origin/feat/x...HEAD` empty and sweep would false-negatively pass; always determine from `origin/HEAD` derived.

```bash
git symbolic-ref refs/remotes/origin/HEAD --short
```

If this returns `origin/main` etc, use that branch as base and get `...` (triple-dot) diff:

```bash
git diff origin/main...HEAD
```

If `origin/HEAD` is not set and symbolic-ref fails, request `BASE_BRANCH` argument and guide user (`git remote set-head origin -a` can reconfigure). For `--staged` / `--worktree` / `BASE_BRANCH` cases, skip this calculation and directly run corresponding command. For `BASE_BRANCH` argument mode, run `git diff origin/<BASE_BRANCH>...HEAD` (use remote tracking ref, not local branch name).

### Step 1.5: Lightweight-PR diff detection (auto-skip)

Run only in `default` / `BASE_BRANCH` modes (`--staged` / `--worktree` excluded since they can be cases with no commit to HEAD; proceed normally to Step 2).

Auto-skip diffs where no new comments structurally exist. Delegate judgment to shared helper:

```bash
python3 -I .claude/skills/_shared/pr-skip-policy.py --base <base-ref> --head HEAD --json
```

`<base-ref>` is **the base ref used in Step 1 with `git diff <base-ref>...HEAD`** (default is `origin/main` etc, `BASE_BRANCH` mode is `origin/<BASE_BRANCH>`). **Don't double `origin/`**. head is `HEAD` since this skill includes unpushed local commits.

Branch on `profile` in output JSON:

- `pure-revert` → Output and exit (revert diff `+` lines are only restoring comments, not re-sweep targets):

  ```text
  ✅ Revert-only diff (skipped)
  ```

- `tiny-json-hotfix` → Output and exit (single JSON scalar value replacement under `.claude/` etc with zero newly added comment lines):

  ```text
  ✅ Lightweight PR (tiny-json-hotfix, skipped)
  ```

- `none` → Proceed to Step 2

If helper returns exit code non-0 (cannot judge due to git failure etc), fall back to normal flow and proceed to Step 2.

### Step 2: Extract and block newly added comment lines

**Exclude generated files (before extraction, if bun available)**: Auto-generated files have comments that are also generated artifacts, not review targets, so exclude them file-by-file from sweep. If bun is in PATH, execute the detection CLI corresponding to the invocation mode and exclude `generated[].path` from output JSON in subsequent extraction targets:

| Mode | Command |
|--------|---------|
| default / `BASE_BRANCH` | `bun --config=/dev/null .claude/skills/_shared/detect-generated-local.ts --range <base-ref>...HEAD` |
| `--staged` | `bun --config=/dev/null .claude/skills/_shared/detect-generated-local.ts --staged` |
| `--worktree` | `bun --config=/dev/null .claude/skills/_shared/detect-generated-local.ts --worktree` |

If bun is not available, skip this step and include all changed files in extraction targets (even with generated files, false-positive violations are detected; user approval stage can exclude them). Note excluded files in Step 4 with count and list (don't silently remove).

From diff output, extract lines starting with `^\+(?!\+\+)` that match comment prefix **according to the changed file's extension**. Valid prefixes per extension are below:

| Extension | Valid comment prefix |
|--------|---------------------|
| `.go` / `.rs` / `.ts` / `.tsx` / `.js` / `.jsx` / `.mjs` / `.cjs` / `.c` / `.h` / `.cpp` / `.hpp` / `.java` / `.swift` / `.kt` / `.scala` / `.dart` | `^\+\s*//` / `^\+\s*/\*` ~ `\*/` / `^\+\s*\*` (block continuation) |
| `.py` / `.rb` / `.sh` / `.bash` / `.zsh` / `.yml` / `.yaml` / `.toml` / `.nix` / `Makefile` / `.mk` / `Dockerfile` | `^\+\s*#` (line) |
| `.md` / `.markdown` / `.html` / `.htm` / `.xml` / `.svg` / `.vue` | `^\+\s*<!--` ~ `-->` (block) only |
| `.sql` | `^\+\s*--` (line) / `^\+\s*/\*` ~ `\*/` (block) |
| `.ex` / `.exs` | `^\+\s*#` (line) |
| `.erl` | `^\+\s*%` (line) |

**In Markdown files (`.md` / `.markdown`), don't treat `^\+\s*#` as "comment"** — `#` is heading syntax, risking false-positive violation detection of `# Usage` / `## Test plan` etc. Markdown only targets `<!-- -->`.

Exclude from judgment:

- Shebang (`#!`)
- Linter / formatter / type-check directive (`// eslint-disable-line`, `# noqa: ...`, `// biome-ignore *`, `// @ts-ignore`, `// @ts-expect-error`, `# type: ignore`, `// nolint`, `# pylint:`)
- License header / copyright block
- Generated file marker (`@generated`)
- When editing `rules/code-comments.md` itself, example comments in that norm description (`// bad example` etc) are excluded

**Blocking rule**: Consecutive added comment lines in same file (without blank lines in between) form 1 block. If non-`+` (context line or `-` line) is interspersed, separate block.

### Step 3: Judge each block against norms

Judge by the following categories in [rules/code-comments.md](../../../rules/code-comments.md). **Pattern match against the body with comment prefix (`//` / `#` / `--` / `<!--` etc) stripped** (language-agnostic). Adopt **the single heaviest violation that applies**:

| Category | Detection criterion (against body with prefix removed) |
|----------|---------|
| `IDENTIFIER_PARAPHRASE` | Body's main noun semantically duplicates the immediately following (or immediately preceding in doc position) identifier (example: `UserSignupToken is a persistence model of signup confirmation token`) |
| `NEXT_CODE_WHAT` | Body explains the immediately following 1-3 lines of code in WHAT/HOW (example: `Register existing user for duplicate check` immediately followed by `existingUser := testutil.AddTestUser(...)`) |
| `COMPARISON` | Comparative expressions like "differs from existing X", "different from other Y" etc |
| `CHANGE_HISTORY` | Contains any of the keywords in "CHANGE_HISTORY keywords" list below |
| `BLOCK_TOO_LONG` | Same block **3+ lines**, passing the 2-step judgment in `code-comments.md` (can naming absorb it? → can WHY compress to 1 line?) passes **compressible** (no information loss from deletion). Don't immediately violate 3+ lines |
| `DUPLICATE_SENTENCE` | Same-essence sentence appears multiple times within same block (essence-based judgment, not cosine similarity) |
| `NO_VIOLATION` | Matches "examples of WHY worth writing" in `code-comments.md` (spec-external constraint / tradeoff reason / known bug avoidance / justified behavior difference from elsewhere) |

**CHANGE_HISTORY keywords list** (separate from markdown table because regex `|` collides with table separator):

- `Copilot finding`
- `[A-Z]{2,}-\d+:` (uppercase issue prefix + serial, example: `DEV-1234:`)
- `added for`
- `\bremoved\b` (word boundary)
- `\bdeprecated\b` (word boundary)
- `fixes?\s+#?\d+` (example: `fixes 123`, `fix #456`)
- `fixes?\s+https?://\S+` (example: `fixes https://example.com/issues/789`)
- `Fix history`
- `https?://\S+/(pull|issues)/\d+` (PR / issue URL)

When surrounding code is needed for judgment (`IDENTIFIER_PARAPHRASE`, `NEXT_CODE_WHAT`), use Read tool to check file's relevant lines.

### Step 4: Present violation table to user

Result in markdown table format. If zero violations, report only "✅ Comment sweep clean" and exit. If generated files were excluded in Step 2, after the table (or clean report), note in 1 line: "Excluded generated files: N files (`path1`, `path2`, ...)".

```markdown
## Comment sweep results

| # | file:line | Category | Excerpt | Suggestion |
|---|-----------|---------|------|------|
| 1 | `app/foo.ts:42` | NEXT_CODE_WHAT | `// Register existing user for duplicate check` | Delete (following code is obvious) |
| 2 | `pkg/bar.go:88-92` | BLOCK_TOO_LONG | `// Per spec unreachable here: ...` (5 lines) | Compress WHY to 1 line or delete |
| 3 | `app/baz.ts:15` | CHANGE_HISTORY | `// Copilot finding: ...` | Delete (git log is SoT) |

Total N / M candidates can remain as WHY only

Fix now? (y for all / specify numbers for partial / n to stop)
```

### Step 5: Fix via Edit after user approval

Approval policy:

- `y` / "please" / "all" → Fix all via Edit
- Number specify (example: `1,3` / `1-2`) → Fix only those
- `n` / "stop" → Stop without fixing (violations already reported)

Fix policy (per category):

- `IDENTIFIER_PARAPHRASE` / `NEXT_CODE_WHAT` / `COMPARISON` / `CHANGE_HISTORY`: **Delete** comment line
- `BLOCK_TOO_LONG`: Compress WHY to 1 line only. If can't compress, suggest delete (`code-comments.md` 2-step judgment: can naming absorb? → can WHY compress to 1 line?)
- `DUPLICATE_SENTENCE`: Delete duplicate part and consolidate to 1 sentence

Pass to Edit tool: old_string with context including violating comment block, new_string with fixed version. Multiple violations per file: Edit consecutively.

**Note for `--staged` mode**: Edit only rewrites working tree. To reflect fix in next commit, user must **always restage** with `git add <fixed-file>` after Edit completes (without restaging, Step 6's `git diff --cached` re-sweep stays with pre-fix state and re-detects violations). Skill doesn't auto-run `git add` — user specifying target paths when staging prevents unintended file inclusion.

### Step 6: Re-sweep to confirm zero remaining violations

After fixes, re-sweep once using **mode-appropriate diff**:

| Mode | Re-sweep comparison target | Prerequisite |
|--------|---------------------|------|
| default / `BASE_BRANCH` | `git diff origin/<base>...HEAD` | Commit fixes **before** re-sweep (working tree fix not reflected if HEAD doesn't move) |
| `--staged` | `git diff --cached` | Step 5 **`git add` done** prerequisite |
| `--worktree` | `git diff HEAD` | Working tree fix done by Edit, reflected as-is |

Repeat Steps 3-5 until zero remaining violations (max 3 times; if still remain, report to user that manual judgment needed). For default / `BASE_BRANCH` mode, interleaving commits makes PR reflect progressively (push separate).

## Concrete violation pattern examples

### IDENTIFIER_PARAPHRASE (recommend delete)

```go
// Bad example: just rephrasing identifier name
// UserSignupToken is a persistence model of signup confirmation token
type UserSignupToken struct { ... }

// Good example: delete comment
type UserSignupToken struct { ... }
```

### NEXT_CODE_WHAT (recommend delete)

```go
// Bad example
// Register existing user for duplicate check.
existingUser := testutil.AddTestUser(...)

// Good example
existingUser := testutil.AddTestUser(...)
```

### CHANGE_HISTORY (recommend delete)

```typescript
// Bad example
// Copilot finding: signup verify design requires user/token creation and session issue in same tx,
// so users/signup_token row rolls back on session issue failure
function verifySignup() { ... }

// Good example: keep WHY only or delete
// Issue in same tx: prevent incomplete row remnants
function verifySignup() { ... }
```

### BLOCK_TOO_LONG (violation only if compressible)

```go
// Bad example (5 lines compressible to 1-line WHY)
// Per spec unreachable here: logout endpoint under AuthMiddleware
// called after session_id Cookie validation (syntax + DB exists + expiry),
// so session ID string should be valid. Defensively return nil,
// but pay attention that if refactor bypasses AuthMiddleware, sessions won't be cleaned
// and the behavior changes.
return nil

// Good example 1: delete (unreachable should return error, express in code not comment)
return errors.New("unreachable: logout outside AuthMiddleware")

// Good example 2: 1-line WHY (when delete impossible)
// Prerequisite of only being called under AuthMiddleware, so nil return as invariant
return nil
```

Even 3+ lines remain as `NO_VIOLATION` if matching "WHY worth writing examples" in `code-comments.md` (example: compressing loses tradeoff explanation for spec-external constraint).

### DUPLICATE_SENTENCE (consolidate to 1 sentence)

```go
// Bad example (rephrases same essence 3 times)
// password change changes credentials, invalidate all existing sessions
// prevent stolen session continued use
// reset complete requires re-login from all devices

// Good example
// password change invalidates all existing sessions (prevent stolen session continued use)
```

### NO_VIOLATION (keep)

```go
// Spec-external constraint: no gorm.DeletedAt (with it, implicitly switches to soft delete, hashed_password row persists)
type User struct { ... }

// timing attack prevention: constant-time compare
if subtle.ConstantTimeCompare(a, b) == 1 { ... }
```

## Integration into PR creation flow

In the autonomy chain of "Commit / PR Operations" in [CLAUDE.md](../../../CLAUDE.md), call in default mode **immediately before** `gh pr create`. Running sweep before starting `/pr-codex-ci` lets codex review focus on substantive findings instead of spending time on comment-related nits.

## Troubleshooting

| Issue | Resolution |
|------|------|
| `git symbolic-ref refs/remotes/origin/HEAD --short` fails | Reconfigure with `git remote set-head origin -a`. If still fails, request explicit argument (`BASE_BRANCH`) |
| Diff empty | Base specification error (check if passing feature branch upstream) or HEAD caught up with base. Verify range with `git log --oneline <base>...HEAD` |
| Violation table huge (>20) | Possibility of large diff including legacy files. Reconsider base or split per-file execution |
| Slow due to heavy surrounding code reads | For multiple violations in same file, batch Read. LLM judgment batch per-file |
| Lint / formatter runs post-fix creating re-diff | Don't false-positive during re-sweep, ignore formatter auto-fix (exclude whitespace-only diffs) |
| Editing `rules/code-comments.md` itself | Don't treat example comments in norm description (`// bad example` etc) as violations (Step 2 exclusion rule) |
| New files not picked up in `--worktree` mode | `git diff HEAD` tracked only. First `git add -N <path>` for intent-to-add, then re-run |
| bun not in PATH | Skip generated file detection step, include all files in sweep targets (core skill function unaffected) |

## Rationale

Judgment criteria use [rules/code-comments.md](../../../rules/code-comments.md) as SoT; this skill enforces **judgment timing** (before PR creation / before commit). LLM comment generation loses CLAUDE.md norm reproducibility through context window compression, so skill-ified as **deterministic trigger point**.
