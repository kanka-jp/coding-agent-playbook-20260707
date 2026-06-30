# ASCII only: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.
param(
  [Parameter(Mandatory = $true)][string]$Name,
  [string]$Base
)

# PS 5.1 decodes native command output with the ANSI codepage; force UTF-8 so non-ASCII repo paths survive.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# git-common-dir based: resolves to the main checkout root even when invoked from inside a stage worktree.
$gitCommonDir = git rev-parse --path-format=absolute --git-common-dir
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Set-Location -LiteralPath (Split-Path -Parent $gitCommonDir)

$Name = $Name -replace '^stage/', ''
if ($Name -eq '' -or $Name -match '[/\\]' -or $Name.StartsWith('.')) {
  Write-Error "invalid stage name '$Name' (use NN-slug like 01-blank)"
  exit 1
}

$branch = "stage/$Name"
$path = ".worktrees/$Name"

git show-ref --verify --quiet "refs/heads/$branch"
if ($LASTEXITCODE -ne 0) {
  git show-ref --verify --quiet "refs/remotes/origin/$branch"
}
if ($LASTEXITCODE -eq 0) {
  Write-Error "branch $branch already exists (local or origin)"
  exit 1
}

if ($Base) {
  $baseBranch = "stage/" + ($Base -replace '^stage/', '')
  git show-ref --verify --quiet "refs/heads/$baseBranch"
  $baseLocal = $LASTEXITCODE -eq 0
  if (-not $baseLocal) {
    git show-ref --verify --quiet "refs/remotes/origin/$baseBranch"
  }
  $baseRemote = (-not $baseLocal) -and ($LASTEXITCODE -eq 0)
  if ($baseLocal) {
    git worktree add --relative-paths -b $branch $path $baseBranch
  } elseif ($baseRemote) {
    git worktree add --relative-paths -b $branch $path "origin/$baseBranch"
  } else {
    Write-Error "base branch '$baseBranch' not found (local or origin)"
    exit 1
  }
} else {
  # --orphan requires git 2.42+; --relative-paths requires git 2.48+ (works inside sbx boxes).
  git worktree add --relative-paths --orphan -b $branch $path
}
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "created: $path ($branch)"
