# Parallel Development and Advanced Usage

Usage patterns diverging from basic pattern in [README](../README.md) §2 (`bash scripts/dev.sh` enters single bind-mount dev box):

- Enter shell inside box (bypassing claude)
- Launch multiple dev boxes in parallel (run production work in parallel / pair reviewer coordination)
- Sandbox box (`--clone .` isolation) for ad-hoc exploration (`/pr-codex-ci` unavailable)
- Distinguish dev servers by name (via Traefik)

## Enter shell inside box (bypassing claude)

In separate terminal, confirm name with `bash scripts/dev.sh ls`, then enter shell in target box:

```bash
bash scripts/dev.sh ls                     # List dev boxes (#, NAME, CDX status)
bash scripts/dev.sh shell <NAME>           # Enter interactive bash in that box (NAME required)
# Windows: powershell -ExecutionPolicy Bypass -File scripts/dev.ps1 shell <NAME>
```

**Can run in parallel with** claude session (exiting shell with `exit` / `Ctrl+D` leaves claude / box alive). Thin wrapper over `sbx exec -it <box> bash`. Use when directly running `setup-worktrees.sh` for stage worktree re-expansion or debugging, or when entering shell in sandbox box below (`bash scripts/dev.sh shell <generated-name>`).

## Launch multiple dev boxes in parallel (production work / pair reviewer coordination)

Running **no-args** `scripts/dev.sh` multiple times creates each with a separate auto-named (`<basename>-<hex6>`, e.g. `coding-agent-playbook-7a3f29`) dev box, each with independent `cdx-<NAME>` reviewer pair (ports also independent, dynamic ephemeral). Can run `/pr-codex-ci` in parallel.

Dev box `<NAME>` can't use reserved prefixes `cdx-*` (reviewer pair) and `sbx-*` (sandbox auto-name) (`dev.sh` rejects on validation). Namespace separation from sandbox use below.

```bash
bash scripts/dev.sh                        # Multiple runs in separate terminals create separate dev boxes + cdx pairs
bash scripts/dev.sh ls                     # List running dev boxes
bash scripts/dev.sh attach <N>             # Re-attach to Nth item in ls
# Windows: powershell -ExecutionPolicy Bypass -File scripts/dev.ps1
```

For explicit names (`task-a` / `task-b` etc to encode intent in name), pass arguments:

```bash
bash scripts/dev.sh task-a                 # Idempotent attach-or-create by explicit name
bash scripts/dev.sh task-b
```

Stop dev box with `bash scripts/dev.sh kill <NAME|N>` (also destroys cdx-`<NAME>` reviewer pair). If auto-teardown didn't run leaving orphan reviewer pairs / stale leases / stale locks, **`bash scripts/dev.sh prune`** batch-cleanups (no args = dry-run, `--yes` = execute) instead of individual `sbx rm -f cdx-<NAME>` + `rm .claude/tmp/cdx-*`. **`--all` flag** adds "dev box itself with CDX=none" (appears in `ls` but lacks cdx pair, accumulated boxes) as candidate (Docker `image prune --all` analogy). 3-tier safety guards: (1) boxes with cdx pairs handled via separate path, (2) active dev locks excluded as in-flight launches, (3) boxes with `status=running` in `sbx ls --json` excluded (protects lock-less attach via `dev.sh shell` / direct `sbx exec`, shown separately in `skipped (running, --all mode)` section). Further, re-snapshots running status right before delete to prevent scan→delete race. **Fail-closed**: bash version requires `jq` + refuses `--all` and exits on `sbx ls --json` fetch/parse failure (safer than degrading with no filtering and mis-deleting), PowerShell version uses built-in `ConvertFrom-Json` with same fail-closed principle. For just-names list, **`ls -q`** (Docker `docker ps -aq` compatible, open for advanced use with `xargs` etc).

## Handle large issue backlogs in parallel (operations & maintenance phase)

After initial implementation (MVP), enter phase to **convert improvements to issues → fix in parallel**. Issue **source** and **handling (dispatch)** each have 2 modes: "manual / ultracode".

### Issue sources (coding agent runs `gh issue create` for all)
Filing itself: better to **ask claude than hand-type `gh`** (filing from box requires PAT with `Issues: Read and write`. [docs/setup.md](setup.md). Without it: `Resource not accessible by personal access token (createIssue)`). Difference is in **what to file**:
- **Human-led (targeted, few)**: Human says "fix this, file an issue" → agent files it.
- **Ultracode-found (comprehensive, many)**: Fan-out finder agents by dimension on target (e.g., stage MVP) → adversarial verify → deduplicate → agent files **verified backlog** (opt-in to Workflow with `ultracode` keyword).

