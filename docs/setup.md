# Setup Details

Supplements not covered in [README](../README.md) §1 Quick start. Credentials permissions rationale, cdx-`<NAME>` pair reviewer operations, image / claude / codex update procedures.

## Authentication Secrets Details

sbx auto-provisions to box on launch, so no need to `/login` / authenticate GitHub each time. **Even global secrets only provision at box creation**, so register the 3 secrets below (anthropic / github / openai) before launching box with `scripts/dev.sh` (registering later requires box recreation to take effect). For using **API key route / `/login` inside box route / codex subscription (`~/.codex/auth.json` transfer) route**, see [sbx/README.md](../sbx/README.md) "Authentication" section.

### anthropic (run claude inside box)

```bash
claude setup-token                         # Issue long-lived token sk-ant-oat01-... (once on host)
sbx secret set -g anthropic                # Paste displayed token
```

To avoid issuing long-lived token and just use API key route, replace `claude setup-token` with [sbx/README.md route A](../sbx/README.md#route-a-api-key-proxy-injection-token-stays-off-box) (paste API key to `sbx secret set -g anthropic`). In this case, skip host `claude` CLI install.

### github (PR operations)

In PR flow [README](../README.md) §3, box runs `gh pr create` / `gh pr checks` / `gh run view`. Issue **fine-grained PAT** ([https://github.com/settings/personal-access-tokens/new](https://github.com/settings/personal-access-tokens/new)):

- **Repository access**: limit to this repo only (own copy if fork)
- **Permissions** (Repository permissions):
  - Contents: Read and write — for `gh pr create` / `git push`
  - Pull requests: Read and write — for `gh pr create` / `gh pr edit` / `gh pr comment` / `gh pr merge`
  - Issues: Read and write — for filing review-derived backlog from box with `gh issue create` (missing causes `Resource not accessible by personal access token (createIssue)` failure)
  - Actions: Read-only — for `gh pr checks` statusCheckRollup / `gh run view --log` CI failure diagnosis
  - Commit statuses: Read-only — legacy status check API (used alongside `gh pr checks`)
  - (Metadata: Read-only auto-granted)
- **Expiration**: recommend ~90 days (reissue + re-register when expired)

Paste issued PAT (`github_pat_...`) to `sbx secret`:

```bash
sbx secret set -g github                   # Paste PAT to displayed prompt
```

> ℹ️ **Why choose fine-grained PAT**: classic PAT or OAuth token from `gh auth login` have scope over all repos for the account, so if compromised in box (YOLO execution), blast radius is large. Fine-grained PAT scopes to target repo + needed permissions only, structurally minimizing attacker's reachable scope after exiting box ([Docker Sandboxes official guidance](https://docs.docker.com/ai/sandboxes/security/credentials/) is the same least-privilege principle). Setting expiration also bounds valid period on leak.

### openai (codex review = /a2a-review / /pr-codex-ci)

```bash
sbx secret set -g openai --oauth           # Authenticate ChatGPT in browser (same flow as codex CLI, subscription route recommended)
```

## cdx-`<NAME>` pair reviewer operations (per-pair lifecycle)

Codex second-opinion (`/a2a-review` / `/pr-codex-ci`, [README](../README.md) §3 PR flow step 4) throws instructions to A2A server on codex box `cdx-<NAME>` paired with claude box `<NAME>`.

**per-pair lifecycle**:

- **Launch**: Running `bash scripts/dev.sh` (no args, auto-named) or `bash scripts/dev.sh <NAME>` (explicit name, bind-mount path) makes dev.sh auto pair-setup `cdx-<NAME>` and bg-fork `pair-serve` (server start + publish host port kernel ephemeral + allow claude box egress + write lease file) as child process (~30s first time, fast on box reuse after).
- **In use**: Claude box env gets `$A2A_CODEX_URL=http://host.docker.internal:<port>` injected, `/a2a-review` (= `bash scripts/internal/a2a-review.sh ask`) reaches transparently. Starting separate `<NAME>` in parallel, each pair gets independent port, no interference (per-pair design confirmed debate 2026-06-27, port is dynamic ephemeral).
- **Shutdown**: Exiting claude box TTY returns `sbx run`, dev.sh trap runs `pair-teardown` (stop server + delete `cdx-<NAME>` box + delete lease). No orphan reviewer boxes remain. Explicit stop: `bash scripts/dev.sh kill <NAME|N>`.

No need to manually launch reviewer box (auto per lifecycle above). Policy: no resident daemon / launchd / systemd on host (workshop premise: clone alone suffices, direction consistent with PR #68/#70 reverts).

> ⚠️ **If you rotate / update openai secret, must destroy existing `cdx-<NAME>` boxes**: design provisions secret at box creation, so existing boxes post-rotation stay locked to old credentials (causes `/a2a-review` to fail later). Exiting `bash scripts/dev.sh <NAME>` auto-tears down `cdx-<NAME>`, next launch auto-provisions with new secret. Manual destroy: `sbx rm -f cdx-<NAME>` (or `bash scripts/dev.sh kill <NAME>`).
>
> ⚠️ **Sandbox box (`bash scripts/dev.sh sandbox`) has no pair reviewer**: sandbox starts with `--clone .` not mounting host checkout, so codex can't see claude's edits, `/a2a-review` / `/pr-codex-ci` unavailable. Use dev box (`bash scripts/dev.sh`) when reviewer needed ([parallel.md](parallel.md)).

## Image / claude / codex updates (occasionally)

macOS / Linux / Git Bash (Windows):

```bash
bash scripts/build-image.sh                # Image rebuild + sbx template reload (1 line)
bash scripts/dev.sh ls                     # List dev boxes created with old image
bash scripts/dev.sh kill <NAME|N>          # Destroy old dev box (cdx-<NAME> pair also destroyed, state lost)
bash scripts/dev.sh                        # Recreate with new image (no args = auto-named dev box)
# Sandbox boxes (clone) don't show in dev.sh ls. If remaining, confirm with `sbx ls` and cleanup separately with `sbx rm <generated-name>`
```

Windows (PowerShell):

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build-image.ps1
powershell -ExecutionPolicy Bypass -File scripts/dev.ps1 ls
powershell -ExecutionPolicy Bypass -File scripts/dev.ps1 kill <NAME|N>
powershell -ExecutionPolicy Bypass -File scripts/dev.ps1
# Optional cleanup of ad-hoc sandbox boxes: sbx ls; sbx rm <generated name>
```

`scripts/build-image.sh` discards installer layer cache with `AGENT_CACHEBUST`, reusing upstream apt / Chromium cache (avoids re-downloading heavy layers).
