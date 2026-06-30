#!/usr/bin/env bash
# base 省略時は orphan ブランチにする: 講義進行用ファイル (main 系列) を project 側の履歴に持ち込まないため。
set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "usage: $0 <NN-slug> [<base NN-slug>]" >&2
  echo "  e.g. $0 01-blank                 # project 最初の stage (orphan)" >&2
  echo "  e.g. $0 02-onepager 01-blank     # stage/01-blank から分岐" >&2
  exit 1
fi

# --git-common-dir 起点: stage worktree 内から実行しても main checkout root に解決するため
cd "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"

name=${1#stage/}
case "$name" in
  */*|.*|"")
    echo "error: invalid stage name '$1' (use NN-slug like 01-blank)" >&2
    exit 1
    ;;
esac
branch="stage/$name"
path=".worktrees/$name"

if git show-ref --verify --quiet "refs/heads/$branch" \
  || git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
  echo "error: branch $branch already exists (local or origin)" >&2
  exit 1
fi

if [ $# -eq 2 ]; then
  base="stage/${2#stage/}"
  if git show-ref --verify --quiet "refs/heads/$base"; then
    git worktree add --relative-paths -b "$branch" "$path" "$base"
  elif git show-ref --verify --quiet "refs/remotes/origin/$base"; then
    git worktree add --relative-paths -b "$branch" "$path" "origin/$base"
  else
    echo "error: base branch '$base' not found (local or origin)" >&2
    exit 1
  fi
else
  # --orphan は git 2.42+、--relative-paths は git 2.48+（sbx の box 内でも git が効く）
  git worktree add --relative-paths --orphan -b "$branch" "$path"
fi

echo "created: $path ($branch)"
