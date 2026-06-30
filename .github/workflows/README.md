# CI workflows

本リポは現在 **private repo** のため、GitHub Actions の無料分消費を避けて全 workflow を **`on: workflow_dispatch`** のみで定義している (= push / pull_request では自動実行されない、Actions タブから手動 trigger でのみ走る)。

## TODO: public 化時の有効化手順

本リポを public にする (または private のまま自動 CI を回したくなった) とき、各 workflow yaml の `on:` を以下のように書き換える:

```yaml
on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:
```

これで PR ごとに自動実行されるようになり、CLAUDE.md `## 開発フロー` Step 4 の "CI gate" が空っぽ ("no checks reported") にならない構成になる。

## workflow 一覧

| workflow | 対象 | 目的 |
|---|---|---|
| [`actionlint.yml`](actionlint.yml) | `.github/workflows/*.yml` | workflow yaml 自身の syntax / common pitfall を check |
| [`shellcheck.yml`](shellcheck.yml) | `scripts/*.sh` | bash script の static analysis (cross-platform 要件のため重要) |
| [`python-syntax.yml`](python-syntax.yml) | `tools/a2a-review/codex-a2a-server/server.py` | a2a-review server の Python syntax を `py_compile` で check (PR #43 の修正対象) |

## 設計判断 (なぜ `workflow_dispatch` only か)

- 案 A (yaml を書かず doc のみ): 将来 yaml を 0 から書くコストが残る
- 案 B (`_disabled/` 配下に置く): yaml 配置が非標準で、有効化に `git mv` が必要
- **案 C 採用 (本構成)**: `.github/workflows/` 直下に置く + `workflow_dispatch:` のみ = trigger 書き換え 1 行で有効化可、UI で workflow の存在も見える

`workflow_dispatch` は **手動 trigger を可能にする** ので、整備の動作確認をしたいときは Actions タブから走らせて自分で課金できる。
