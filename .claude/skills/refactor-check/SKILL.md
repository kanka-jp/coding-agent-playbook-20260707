---
name: refactor-check
argument-hint: "[PR番号]"
description: "Mechanically checks whether a refactoring PR preserves observable behavior, by diffing the computed styles and rendered output of corresponding elements between base and PR. Launches both base and PR local environments (auto-detected from project structure), navigates the same routes in Chrome DevTools MCP, matches elements by their visible text (not CSS selectors) so it survives DOM structure changes (wrapper add/remove, tag swap), then diffs a curated getComputedStyle fingerprint (color, font-size, font-weight, line-height, spacing, border, layout) plus geometry, and flags visible-text changes as content changes, reporting every difference as a regression candidate — a true refactoring should produce identical output. Use when verifying that a refactor, style-token extraction, component consolidation, or cleanup did NOT change the UI, when the user asks whether the look is really unchanged, or mentions リファクタ, 振る舞い保存, 見た目変わってない, 見た目一緒, computed style 差分, 等価, デグレ, or regression。"
---

# refactor-check

リファクタリング (= 外部から観測できる振る舞いを変えない変更) の PR について、**base と PR の同じ箇所の computed style とレンダリング結果を機械的に差分**し、差が出た箇所を regression 候補として報告する leaf skill ([rules/skills.md](../../../rules/skills.md))。

**原理**: 真のリファクタなら observable output は base と完全一致する。差分が 1 つでも出たら、それは意図しない挙動変化 (= regression 候補) である。スクリーンショットの pixel 比較と違い、`getComputedStyle` の property 単位で差を出すため「どの宣言が・どう変わったか」(例: `color: rgb(31,41,55) → rgb(0,0,0)`) まで特定できる。

このスキルが捕捉する代表的な穴: リファクタで wrapper 要素やクラスを削った結果、色トークンを運んでいたクラスが落ち、親からの**継承で computed color が変わる**ような、画面を一見すると気づきにくい差。

## いつ使うか / 何を検証するか

- 「見た目を変えずに」進めたリファクタ (style-token 抽出・共通コンポーネント化・クラス整理・dead code 削除等) の後、UI が本当に同一かを確認したいとき
- 「ほんとに見た目一緒？」「デグレしてない？」と疑いたいとき
- 対象は **user-visible な UI** (DOM のレンダリング結果と computed style)。内部ロジック・API レスポンス形・DB マイグレーション等の非 UI 変更は対象外 (「画面では確認できない」と明示して差分対象から外す)

## verify / manual-verify との違い

| スキル | 何をするか | base との等価比較 |
|--------|-----------|------------------|
| `verify` | diff から検証項目を生成し「動くか」を確認。`getComputedStyle` は補助 | しない (片方向) |
| `manual-verify` | base/PR を該当箇所ごとの 3 タブ群（3 × N タブ）で並べ、人間が目視で比較 | 人間の目に依存 |
| **refactor-check** | base/PR の対応要素の computed style を**機械的に差分** | **する (これが主目的)** |

「新機能が動くか」ではなく「リファクタで何も変わっていないか」を保証したいときに使う。新しい挙動を足す PR には向かない (差が出るのが正常なため)。

## 引数

| 引数 | 対象 |
|------|------|
| `PR番号`（任意） | `gh pr view` / `gh pr diff` で対象 PR を取得 |
| （なし） | 現在 branch の `git diff`（base は `origin/HEAD`） |

## 手順

```text
Refactor-check Progress:
- [ ] Step 1: diff と base/head の取得
- [ ] Step 2: 検証対象 UI 箇所と対応キーの抽出
- [ ] Step 3: base / PR のローカル環境を起動
- [ ] Step 4: computed-style fingerprint の抽出と差分
- [ ] Step 5: 差分レポート
- [ ] Step 6: クリーンアップ
```

### Step 1: diff と base/head の取得

PR 番号が指定された場合:

```bash
gh pr view {PR番号} --json title,body,files,baseRefName,headRefName,url
gh pr diff {PR番号}
```

PR 番号が省略された場合 (現在 branch)。先に default branch を解決する (`origin/HEAD` 未設定なら `git remote set-head origin -a` で再設定):

