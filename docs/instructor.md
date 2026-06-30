# 講義運営者向け

## 運用モデル

- **branch / PR**: agent が実際に作業する単位。PR は実演ログとして残す
- **`stage/NN-<name>` ブランチ**: project が通過する各状態のスナップショット (main と履歴を共有しない orphan 系列)。各フェーズの**開始状態**を checkpoint に取り、フェーズの到達点が次フェーズの開始点になるよう**連鎖**で並べる (運用保守・バグ修正のみ健全な状態から「壊れた状態 / 直した状態」を別に分岐するため、checkpoint 数はフェーズ数より多くなる。下記「ステージ」参照)
- **git worktree**: 講義中に「ここまで進んだ状態」を即座に開く (3 分クッキング方式)

## 新しい stage を作る

```bash
bash scripts/internal/new-stage.sh 01-blank                 # project 最初の stage (orphan)
bash scripts/internal/new-stage.sh 02-onepager 01-blank     # stage/01-blank から分岐
```

Windows (PowerShell):

```powershell
powershell -ExecutionPolicy Bypass -File scripts/internal/new-stage.ps1 -Name 01-blank
powershell -ExecutionPolicy Bypass -File scripts/internal/new-stage.ps1 -Name 02-onepager -Base 01-blank
```

stage の規約 (orphan 分離 / 命名 / 講義進行用ファイルを混入させない) は [CLAUDE.md](../CLAUDE.md) 「stage ブランチの規約」参照。

## スライド

講義スライドは**フェーズ単位**で `slides/<NN-slug>.html` に置く (壁打ち / 設計 / 実装 / 仕上げ (並列 issue 処理) / 運用保守・バグ修正 の 5 枚。スライドは状態でなくフェーズに対応するので、stage の checkpoint 数とは一致しない)。reveal.js を CDN から読み込む単一の自己完結 HTML で、中身は markdown 箇条書き (`---` でスライド区切り)。スライドの中身は人間が書く。

- **作る**: `slides/template.html` を `slides/<NN-slug>.html` にコピーし、`<textarea>` 内の markdown を箇条書きで埋める (HTML 雛形は触らない)
- **見る**: HTML をブラウザで開くだけ (ローカルは `file://` で可、ビルド不要)
- **配信 (予定)**: 公開時は GitHub Pages で `/<repo>/slides/<NN-slug>.html` の URL から配る

## ステージ (checkpoint 連鎖)

講義は **壁打ち → 設計 → 実装 → 仕上げ (並列 issue 処理) → 運用保守・バグ修正** の 5 フェーズ。各フェーズは「その区間の**開始状態**」を worktree で即座に開いて実演する (3 分クッキング方式)。あるフェーズの到達点が次フェーズの開始点になるため、stage は project が通過する状態の**連鎖**として並ぶ。運用保守・バグ修正だけは「壊れている状態」と「直した状態」の両方を開きたいので、修正前 / 修正後の 2 点を持つ。

checkpoint は状態の連鎖として並ぶ (✅ = 整備済み / ⬜ = 予定):

| stage | 状態 | どのフェーズで開くか | |
|-------|------|----------------------|---|
| `stage/01-blank` | 空 (root commit / ファイル0件。起点プロンプトは実演時に口頭で与える) | **壁打ち** の開始 → 実演で one-pager を作る | ✅ |
| `stage/02-onepager` | one-pager あり | 壁打ちの到達点 / **設計** の開始 → 実演で設計書を書く | ✅ |
| `stage/03-design` | `docs/design.md` あり (フルスタック + AWS/ECS 構成) | 設計の到達点 / **実装** の開始 → 実演で MVP を作る | ✅ |
| `stage/04-mvp` | 動く MVP (monorepo: web / api / mock / core / infra) | 実装の到達点 / **仕上げ (並列 issue 処理)** の開始 → 大量 issue を並列で潰す | ✅ |
| `stage/05-fixed` | issue を捌いて磨いた MVP (並列 issue 処理 後の健全な状態) | **仕上げ (並列 issue 処理)** の到達点 | ⬜ |
| `stage/06-*` (broken) | バグを仕込んだ / 不具合を再現した状態 | **運用保守・バグ修正** の開始 (壊れている状態) → 実演で直す | ⬜ |
| `stage/07-*` (fixed) | バグ修正済み | 運用保守・バグ修正の到達点 (答え合わせ) | ⬜ |

- スラッグは「その checkpoint がどんな**状態**か」を表す (講義名ではなく状態記述)。各 stage は前 stage を base に分岐する (`stage/01-blank` のみ orphan)。
- **仕上げ (並列 issue 処理)** フェーズの実演手順 (手動ペタペタ / ultracode 並列) は [parallel.md](parallel.md)「大量 issue を並列で捌く」を参照。
- **運用保守・バグ修正** は健全な `05-fixed` をそのまま開始にできない (壊れた状態が要る) ため、`05-fixed` を土台に**バグを仕込む or 運用で出た不具合を再現**して `06-*` (broken・開始) / `07-*` (fixed・到達) を別に分岐する。結果 checkpoint は `01`〜`07` の 7 つ (連鎖 5 つ + 運用保守の broken/fixed 2 つ) で、5 フェーズより 2 多い。具体スラッグは整備時に決定する。
- 講義スライドは状態ではなく**フェーズ**に対応する。上記「スライド」参照。

**現状 (2026-06)**: 壁打ち〜実装の checkpoint まで整備済み。`stage/01-blank` (空の起点・root commit / ファイル0件) → `stage/02-onepager` (one-pager) → `stage/03-design` (`docs/design.md`) → `stage/04-mvp` (動く MVP) が連鎖で存在する。残りはこれから:
- `stage/05-fixed` (`04-mvp` から分岐。並列 issue 処理で backlog を捌いて磨いた状態) の生成
- `stage/06-*` (broken) / `stage/07-*` (fixed) — 運用保守・バグ修正フェーズの「壊れた状態 / 直した状態」ペアの設計 (動く MVP にバグを仕込む or 運用で出た不具合を再現)
