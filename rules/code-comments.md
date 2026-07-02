# Code Comments

## Principles

Follow the existing comment conventions of the file you're editing. If docstrings exist, write similarly; if not, don't add them. For new files, follow existing files in the same directory; if you can't decide, don't write comments.

Comments should be concise and address only the "why". Leave WHAT / HOW explanations to identifier names and type signatures. **If WHY is self-evident from code, don't write it** ("write WHY" is not the correct rule; "write only WHY that isn't self-evident" is). "Why" that's deducible from identifier names, types, and surrounding code—when commented—adds no information and becomes debt when code changes.

## Specific Patterns to Avoid

### 1. Just Rephrasing Identifier Names in Natural Language

Don't write "definition" comments that convert what the identifier shows into Japanese/English. Readers get the same info by reading the code.

```go
// Bad: just rephrasing identifier name in Japanese
// UserSignupToken is a persistence model of token for signup confirmation
type UserSignupToken struct { ... }

// Good: remove comment
type UserSignupToken struct { ... }
```

However, WHY not deducible from the identifier name (e.g., design reason for delaying users INSERT until verification is complete) deserves to remain. If it matches "Examples of WHY Worth Writing" below, keep it (don't delete) but organize as WHY only.

### 2. Comparison / Contrast with Other Code

Don't write contrastive comments like "unlike existing X" or "different from other Y". Readers should examine X / Y directly and understand the structure themselves; contrasts are just WHAT / HOW rephrasing. Moreover, if referenced code changes later, the comment alone goes stale and becomes false.

```go
// Bad: explain via contrast with existing implementation
// IssueSignupToken differs from existing Email/Password update token (JWT):
// uses DB record as SoT, so issues opaque token without JWT signing/verification.
func IssueSignupToken(...) { ... }

// Good: drop contrast, state independent WHY concisely
// DB record as SoT; issue opaque token to guarantee revoke via immediate hard-delete after consumption
func IssueSignupToken(...) { ... }
```

### 3. Immediately Following Code Self-Evidently Explains the Operation

```go
// Bad
// Register existing user for duplicate check.
existingUser := testutil.AddTestUser(...)

// Bad
// Record created in user_signup_tokens.
assertUserSignupTokenFound(...)

// Good: remove comment
existingUser := testutil.AddTestUser(...)
assertUserSignupTokenFound(...)
```

### 4. Change History Comments

Don't write change-history like `// removed`, `// deprecated`, `// added for issue X`, `// fixes https://example.com/org/repo/issues/123` etc. Git log / PR description is SoT.

## Examples of WHY Worth Writing

Write only info not deducible from identifier names or type signatures.

- Out-of-spec constraints: `// no gorm.DeletedAt: having it implicitly switches to soft delete and rows with hashed_password remain`
- Reason for seemingly redundant/inefficient operation: `// constant-time compare prevents timing attack`
- Valid reason for behavior differing elsewhere: `// only this path hashes once before encryption: fit legacy V1 key length limit (32 bytes)` — write not just "what to do" but "why." If you can't write the reason, it's HOW not WHY.
- Known bug avoidance: `// https://example.com/issues/BUG-123: foo can return nil`

## Language-Specific Notes

### Go Exported Identifiers

Go golint convention says "doc comments on exported identifiers," but **if same directory / same kind of file (same Model / Repository / Interactor etc.) in the project lacks doc comments, don't write them either**. Judge convention compliance per project, not per ecosystem.

### Python Docstring

If existing functions in the file lack docstring, don't add one. If some functions have docstring, add docstring to newly added functions to maintain file-level consistency.

## Three or More Line Comment Blocks: Caution

WHY rarely requires 3 lines. If "I want to write 3 lines" crosses your mind, usually you're writing WHAT / structural explanation / contrast. Second-guess it and check if reduction is possible.

Before deciding to delete, when wanting to write 3+ lines, always do this 2-stage check:

1. **Can naming absorb it?**: Can you embed what the comment explains into identifier names (function names, type names, parameter names, enum tags etc.) so it disappears? Example: rather than comment explaining `ToEntities` is strict, name them `ToEntitiesStrict` / `ToEntitiesLenient` so naming states intent and SoT is one.
2. **Can compress to WHY only?**: After deleting all WHAT / HOW, if remaining WHY fits one line, that's the answer. If 3 lines remain, not yet fully trimmed.

## Judgment Timing

Judge at 3 timings: "before writing," "right after writing," "during review." Rules exist but go unobeyed because judgment timing is implicit.

### Before Writing

When about to write a comment, check it doesn't match any "Specific Patterns to Avoid" above. If it does, don't write.

### Right After Writing (pre-commit sweep)

Before commit / PR creation, use `/comment-sweep` skill to sweep newly added comments. Skill extracts comment lines you added and applies this document's judgment to each (see [.claude/skills/comment-sweep/SKILL.md](../.claude/skills/comment-sweep/SKILL.md) for details).

### During Review (reviewer mode)

When asked to review PR / code snippet, flag excessive comments as **top-priority nit explicitly**. Concretely:

- Rephrasing identifier names, WHAT explanations, contrasts, change-history comments: mark as "recommend deletion" with individual notes
- 3+ line comment blocks: suggest alternatives including "can naming absorb this?"
- But limit inline notes to **max 5**. Beyond that, aggregate in summary as "N more instances of this type of excessive comment" without bloating inline (reviewer noise limit per Cloudflare's AI review practice: https://blog.cloudflare.com/ai-code-review/)
- However, don't flag existing comments matching "Examples of WHY Worth Writing" above. **In reviewer mode don't propose "should add comments"** — only work in reduction direction (the "Python docstring" section's consistency-maintenance rule applies to writers separately, outside reviewer mode scope)

If user explicitly instructs "no comments needed" or "make verbose" etc., follow that.