### ① Manual dispatch (human distributes)
Repeat: launch box per issue, paste issue number, let it auto-run:

```bash
bash scripts/dev.sh                     # Launch auto-named dev box (repeat per issue = parallelism = box count)
# Tell box's claude (specify target checkpoint, have it cut dedicated worktree):
> Fix issue #93 in <target stage> (e.g. stage/04-mvp), cut dedicated worktree and push PR
```

Claude auto-runs worktree→implement→PR→`/pr-codex-ci`→`/pr-review-respond` ([CLAUDE.md](../CLAUDE.md) "Development flow" chain). HOTL monitors via statusLine session id → transcript from host. **Simple & reliable, but repetitive "launch & paste" tires with many issues** (→②).

**① is repo standard** (reproducible with just clone). ② is advanced form when using Claude Code harness below.

> ⚠️ **Common caution for ①② (when parallelizing against stages)**
> - **Worktree isolation**: dev boxes share host checkout (`.git` / `.worktrees/`) by bind-mount. Don't edit shared stage worktree (`.worktrees/<NN>/`) directly; **cut separate branch + separate worktree per issue** (unique names across boxes to avoid collision).
> - **`Closes` doesn't work**: since `stage/*` isn't default branch, fix PRs for them don't get **`Closes #N` auto-close** ([GitHub spec](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/linking-a-pull-request-to-an-issue)). Close issues manually / reference in body.
> - Target checkpoint name matches real branch (`docs/instructor.md` checkpoint table still has old names, unaligned → plan to update separately).

### ② Parallel via ultracode (advanced / Claude Code harness only)