```bash
git symbolic-ref refs/remotes/origin/HEAD --short
git diff origin/<base-branch>...HEAD
```

`<base-branch>` は 1 行目の出力 `origin/<branch>` から `origin/` を除いた名前。base ref (比較元) と head ref (PR の変更) を確定する。

### Step 2: 検証対象 UI 箇所と対応キーの抽出

diff を分析し、**画面に現れる変更**だけを対象として列挙する。各箇所について次を特定する:

- **ルート**: その変更が現れる URL パス (例: `/items`、`/settings`)
- **対応キー (correspondence key)**: base と PR で**同じ要素**を突き合わせるための手がかり。第一に**画面に実際に表示されるテキスト** (見出し・ラベル・ボタン文言・セル値)。テキストが一意でない場合はセクション見出し等で限定する。**CSS セレクタや DOM 構造には依存しない** — リファクタは構造を変えうるため (wrapper 追加/削除、`h5 > h2` を `h2` 単独へ等)
- **確認に必要な操作**: クリック・ドロップダウン展開・モーダル表示・フォーム送信等 (操作なしで見えるなら「操作不要」)
- **静的な高リスクシグナル (任意)**: diff の `+`/`-` を見て、ある要素から**スタイルを運ぶクラスが落ちている** (例: 色・サイズ・余白を当てるクラスが削除され、別クラスに置換されていない) 箇所は継承による computed style 変化の温床。Step 4 で最優先で測る候補として記録する

非 UI 変更 (内部ロジック・API・マイグレーション等) は「画面では確認できない」と明示し、Step 4 の対象から外す。

### Step 3: base / PR のローカル環境を起動

**project が定義する dev 起動機構を auto-detect** して使う (このスキルは project 側に専用の構造を要求しない)。検出の優先順位:

1. `CLAUDE_SKILL_DEV_COMMAND` / `CLAUDE_SKILL_DEV_PORT` (project の `.claude/settings.json` で任意設定。未設定でも続行)
2. project の標準構造から推定: `Makefile` の `dev` / `serve` / `up` 系、`package.json` の `scripts` (`dev` / `start`)、`README.md` / `CONTRIBUTING.md` の "Getting Started" / "Development"

**base と PR を別々の worktree で別ポートで同時起動**する (`.worktrees/<slug>/` は project root 相対。`<slug>` は ref 名の `/` を `-` に置換した安全名。worktree の切り方は [rules/worktrees.md](../../../rules/worktrees.md) 参照)。**dev コマンドはその worktree を CWD にしてバックグラウンドで起動する** — CWD がメイン checkout のままだと別 ref のコードを配信してしまう。各 worktree は最新 ref で起動する:

- PR 側: `git fetch origin +pull/<PR番号>/head:refs/refactor-check/pr-<PR番号>` (fork PR でも head 取得、named ref に固定) → worktree が無ければ `git worktree add .worktrees/pr-<PR番号> refs/refactor-check/pr-<PR番号>`、あれば `git -C .worktrees/pr-<PR番号> reset --hard refs/refactor-check/pr-<PR番号>` → その worktree に `cd` して dev 起動 (PR 番号なしモードは現在 checkout が head なので現在の CWD で起動)
- base 側: base branch を確定 (PR 番号あり → `baseRefName`、なし → Step 1 の `<base-branch>`) → `git fetch origin <base-branch>` → worktree が無ければ `git worktree add .worktrees/base-<slug> origin/<base-branch>`、あれば `git -C .worktrees/base-<slug> reset --hard origin/<base-branch>` → その worktree に `cd` して dev 起動

base と PR は **同一の viewport / window サイズ**で開く (computed style は viewport 依存のため、条件を揃えないと差が偽陽性になる)。ポート待機は応答するまでリトライ (最大 30 秒・3 秒間隔目安)。

依存が必要な project (`node_modules` 等) では worktree ごとに install する (worktree は親の `node_modules` を共有しない)。同時起動できない (単一固定ポート / bind 衝突) 場合は sequential に切替え、base を測って fingerprint を保存 → 停止 → PR を測って差分する。dev 起動機構を検出できない場合は環境起動を **silent skip** し、Step 2 で得た対応キーと「ローカル起動不能のため computed-style 差分は未実施」を明示してチャットに出力する。

### Step 4: computed-style fingerprint の抽出と差分

base と PR の同じ route を Chrome DevTools MCP で開き、Step 2 の対応キー (表示テキスト) で要素を突き合わせ、`getComputedStyle` の curated な property 集合 + geometry (`rect`) を **fingerprint** として抽出して差分する。`text` / `tag` / `boxTag` は突き合わせ確認用の補助メタデータ (`text` は対応キーそのもので、両タブ exact 一致時は同値)。これが本スキルの核。

使うツール: `navigate_page` / `take_snapshot` / `evaluate_script` / `click` / `wait_for` / `new_page` / `select_page` / `list_pages` (session が別名の Chrome MCP server を公開している場合はその同等ツール)。

要素の対応付けアルゴリズム・抽出する property の既定集合・base/PR それぞれで実行する `evaluate_script` の関数全文・差分の解釈 (高/低信頼度の分類、サブピクセル許容、構造差の扱い) は [references/computed-style-diff.md](references/computed-style-diff.md) を参照する。

大枠:

1. base タブと PR タブで対象 route を開く (`navigate_page` は `ignoreCache: true`。SPA 内遷移はリンク/ボタンを `click` で操作)。操作が要る箇所は事前に `click` 等で画面に出す (両タブで同じ操作)
2. 両タブで `evaluate_script` に同じ fingerprint 抽出関数 (arrow 関数式) を渡し、対応キーごとに `{ ok, match, tag, boxTag, text, rect, styles }` を取得する (`ok: false` は reason: not-found / ambiguous で突き合わせ不成立)
3. base と PR の fingerprint を比較する。**両タブが `ok: true` かつ `match: "exact"` のときのみ**差を信用する: `styles` 差は computed style regression、`rect` の数 px 差はレイアウトずれ (`text` は対応キーと同値なので両 exact では差が出ない — 表示テキストの変更は item 4 の突き合わせ非対称で検出する)。**Step 2 の高リスクシグナル箇所を最優先で測る**
4. `ok: false` (not-found / ambiguous)、`match: "partial"`、または anchor が一方のタブでしか `ok: true` にならない (非対称) 場合は突き合わせ不成立。これは (a) 対応キーの表示テキストが変わった = content 変更、または (b) 要素の削除・構造変化のシグナル。`styles` / `rect` 差を regression として出さず、まず base/PR で表示テキストが変わっていないか確認する (意図した copy 変更か、消えてはいけないテキストの欠落かを判断)。誤った対応キーが原因なら一意化して測り直す

### Step 5: 差分レポート

```text
## refactor-check 結果 (PR #42)

対象 route: /items  (base: localhost:3000 / PR: localhost:3001)

### 差分あり (regression 候補)
| 箇所 (対応キー) | property | base | PR | 信頼度 |
|---|---|---|---|---|
| モーダル見出し「品目を新規登録」 | color | rgb(31,41,55) | rgb(0,0,0) | 高 |

### 差分なし — `ok: true` かつ `match: "exact"` の成立箇所のみ
- ボタン「保存」: 測定した styles / rect すべて一致
- リンク「一覧へ戻る」: 一致

### 要対応 (未検証) — 振る舞い保存の判定に含めない
- [高リスク] 見出し「在庫サマリ」: base `ok: true` / PR `ok: false` (非対称) → 主目的の高リスク箇所が検証できていない
- 「合計」: `match: "partial"` (anchor が短く「合計金額」に部分一致) → 完全一致キー「合計金額」に直して測り直す
- 「在庫数」: Step 2 で列挙したが Step 4 で未測定 → 測る

### 画面では確認できない変更
- `src/lib/calc.ts` の内部リファクタ → UI に出ないため別手段で確認
```