> ⚠️ **This is not bundled-in-repo functionality**. `ultracode` / `Workflow` (multi-agent orchestration) / `isolation: 'worktree'` are **Claude Code harness features**, not repo scripts/skills (don't exist after just cloning). Repo's standard parallel is ①. ② only works when running inside Claude Code.

Pass issue list, **fan-out agent per issue** to fix & PR in parallel (collapse ①'s "launch & paste" loop into 1 command):

```text
> Parallel-fix #92 #93 #94 #95 #96 #97 in <target stage> (e.g., stage/04-mvp) with ultracode
```

Each agent fixes independently with `isolation: 'worktree'` (harness automatically satisfies worktree isolation above). **Convergence** (combining each worktree's results into one) **is handled by harness / human orchestration** (repo has no auto-integration mechanism). Depending on scale and conflicts:
- Issue-per-PR → sequential review/merge (like production GitHub flow. As noted, `Closes` doesn't work for stage PRs)
- Integrate into 1 checkpoint (e.g., stage/05-fixed) → 1 PR (cleaner demo)

> ⚠️ **Issues touching same file conflict in parallel**. Either select file-independent issues to increase parallelism / design in sequential merge & conflict resolution. (Bundling issues at filing stage with "non-overlapping file granularity" makes parallelism easier).

## Sandbox box (`--clone .` isolation / ad-hoc exploration / `/pr-codex-ci` unavailable)

For throwaway boxes completely isolated from host (exploring options A/B, verifying risky commands etc), use `dev.sh sandbox`. Launches as private copy not mounting host checkout, so file-contention races with host are structurally nonexistent (parallel-safe).

```bash
bash scripts/dev.sh sandbox                # No args: fresh --clone each time as sbx-<basename>-<hex6>
bash scripts/dev.sh sandbox <NAME>         # Explicit name: create/attach sandbox
# Windows: powershell -ExecutionPolicy Bypass -File scripts/dev.ps1 sandbox [<NAME>]
```

Sandbox boxes are **`sbx-` prefixed**, completely separated from dev box namespace (no prefix). When calling `bash scripts/dev.sh sandbox <NAME>` with explicit name, can't include `cdx-*` in `<NAME>`; `sbx-*` **reattaches if existing, creates if not** (preserves both auto-name reattach path and participants launching own `sbx-task-a` prefixed sandboxes). Prevents accidental `bash scripts/dev.sh <NAME>` attaching to sandbox. `bash scripts/dev.sh ls` doesn't show sandbox boxes (dev box discovery excludes `sbx-*`). Confirm all boxes with `sbx ls`, destroy with `sbx rm -f <NAME>`.

> ⚠️ **Migration note**: Old boxes from pre-2026-06-27 refactor where `dev.sh` no-arg = clone (`<basename>-<hex6>` format, no prefix) are **discovered as dev boxes** in current design but actually clone boxes (no host checkout mount). Attaching with `bash scripts/dev.sh <old-clone-name>` pretends to bind-mount, causing `/a2a-review` to review stale diffs. **Destroy old clone boxes with `sbx rm -f <NAME>` before using new dev.sh**. New design always `sbx-` prefixes clone boxes (`dev.sh sandbox` route), so prefix-less boxes are now only bind-mount dev boxes.
>
> ⚠️ **Known limitation (multi-checkout cross-pollution)**: `bash scripts/dev.sh ls` / `prune` display `sbx ls` results (host-wide box list) minus reserved prefixes, so **participants launching dev.sh from multiple clones / project checkouts see dev boxes / cdx pairs created in other checkouts mixed in the list**. Calling `dev.sh attach <N>` then newly-provisions current checkout's `cdx-<NAME>` and attaches to other checkout's box, risking `/a2a-review` reading wrong tree. `prune --yes` similarly risks race: misidentifies cdx pairs from other checkout's startup window as orphans (because active dev lock check **only looks at current checkout's `.claude/tmp/`**, unaware of other checkout locks) and deletes them. **Normal workshop operations (1 machine, 1 checkout) unaffected**, but with multiple checkouts, recommended to confirm box names with `sbx ls` before attaching by explicit name / substitute `prune` (dry-run) for `prune --yes` and visually confirm output. Structural fix (include project root hash in box name for filtering) tracked in separate issue ([#75](https://github.com/kanka-jp/coding-agent-playbook/issues/75)).
>
> ⚠️ **`/pr-codex-ci` (codex review) doesn't work in sandbox boxes**: `/a2a-review` **bind-mounts host checkout** to show codex, so codex can't inspect branches written/pushed in sandbox box, possibly returning LGTM on stale/empty diffs. For merge-ready flow, use `bash scripts/dev.sh` (bind-mount dev box). Sandbox limited to **pre-PR ad-hoc use**.
>
> ⚠️ **Sandbox boxes must re-expand stage worktrees**: `.worktrees/` is outside git and not copied by `--clone` ([README](../README.md) §1-3 host-expanded state doesn't come into box). Right after entering sandbox, **run inside box**: `bash scripts/internal/setup-worktrees.sh` to recreate `.worktrees/<NN>/` (details: [rules/box-ops.md](../rules/box-ops.md)). Dev box (bind-mount) sees host's `.worktrees/` directly, so unnecessary.

## View dev server in browser

**First baseline** (no Traefik, everyone has enough): publish box dev port and open directly.

```bash
sbx ports <box> --publish 3000:3000   # → http://localhost:3000
```

For named URLs (`web.<branch>.<repo>.localhost`), optionally use Traefik layer:

```bash
# A) :80 free → launch own Traefik, view by name
bash scripts/dev.sh route up
bash scripts/dev.sh route add <box>             # Default name = <branch>.<repo> → web.<branch>.<repo>.localhost
bash scripts/dev.sh route add <box> 3000 my.name  # Explicit name (dot-separated) → web.my.name.localhost

# B) Shared Traefik already on :80 (standard for multiple projects on 1 server) → auto-detect and piggyback (don't launch own)
bash scripts/dev.sh route add <box>             # Auto-detect :80 shared Traefik (no env needed, no up needed)
bash scripts/dev.sh route detect                # Confirm detection
# Windows: powershell -ExecutionPolicy Bypass -File scripts/dev.ps1 route <verb> <args>
```

Piggybacking (B) auto-detects `:80` file-provider Traefik and routes in/out there (`up`/`down` are no-op, no changes to existing Traefik config). For configs that can't auto-detect (explicit config files etc), supply destination via `BOX_ROUTING_DYNAMIC_DIR` / `BOX_ROUTING_DYNAMIC_VOLUME`. Wiring, Traefik configuration, mode details, Linux native Docker 502 notes: [tools/parallel-dev/box-routing/README.md](../tools/parallel-dev/box-routing/README.md).

**No need for Traefik or `dev.sh route` subcommand if viewing by name isn't necessary** (baseline sufficient). "Entering box" and "viewing dev server by name" are separate concerns; the latter is optional layer.

> Above is **for humans viewing in browser**. To **let agent drive host's visible Chrome via CDP** (maintain box session while operating visible browser), use separate tool [headful-bridge.md](headful-bridge.md) (`scripts/cdp-bridge.sh`). Increased attack surface, so opt-in + disposable profile only (read security section in that doc).