判定ルール: 各 anchor を **成立** (`ok: true` かつ `match: "exact"` = 測定して一致) と **未検証** (それ以外 = `ok: false` / `match: "partial"` / 非対称 / Step 4 で測らなかった / Step 4 が実行できなかった / Step 3 で測定 skip) の 2 つに分ける。成立箇所のみ `styles` / `rect` を比較する。未検証は `### 要対応 (未検証)` に 1 箇所 1 行で載せ (Step 2 の高リスクシグナル箇所は `[高リスク]`、表示テキストが変わった箇所は `[テキスト変更]` を付ける)、誤った対応キーの partial は完全一致テキストに直して測り直す。表示テキストの変更は対応キーが一致しなくなる observable な content 変更なので、同じ `### 要対応 (未検証)` に `[テキスト変更]` として別掲し overall「振る舞い保存を確認」には含めない。

overall verdict は次の順で決める (上が優先。Rule 1 で regression を処理するため Rule 2 以降の成立箇所は差分ゼロ):

1. 成立箇所に `styles` / `rect` 差 (regression 候補) が 1 件以上 → **「差分あり」**。振る舞い保存とは結論しない (property 単位で base/PR 実値 + 修正方針 1 行。例: 落ちた色トークンクラスを title 要素に戻す)
2. 成立箇所が 0 件 → 測定が走らなかった (Step 3 skip / Step 4 で Chrome MCP 不能) なら **「確認不能 (測定未実施)」**、測定は走ったが全 anchor 未検証なら **「確認不能 (成立箇所なし)」**。いずれも振る舞い保存とは report しない
3. **Step 2 で列挙した対応キーがすべて成立** (= 未検証 0 件) → **「振る舞い保存を確認」(overall)** と明示する。高リスク箇所だけでなく Step 2 の全 UI 対応キーの成立を要求する (一部だけ測って overall success を出す false-green を防ぐ)
4. 成立 ≥ 1 件だが未検証が残る (特に高リスク箇所が未検証) → overall にせず **「成立箇所について振る舞い保存を確認 (要対応 N 件は別途要対応)」** と scope する。高リスク箇所の未検証があればその件数 M も併記する (M=0 なら高リスク句は付けない)

- **測れなかったことを「差分なし」と report しない**

### Step 6: クリーンアップ

- 本スキルが起動した dev server プロセスを停止する (既に起動済みのものは触らない)
- 本スキルが作成した worktree (PR 用 / base 用) は、確認後に停止してから削除コマンドを案内する (自動削除はしない。worktree 削除前に CWD をメインリポジトリへ戻す)

## 環境変数（任意）

project の `.claude/settings.json` の `env` で dev 起動を明示できる (未設定でも auto-detect で動作する):

| 環境変数 | 説明 |
|----------|------|
| `CLAUDE_SKILL_DEV_COMMAND` | dev サーバー起動コマンド |
| `CLAUDE_SKILL_DEV_PORT` | dev サーバーのポート番号 |

## トラブルシューティング

| 問題 | 対処 |
|------|------|
| 対応キーで要素が複数ヒットして特定できない | テキストをセクション見出し等で限定するか、より一意な値 (セル値等) を対応キーに選び直す。曖昧なまま「差分なし」と report しない |
| base と PR で要素数が違う (一方に無い) | リファクタで wrapper の add/remove が起きている。構造差として記録し、表示テキストが残っているリーフ要素同士で computed style を比較する |
| 全 property に差が出る | base と PR の viewport / window サイズが不一致。両タブを同一サイズで開き直す (Step 3) |
| サブピクセルだけ差が出る (width/padding が 0.x px) | フォントレンダリング由来の誤差。低信頼度として扱い、color / font-weight / font-size 等の離散値の差を優先して報告する |
| dev 起動機構が見つからない | 環境起動を silent skip し、対応キーと「差分未実施」を明示。`CLAUDE_SKILL_DEV_COMMAND` の設定を案内 |
| base と PR が同一ポートで衝突 | sequential に切替え (base 測定 → 保存 → 停止 → PR 測定 → 差分) |
| Chrome DevTools MCP に接続できない | ブラウザ起動・MCP server 有効を確認。接続不能なら差分は未実施として対応キーのみ出力 |
| 非 UI のリファクタ (内部ロジック等) | 「画面では確認できない」と明示し computed-style 差分の対象から外す。等価性は別手段 (テスト等) で確認 |
