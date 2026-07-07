---
name: manual-verify
argument-hint: "[PR番号]"
description: "Inline human walkthrough for manually verifying a PR's user-visible changes. Overlays frames on every changed element via Chrome DevTools MCP (CSS Anchor Positioning, no UI shift, no screenshot files), launches base and PR local envs, and when both run on distinct URLs builds per-location 3-tab groups (PR-with-overlay / bare-base / bare-PR, scroll/state-synced) so all locations are open (3×N tabs) and the human flips between bare tabs. Prints per-location tab-number guidance (falls back to alternating base/PR URLs) plus click steps quoting on-screen text. For changes whose visual diff only appears in a triggered state (active scrollbar, hover/focus, error/empty, narrow breakpoint), forces that state across the group's tabs without touching the compared property. Use when the user wants a manual verification guide, asks where to look or what to check for a PR, or mentions 動作確認, 手動確認, 赤枠で囲って, ラベル, どこを見ればいい, 発火, or 確認手順."
---

# manual-verify

PR の user-visible な変更を **人間が手で動作確認する**ためのウォークスルーをチャットにインライン出力する leaf skill ([rules/skills.md](../../../rules/skills.md))。各該当箇所の**変更された全要素**を Chrome DevTools MCP でライブ画面上に枠で囲み、箇所ごとに 1 つの識別子ラベル (`ⓐ ⓑ ⓒ` 等) を添えて overlay 注入し（スクリーンショットの書き出しはしない）、確認に必要な操作手順を画面上の実テキストに言及して書き出す（案内はタブ番号が主経路で、3 タブ群非構築時のみ base と PR のローカル環境 URL を交互に並べる）。base と PR を同時起動できる場合は、**該当箇所ごとに専用の 3 タブ群（PR + overlay / base 素 / PR 素、その箇所の route・比較可能な画面状態）**をブラウザに自動構築し、複数該当箇所があれば全箇所ぶんを同時に開く（タブを共有して箇所ごとに開き替えるのではなく、N 箇所 → 3 × N タブ。Step 4 の「タブ構成」参照）。

**省略禁止**: 赤枠・ラベル・3 タブ群・全変更要素の枠を勝手に省略/簡略化しない（人間はこれを頼りに「どこを見れば本当に問題ないか」を把握する）。視認性等の理由で何かを省くときは黙って簡略化せず理由を明記する。「確認できる」「立ち上げた」「完了」と報告する前に、Step 5 冒頭の**完了ゲート**を必ず満たす。

**skip 根拠にしない anti-pattern**（agent が独自判断で「正当な例外」を作って赤枠 / base / 3 タブ群を省く経路を構造的に拒否する）:

1. **「単方向改善 / 改善方向に変化が偏る PR だから base 不要」**: base が壊れた状態 → PR で正しい状態に変わる PR、あるいはバグ修正で base が「現状壊れている」と分かっている PR でも、base/PR 比較は (a) 改善箇所が実際に変わったことの確認 (b) 改善箇所**以外**が変わっていないこと (regression 防止) の両方を担う。「base を立ち上げても壊れていることを確認するだけで意味がない」は誤り（その「壊れている」を **PR が直したか** と **他箇所が連動して壊れていないか** を同時に確認するのが base/PR 比較の目的）
2. **「unit test / snapshot test で固定済みだから live UI 確認不要」**: 単体 test は構文・データ層の固定、manual-verify は live UI の人間目視で別軸。test 通過は live UI 確認の代替にならない（render 経路の bug、CSS 変更による視覚的破綻、データの実画面表示等は単体 test では捕えない）
3. **「`take_snapshot` が token 上限で truncate された / 大規模で取れないから overlay 注入を簡略化」**: snapshot truncate は uid 経由経路の失敗であって overlay 注入そのものの不能ではない。`evaluate_script` で `document.querySelector` / text content match 等で要素を直接特定する代替経路がある（トラブルシューティング「`take_snapshot` が token 上限で truncate される / 大規模で取れない」参照）。**代替経路 (querySelector / text match) を試すまでは overlay skip 不可**。代替経路を試行してもなお**変更要素が 1 つも一意特定できない**場合は完了ゲートの「正当 skip の扱い」**第 2 種類** (item 1/3 全 skip; item 4 必須) に該当し、item 5 (A) で「snapshot 不能 + querySelector も不能」と試行内容と理由を宣言する。**部分失敗** (一部の要素は特定でき、別の一部は特定できない場合) は完了ゲートの「正当 skip の扱い」**第 3 種類** (item 3 部分緩和; item 1/4 は緩和せず) に該当し、特定できた要素で注入を継続しつつ item 5 (A) で「特定できた要素 + 特定不能要素 + 試行方法」を宣言する (黙って代表絞り込みで済ませない。視認性のための代表絞り込みは Step 2 規定の item 5 (C) で別カテゴリ)
4. **「同じテーマの過去 PR で確認済みだから今回は skip」**: PR ごとに変更要素は異なる。前回の確認結果は当 PR の検証の代替にならない
5. **「diff の touched ファイルが backend / schema / 生成物 / internal API のみだから UI 0 件」**: touched ファイル単体を見て「画面に現れない」と判定する経路。**型・API endpoint・schema・enum・i18n リソース等は app/src 側に消費者 (consumer) が存在し、そこが UI として顕在化する**。touched ファイルだけで判定する前に、変更要素 (export 型名・関数名・endpoint path・enum 値・i18n key 等) を `grep -rn` で repository 内の UI tree に対して reverse lookup し、**1 件でも consumer が見つかったらその consumer ファイルから到達する画面・操作を該当箇所として列挙する**。consumer search を skip して「UI 0 件」と結論しない（Step 2「reverse reachability 検証」が SoT）
6. **「dev 起動機構が重量級 (multi-service docker compose / Traefik / Storybook / MSW / 複数サービス並走 等) だから skip」**: dev 環境の重さは skip 根拠にしない。重量級でも project 標準 (`Makefile` / `package.json` scripts / `README.md` / `CONTRIBUTING.md` の "Getting Started" / "Development") で定義された起動手段がある以上 Step 3 末尾の silent skip 段落 (L125「dev 起動機構が project 標準構造のどこからも検出できない場合のみ」が正当 silent skip の唯一根拠) には該当しない。起動に時間がかかっても完了を待って、Step 3 の同時起動条件 (worktree/branch ごとに**実際に host 側で distinct な URL** を発行する) を満たせば overlay 注入 + 3 タブ群構築を行う (満たさない fixed-port / 判定不能のときは Step 3 default の sequential フォールバックに倒す。本 anti-pattern は「重さ」を根拠とする silent skip を禁ずるもので、3 タブ構築自体を無条件に強制するものではない)
7. **「他 worktree との port 競合可能性 / 既存 dev server 稼働中の可能性だから skip」**: port 競合は silent skip 経路ではなく Step 3 の sequential 切替経路 (トラブルシューティング「base と PR が同一ポートで衝突」項目)。「可能性」だけを skip 根拠にしない。判定は (a) **Step 3 の同時起動条件 (host 側 distinct URL 発行機構あり) を満たす場合は同時起動を試み、実起動で `EADDRINUSE` 等の競合エラーが返ったら sequential フォールバックに倒す**。(b) **単一固定ポート / 判定不能の場合は Step 3 (= 「sequential を default」) に従い、無理に同時起動せず最初から sequential を採用する** (実起動 EADDRINUSE 観測を前提にしない)。本 anti-pattern は (a) 経路で「可能性」のみを理由に skip するのを禁ずるもので、(b) 経路の sequential 即時採用を阻害しない。**実際に host 側で distinct な URL を発行する機構** (portless / docker compose で branch ごとに publish port や hostname を変える設定 / branch-based subdomain 等。`docker compose -p <name>` 単独はリソース名空間 = container / network / volume の隔離のみで published port は `5173:5173` の宣言が両 instance で衝突するため本機構に含めない) がある場合は同時起動と 3 タブ群構築が成立するため事前判断で skip しない
8. **「base worktree の追加切り出しが必要 / セットアップ重量級だから skip」**: base worktree の作成 (`git worktree add .worktrees/base-<slug>`) は Step 3 で明示された標準手順で、「追加で要る」は skip 根拠にならない (Step 3 自体が「base と PR を別々の worktree で起動する」を要求している)。worktree 作成や依存 install (`npm ci` 等) が時間を要しても完了まで待つ

## verify との違い

`verify` は agent が自動で挙動を確認し機械判定タグを出す（CI / orchestrator skill 連携用）。本スキルは **人間に「どこを・何を見ればいいか」を渡す**のが目的で、出力はチャットへのインラインのみ・マージ可否判定はしない。最終的な確認操作は人間が行う。

## 引数

| 引数 | 対象 |
|------|------|
| `PR番号`（任意） | `gh pr view` / `gh pr diff` で対象 PR を取得 |
| （なし） | 現在 branch の `git diff`（base は `origin/HEAD`） |

## 手順

### Step 1: 変更内容と base/head を取得

PR 番号が指定された場合:

```bash
gh pr view {PR番号} --json title,body,files,baseRefName,headRefName,url
gh pr diff {PR番号}
```

PR 番号が省略された場合（現在 branch の確認）。先に default branch を解決する（`origin/HEAD` 未設定なら `git remote set-head origin -a` で再設定）:

```bash
git symbolic-ref refs/remotes/origin/HEAD --short
git diff origin/<base-branch>...HEAD
```

`<base-branch>` は 1 行目の出力 `origin/<branch>` から `origin/` を除いた名前。このモードの base は default branch 固定で、base が default 以外の PR を確認したい場合は PR 番号を指定する。

base ref（比較元）と head ref（PR の変更）を確定する。

### Step 2: UI 該当箇所の抽出

diff を分析し、**画面に現れる変更**だけを該当箇所として列挙する。各箇所について次を特定する:

- **ルート**: その変更が現れる URL パス（例: `/settings`、`/items`）
- **画面上の位置と要素**: どのセクション・どのラベル/ボタン/入力の近くか（後で人間に伝えるため、できるだけ**実際に表示されるテキスト**で特定する）
- **アンカー対象（枠で囲む要素） — 代表 1 つでなく、その箇所の変更要素を全列挙する**: その変更を**実際に検証する対象そのもの**を囲む。同じ画面領域で**複数の要素が変更されている場合（例: フォーム内の 10 個の `<input>` をまとめて同一コンポーネントへ収束、検索行の 3 控件の一括差し替え）は、代表 1 つだけでなく変更された全要素を列挙して全部に枠を付ける**（diff の各変更要素 → 1 枠。1 箇所に何個でも枠が付く。枠が 1 つだけだと「同じ画面で他の変更要素にも枠は要らないのか」という取りこぼしになる — 実例で代表 1 控件にしか枠が無く指摘された）。識別子ラベル（`ⓐ` 等）は**箇所ごとに 1 つ**で代表要素に添える（枠ごとには付けない。枠だらけにラベルを足すと画面が埋まる）。「どの画面か」を示すだけの画面見出し（ページタイトル等）は、見出し自体が変更対象でない限りアンカーにしない。出力が変わる変更は変わる要素（追加された行・該当の値セル・新規ボタン等）を囲み、**出力が変わらない変更**（描画を生成する経路の変更 — データ供給経路・状態管理の移行・描画ロジックの refactor 等で描画結果は base と同一。描画に関与しない純粋な内部変更は本 Step 末尾の除外ルール（UI に現れない変更は overlay 注入・URL の対象から外す）に従い対象外）は「描画が base と同一に保たれるか」が検証対象なので**その描画を代表する具体要素**（変更が通るデータ行・値セル等。可能なら欠落値の `−` 表示等、差異が一目で分かる箇所を含む）を囲む
- **変更要素が多すぎて全枠が画面を埋める場合**: 同種の繰り返し要素（テーブルの全行等）が大量にあるときは、視認性のため代表数個に絞ってよい。その場合はラベルに「ほか N 件同種」と明記し、Step 5 の操作手順でも全件が対象である旨を書く（黙って代表だけにしない）
- **before / after**: base では何が表示され、PR では何に変わるか
- **確認に必要な操作**: クリック・ドロップダウン展開・フォーム送信・トグル等（操作なしで見えるなら「操作不要」）。**到達操作を経て初めて現れる content そのものが比較対象**の場合（SelectBox / combobox の候補リスト、popover・autocomplete・tooltip の中身、モーダル/ダイアログの中身、フォーム入力で初めて描画される結果表等。例: データ供給経路の移行で「候補が base と PR で一致するか」が主眼）は、「その content が出た状態」自体が検証対象であることを記録し、アンカー対象を**到達後の content**（候補リスト・ダイアログ内の表等）にする。Step 4 の「到達 content が比較対象」bullet で対象が存在するタブをその状態のまま渡す
- **発火条件（差が default 画面では見えない変更のみ）**: スタイル変更の効果が **default 状態では現れず、特定の状態を発火させて初めて差が出る**箇所を見分ける。例: 横スクロール overflow が有効なときだけ効く footer の `pb-*`→`mb-*`（スクロールバーとボタン群の余白差）、`:hover`/`:focus`/`:active` 等の擬似状態、error/empty/loading/disabled 状態、狭い breakpoint でのみ出るレイアウト、overlay スクロールバーのように既定で不可視な指標。**到達操作（要素を画面に出す click/遷移）とは別軸**で、要素は既に画面にあるが「変更したスタイルが効く状態」が default で起きないものを指す。該当する場合は (1) 発火させる条件、(2) **比較対象プロパティに触れずに決定論的に発火させる手段**（例: footer 幅を `max-width` で制約して overflow を強制、擬似状態を class/style で付与）を特定する。発火が要る箇所は Step 4 の「条件付き発火」で群内 3 タブに同一発火を注入する。default で差が見える箇所は本項目の記載不要

**reverse reachability 検証** (UI 該当箇所 0 件結論前 および hybrid diff での追加 consumer 洗い出し):

diff が backend (Go/Rust/Python schema)、生成物 (swagger.json / orval / protobuf 生成コード / msw mock)、internal API、enum/const 定義、i18n リソースを含む場合、UI 該当箇所の有無にかかわらず、結論を出す**前**に以下を実施する。touched ファイル単体で「画面に出ない」と結論する経路を構造的に塞ぐ。**UI 該当箇所を 1 件以上特定済みでも実施対象**: hybrid diff (schema 系 + `app/src` 等) で agent が `app/src` 側から UI 該当箇所を列挙できた場合も、schema 公開シンボルの consumer が**別画面**にのみ存在するケース (例: 同 PR の `internal/schema.go` + `swagger` + `app/src/FormA.tsx` で schema 追加 enum の consumer が別画面 `ScreenB`) を取りこぼさないよう reverse lookup を実施し、追加 consumer が見つかればその画面も該当箇所にマージする:

1. **公開シンボル抽出**: diff の `+` 行および**変更が属する宣言ブロックの context 行** (`+` 行が touch している関数 / 型 / interface / class / enum の見出し行と body のシンボル名)、ならびに `-` 行 (rename / remove 元の旧シンボル名) から **app 側から参照されうる名前**を抽出する。`+` 行限定だと既存 export 宣言行が context のままで新規 field のみ追加されたケースで宣言名を取りこぼし、reverse lookup の recall を落とす
   - Go/TS/Rust/Python の export 型名・関数名・const 名 (interface / type / class / function / enum)
   - API endpoint path (`POST /foo/bar` / `/api/v1/...`)、swagger operationId、schema 名
   - i18n key (`messages.foo.bar`)、CSS class 名、URL path 等の文字列リテラル
2. **UI tree への reverse lookup**: 抽出した各 symbol を `grep -rn` で UI コード tree に検索する。検索対象は project 標準構造から推定:
   - TS/JS: `app/src/`、`src/`、`frontend/`、`packages/web/`、`web/` 等
   - 生成 client 経由 (orval / openapi-generator): `app/src/api/` / `app/src/generated/` も含む — ここを skip すると「生成物だから無視」の罠
   - Step 3 と同様、project の標準構造から自動推定 (project に専用構造は要求しない)
3. **画面到達経路の構築**: 1 件でも consumer が見つかったら、その consumer ファイルの import 元を辿り、**画面コンポーネント (route handler / page component)** まで到達する経路を全て列挙する。複数 consumer が同じ画面に収束する場合は 1 該当箇所にまとめてよい
4. **到達した画面を Step 2 の通常の該当箇所として扱う**: 各 route → 画面 → consumer の使用箇所 (input form, 表示エリア等) をアンカー対象として列挙

reverse lookup 経路 (symbol 抽出 + grep) を試した上でも consumer が 0 件であることが確認できた場合のみ「UI 0 件」結論に進める。試行内容 (検索した symbol 一覧 + 検索対象 tree path) を Step 5 完了ゲート item 6 (本サブセクションの自己点検項目) で宣言する。

**reverse lookup を skip してよい条件** (いずれかに該当):

- diff の touched ファイルがすべて pure docs (`docs/**` / `README.md` / `CHANGELOG.md` / `*.md`) や CI 設定 (`.github/workflows/`) で、symbol export を含まない
- diff の touched ファイルがすべて **production code に到達しないファイル群** — プロジェクト設定 (`package.json` / `tsconfig.json` / `vitest.config.ts` / `next.config.js` 等)、テスト設定 / ビルドスクリプト、テストコード (`*.test.*` / `*.spec.*`、production export を含まないもの) — のみで、production の UI に到達するシンボル export を含まない
- diff が **`app/src` 等の UI コード**のみで schema 系 (backend / swagger / orval / msw / i18n / enum / const 定義) を一切含まず、agent が diff から UI 該当箇所を直接特定できる (= hybrid diff の主旨に該当しない pure UI 変更)

Go schema / swagger / orval / msw / i18n リソースは「generated だから UI 無関係」の罠 — これらはむしろ「UI から呼ばれる契約」のため reverse lookup の主対象 (skip 条件に該当しない)。

UI に現れない変更（内部ロジック・API レスポンス形・DB マイグレーション等）は **「画面では確認できない（手動/別手段）」**と明示し、overlay 注入・URL の対象から外す。

### Step 3: base / PR のローカル環境を起動

**project が定義する dev 起動機構を auto-detect** して使う（本スキルは project に専用の構造を要求しない）。検出の優先順位:

1. `CLAUDE_SKILL_DEV_COMMAND` / `CLAUDE_SKILL_DEV_PORT`（project の `.claude/settings.json` で任意設定。未設定でも続行）
2. project の標準構造から推定: `Makefile`（`dev` / `serve` / `up` 系ターゲット）、`package.json` の `scripts`（`dev` / `start`）、`README.md` / `CONTRIBUTING.md` の "Getting Started" / "Development"

**base と PR を別々の worktree で起動**する（`.worktrees/<slug>/` は project root 相対。`<slug>` は ref 名の `/` を `-` に置換した安全名。worktree の切り方は [rules/worktrees.md](../../../rules/worktrees.md) 参照）。**dev コマンドはその worktree を CWD にしてバックグラウンドで起動する** — CWD がメイン checkout のままだと別 ref のコードを配信してしまう。foreground 起動だと Bash session が dev に占有され port 待機・Chrome 操作に進めない。各 worktree は**最新 ref で起動する**（既存なら fetch 後に更新、無ければ作成）:

- PR 側: `git fetch origin +pull/<PR番号>/head:refs/manual-verify/pr-<PR番号>`（fork PR でも head を取得。named ref に固定して `FETCH_HEAD` の上書きを避ける。`+` で force-push 後の non-fast-forward も更新）→ worktree が無ければ `git worktree add .worktrees/pr-<PR番号> refs/manual-verify/pr-<PR番号>`、あれば `git -C .worktrees/pr-<PR番号> reset --hard refs/manual-verify/pr-<PR番号>` → その worktree に `cd` して dev 起動（PR 番号なしモードは現在 checkout が head なので現在の CWD で起動）
- base 側: base branch 名を確定（PR 番号あり → `baseRefName`、なし → Step 1 で解決した `<base-branch>`）→ `git fetch origin <base-branch>` → worktree が無ければ `git worktree add .worktrees/base-<slug> origin/<base-branch>`、あれば `git -C .worktrees/base-<slug> reset --hard origin/<base-branch>` → その worktree に `cd` して dev 起動

**同時起動 vs sequential**:

- dev コマンドが **worktree/branch ごとに実際に host 側で distinct な URL** を発行する場合（branch 由来のホスト名・サブドメイン・publish port をホストへ実際に bind する等。`docker compose -p <name>` 単独はリソース名空間のみで `5173:5173` 等の published port が両 instance で衝突するため**本条件に含めない** — 詳細は anti-pattern 7）のみ base と PR を同時起動し、両方の URL を得る → Step 4 の「タブ構成」で**該当箇所ごとに 3 タブ群**を構築し、Step 5 はタブ番号案内を主経路にする（URL 交互表示は 3 タブ群非構築時のみ）
- それ以外（単一固定ポート / 判定不能）は **sequential を default** とする（base を起動 → 確認 → 停止 → PR に切替）。無理に同時起動して 2 つ目の bind を衝突させない。この場合 URL は同一で、人間には branch 切替手順を併記する

dev 起動機構が project 標準構造のどこからも**検出できない**場合 (= `CLAUDE_SKILL_DEV_COMMAND` 未設定 + `Makefile` / `package.json` scripts / `README.md` / `CONTRIBUTING.md` の "Getting Started" / "Development" のいずれにも該当ターゲット無し) のみ環境起動を **silent skip** し、Step 2 で得た該当箇所・操作手順のみをチャットに出力する（overlay 注入と URL は省略し、その旨を明記）。**dev 起動機構が重量級 (multi-service docker compose / Traefik 等) / 他 worktree との port 競合可能性 / base worktree 追加が必要 等は silent skip 根拠にしない** (冒頭「skip 根拠にしない anti-pattern」6/7/8 項目)。port 競合の判定は anti-pattern 7 のとおり (a) host distinct URL 機構あり → 同時起動を試み EADDRINUSE 観測後 sequential、(b) 固定ポート / 判定不能 → 上述「単一固定ポート / 判定不能」case (sequential を default、無理に同時起動しない) に従う。

ポート待機は応答するまでリトライ（最大 30 秒・3 秒間隔目安。multi-service docker compose / Traefik 等の重量級 dev は ready 判定 (ログ上の "ready" / "listening" 等のマーカー / healthcheck / port 応答) までに 30 秒超かかる場合があり、その場合は port 待機 30 秒 cap を ready 判定可能な段階から計上するか、延長する。**dev server プロセス自体の終了は待たない** — `npm run dev` / `vite` / `next dev` 等の long-running server は serve 開始後も process 終了しないため、anti-pattern 6 の「起動に時間がかかっても完了を待って」の「完了」は process 終了ではなく ready 判定到達を指す）。

### Step 4: 各該当箇所をライブ画面で枠とラベルで指し示す

PR 環境を表示している実ブラウザ（Chrome DevTools MCP が操作する。人間が画面で見られる）で、各該当箇所に**枠とラベルを overlay 注入**して「どこを・何を見ればよいか」を示す。**スクリーンショットの書き出しはしない**（注入検証のための `take_screenshot` は inline 取得のみで、`filePath` 指定によるファイル保存はしない）。使うツール: `navigate_page` / `take_snapshot` / `evaluate_script` / `click` / `wait_for` / `take_screenshot` / `new_page` / `select_page` / `list_pages`（session が別名の Chrome MCP server を公開している場合はその同等ツール）。

#### タブ構成（同時起動時は該当箇所ごとに 3 タブ群を default で構築）

Step 3 で base と PR を**同時起動**した場合（worktree ごとに別 URL）、**Step 2 で列挙した該当箇所ごとに専用の 3 タブ群**をユーザーの個別指示を待たずに構築する。タブを共有して箇所ごとに開き替える順送り方式は取らず、複数該当箇所があれば全箇所ぶんの群を同時に開く（N 箇所 → 3 × N タブ）。各群は 1 箇所に固定で、その箇所の route・到達状態・スクロール位置に揃える。群内の 3 タブは:

| 群内タブ | 内容 | 役割 |
|------|------|------|
| ① PR赤枠 | PR 環境 + 枠/ラベル overlay | どこを見るかの位置ガイド |
| ② base素 | base 環境（overlay なし） | ② ⇄ ③ を切替えて素の描画を比較 |
| ③ PR素 | PR 環境（overlay なし） | 同上（枠/ラベルが pixel 比較の邪魔にならない素の PR） |

- **1 群 = 1 該当箇所**。群内の ①②③ は**同一 route・同一到達状態・同一スクロール位置**に揃える（群をまたいで route が違ってよいが、群内が混在すると人間がどのタブで何を比較するのか追えない）
- **群ごとに ①②③ の pageId を群番号とともに控える**（Step 5 の絶対タブ番号案内に使う。群内①③・別群どうしは同一 URL になりうるため、後追いの `list_pages` では URL から区別できず pageId 対応が必須）
- **構築順（各該当箇所で繰り返す）**: ①で対象 route を開く（1 群目は現在のタブ — **最初の `new_page` の前に `list_pages` で 1 群目①の pageId を控える**。2 群目以降は `new_page` で **PR 側の対象 route の full URL** を開き、レスポンスの Pages 一覧で **① として pageId 記録** — ②③ と同様、①も他群の③と同一 URL のため記録漏れがあると後続の `select_page` で特定できない）→ overlay 注入と検証（下記手順 1〜6）→ `new_page` で **base 側の対象 route の full URL**（origin だけでなく path まで。② として pageId 記録）→ `new_page` で **PR 側の対象 route の full URL**（③ として pageId 記録。各 `new_page` のレスポンスの Pages 一覧で新規タブの pageId を確認）→ 到達操作が要る箇所は対象が存在するタブで再現（下記「到達操作」bullet）→ **群内①→②・③の順にスクロール位置を同期（次 bullet、必須）**。全群を構築し終えたら、最後に 1 群目①の pageId で `select_page` し前面に戻す（`new_page` は selected page を新タブへ移すため、各群の overlay 注入と pageId 控えを**先に**済ませる。前面復帰は人間が最初に見るのを位置ガイドにするため）。**Step 2 で発火条件ありと判定した箇所は、全タブ（①②③）に同一の Force-trigger を差し込む**（① は overlay 注入＝手順 4 の前、②③ は overlay を持たないため到達操作の後・スクロール同期の前。順序は下記「条件付き発火」の「構築順・手順への組み込み」bullet が SoT）
- **スクロール位置の同期（必須・構築順の一部）**: 各群内で **①から順に**行う。まず①を `select_page` で選択し、その群の該当箇所の対象（本 bullet の「対象」は Step 4 手順 3 と同じく Step 2 の**アンカー対象**を指す。「画面上の位置と要素」の見出し等ではない。**1 箇所に複数の枠がある場合は代表 = label を付けた最初の要素〔注入関数の `firstTarget`〕の可視テキストで同期する**。全枠を 1 つの中央 Y に揃えることはできないため、代表に揃え、代表から縦に離れた枠は手順 6 のスクロール確認でカバーする）の可視テキストで references/overlay-injection.md の「Scroll-sync snippet」を実行して位置を最新化し、**戻り値 `y` を①の比較値とする** — overlay 注入時の戻り値 `rect` は比較に使わない（②・③構築中の遅延レイアウト〔画像・フォント・lazy コンポーネント〕で stale になりうるため。snippet は scroll と計測のみで overlay には影響しない）。続けて②・③を `select_page` で順に選択し、**各タブで対象テキスト（fallback 時は anchor テキスト）を `wait_for` してページ安定を待ってから**同 snippet で揃える（`new_page` / 遷移直後は非同期レンダリングで layout が変動中のことがあり、不安定なまま中央寄せすると `ok: true` でも読み込み完了後にズレる偽性成功になる）。対象の識別テキストが sr-only にしか無い（icon ボタン等）場合は、snippet は可視テキストしか探せないため、**両環境に共通する近傍の可視テキストを anchor に選び、群内 3 タブとも anchor で同期して中央 Y 一致を確認する**（対象が PR 新規でもこの方式 — 例外 1 の「③ は対象自身」は適用しない。①の赤枠は対象の uid のままでよく、anchor は近傍のため赤枠も視界内に入る。離れていて赤枠が画面外になるなら、より対象に近い可視テキストへ anchor を選び直す）。素タブを route 先頭のまま放置すると、人間がタブ切替のたびに手でスクロールを合わせ直すことになり切替比較が成立しない。アプリが window でなく内部コンテナをスクロールする構造だと `window.scrollTo` は効かず `window.scrollY` も 0 のままになる（実機で発生）が、`scrollIntoView` はどの祖先がスクロールするかに依らず機能する。**揃ったことの検証**: **群内 3 タブとも snippet 戻り値 `y`（対象 box 中央の viewport Y）の差が数 px（目安 |Δ| ≤ 5）に収まれば同期完了**とする（`block: 'center'` は要素 box の中央を viewport 中央へ寄せるため、top でなく中央 Y で比較する — base / PR で要素高さが異なる見出し level 変更等でも偽性ズレが出ない。許容誤差の SoT は本 bullet）。snippet は内部で再 scroll 収束ループを回し戻り値に `settled` を返す（遅延ロードで計測後に中央 Y がズレるのを sample-stable まで収束させる。収束ロジックは references/overlay-injection.md「Scroll-sync snippet」の仕様メモ参照）。いずれかのタブが `settled: false` を返した場合はレイアウトが止まっておらず `y` の信頼度が低いため、`wait_for` で安定を待って再実行する（下記**例外 1/2** 適用時も、`ok: true` でも `settled: false` のタブは同様に再実行対象）。**例外 1（PR 新規要素）**: 対象が base 側に存在しない場合、③ は対象自身で同期し、**② のみ**両環境に共通する直近の実テキスト（セクション見出し等）を anchor にする。中央 Y 一致は① ⇄ ③で確認し、② は snippet が `ok: true` かつ `settled: true`（anchor 中央表示・収束済み）を返せば完了（`settled: false` は `wait_for` 後に再実行）。**例外 2（テキスト変更）**: ② は before・③ は after テキストで同期し、各タブで `ok: true` かつ `settled: true` が返れば完了（`settled: false` は `wait_for` 後に再実行。別要素の中央寄せのため厳密な中央 Y 一致は要求しない）。操作（ドロップダウン展開・モーダル開放等）を経ないと対象が描画されない箇所は、先に到達操作の再現（下記 bullet）で**対象が存在するタブ**（通常は群内 3 タブとも、PR 新規 UI のトリガーは①・③）で対象を画面に出してから同期する（対象が viewport 固定のモーダル内等でスクロール位置が切替比較に影響しない場合は同期を skip してよい）
- 以後の `select_page` は記録した pageId 対応で行う（群内①と③、別群どうしは同一 URL になりうるため、`list_pages` の URL では区別できない）
- **別の該当箇所はタブを開き替えず新しい 3 タブ群を追加する**。初回群と同順で構築する（上記「構築順」を `new_page` から繰り返す）。同一 route に複数の該当箇所がある場合も**箇所ごとに別の群**を作る（各群はその箇所のスクロール位置に固定されるため、開き替えによる再同期は発生しない）。クライアント状態が URL に乗らず対象 route の直開きでは再現できない確認では、その群の各タブを `new_page` で entry route から開き、タブ内のリンク/ボタンを `click` で辿って対象 route に到達してから（`navigate_page` は full reload でクライアント状態が消える — 手順 1 の SPA 注意参照）、通常どおり続ける（発火条件ありの箇所は到達後に Force-trigger も注入する。順序は「条件付き発火」の「構築順・手順への組み込み」bullet が SoT）
- **到達操作**（モーダルを開く・ドロップダウン展開・ページ内タブ切替・フォーム入力等、確認対象を画面に出すための操作）が必要な該当箇所は、①で実施した操作を**対象が存在するタブでも agent が再現**する（再現が要るのは通常②・③、PR 新規 UI のトリガーは③のみ — 存在と再現対象の区別は下記参照）。再現したタブを同じ画面状態に揃えてから Step 5 に進む（各タブを `select_page` で選択 → `take_snapshot` で同テキストの要素を特定 → `click` 等で操作 → `take_snapshot` で状態到達を確認。トリガーのテキスト自体が PR で変更されている場合は② は before・③ は after テキストで特定し〔例外 2 と同様〕、テキストを持たない icon トリガーは `take_snapshot` の accessible name / role で特定する。トリガー自体が base に存在しない（PR 新規 UI の）場合は、トリガーは①（PR + overlay）と③（PR 素）に存在し②（base 素）には無いため、**素タブのうち再現が要るのは③のみ**（① は overlay 構築時に操作済み）・② は到達操作を skip して route・スクロール同期までに留める〔例外 1 と同型 — ② ⇄ ③の比較は「base に無い / PR で出る」の確認になる〕。クライアント状態は URL に乗らないため route を揃えるだけでは再現されず、操作を人間任せにすると確認対象が画面に出ていない素タブを渡すことになる）。再現は**スクロール同期の前**に行う。**挙動そのものが確認対象の操作**（トグルを ON にして反応を見る等）は人間が実施するため揃え対象外とし、Step 5 の操作手順に書く
- **到達 content が比較対象（必須・到達操作の特殊系）**: 到達操作を経て初めて現れる content そのものが比較対象（SelectBox / combobox の候補リスト、popover・autocomplete・tooltip の中身、**モーダル/ダイアログの中身**、**フォーム入力で初めて描画される結果表**等。Step 2「確認に必要な操作」で記録した箇所）では、到達操作で出した状態を**閉じずに維持**する（到達操作の再現対象は親の「到達操作」bullet のとおり ②・③、PR 新規 UI のトリガーは③のみ。① は overlay 構築時に操作済み）。**到達が多段（モーダルを開く → フォーム入力で結果表を描画させる等）でも、静的な比較対象を画面に出すための操作はすべて agent が対象の存在する比較タブ（②・③、PR 新規 UI は③のみ）で再現する** — 「結果表は別途人間操作で」と人間に丸投げしないこと（実例で base/PR 比較タブのダイアログを開かず closed のまま渡し指摘された）。結果として対象が存在する各タブを**その状態のまま**にし、閉じた制御要素ではなく**到達後の content**（候補リスト・ダイアログ内の表等）をアンカー対象にして overlay（①）を当て、スクロール同期も（対象が存在するタブで）到達 content に対して行う（② に対象が無い PR 新規 UI は既存スクロール同期の例外 1 に従う。制御要素に枠を付けて閉じたまま渡すと、人間が各タブで開き直さねばならず候補・差分の取りこぼしを切替比較で検出できない）。これは「挙動そのものが確認対象の操作」（人間がトグル等を操作して**動的な反応そのもの**を観察する）とは別 — 到達後の content は**静的な比較対象**なので agent が事前に対象の存在する各タブで出しておく。Step 5 のウォークスルーには「対象が存在するタブは到達状態済み・タブ切替だけで見比べられる」旨を明記する（下記例外で sub-state を人間手順に委ねた場合は、その箇所のみ「人間が各タブで再現」と併記し overstate しない）。**例外（overlay を当てられない到達 content）**: (i) ブラウザネイティブ `<select>` の OS 描画 option リスト等、到達後の content が DOM 要素として取得できない場合は開いた状態の維持も anchor も不能なため、制御要素の位置を Step 5 のテキスト手順で案内して人間が各タブで開いて比較する。(ii) ネイティブ `<dialog>.showModal()` / Popover API のような **top-layer** に出るモーダル/popover は DOM 取得自体は可能で agent が開いて揃えられる（開く・維持・再現は本 bullet どおり）が、①の overlay（`position: fixed`）が top-layer の下に隠れるため枠付けのみ skip し、Step 5 のテキスト手順で位置を案内する（トラブルシューティング「top-layer UI」「対象要素が特定できない」・設計方針 5 と同じ skip 経路。z-index ベースの portal モーダルは overlay が効くため本例外の対象外）
- **sequential 起動**（単一ポート）では base / PR を同時に開けないため 3 タブ群は組まず、単一タブ + branch 切替手順の案内にする（複数箇所は箇所ごとに切替手順を併記する）

#### 条件付き発火（検証用強制トリガー）が必要な該当箇所

Step 2 で**発火条件**ありと判定した箇所（差が default 画面では見えず、特定状態を発火させて初めて出る変更）は、overlay 注入・スクロール同期の**前に**、その群の**全タブ（①②③）へ同一の発火を注入**する。到達操作（要素を画面に出す）とは別工程で、要素は既に画面にあるが「変更したスタイルが効く状態」を強制する。

- **構築順・手順への組み込み（必須・本サブセクションが発火タイミングの SoT）**: 上記「構築順」「手順」は default では発火工程を持たない。発火条件ありの箇所では、**群内 3 タブそれぞれ**で **route 到達 →（到達操作があれば再現）→ Force-trigger snippet 注入 →（① のみ overlay 注入＝手順 4） → スクロール同期** の順にする（① の overlay は Force-trigger の**後**に当てる＝発火後の最終レイアウトに枠を合わせる。references/overlay-injection.md「Force-trigger snippet」の推奨順「発火 → overlay 注入 → スクロール同期」と同じ）。**②③ は overlay を持たないが Force-trigger は省かない** — overlay 工程が無い分「overlay の前」という基準が効かないため、構築順上は **②③ を `select_page` した後・スクロール同期の前に同一 Force-trigger を注入する**（明示しないと「① だけ発火・②③ は default」になり base/PR 素タブ比較で差が見えない）。「構築順」「手順」はこの組み込みに従って発火工程を差し込む（両者が個別に発火順を再定義せず、本 bullet を唯一の SoT とする）
- **発火成立を検証する（必須）**: 各タブで Force-trigger 注入後、戻り値の `ok` / `hasScroll` を確認する。`ok: false`（対象不在＝誤セレクタ / 未描画）や、overflow 系で `hasScroll: false`（強制幅不足 / overflow 未設定）なら再調整して再実行し、**群内 3 タブすべてで発火成立を確認してから** overlay・スクロール同期・比較に進む（overlay の戻り値 `rect` 非ゼロ検証〔設計方針 5・手順 5〕と同型。発火が成立しない素タブをそのまま人間に渡すと差が見えない）
- **全タブに同一発火（必須）**: base/PR 比較が成立するよう、群内 3 タブに**同じ発火**を注入する。片方のタブだけ発火させると余白差が発火の有無に化けて比較が無意味になる
- **比較対象プロパティには触れない（必須）**: 発火は**トリガー条件だけ**を作る。比較する `pb`/`mb` 等のプロパティ自体は変えない（例: 横スクロールを出すなら footer の `max-width` を絞る等、対象 box の padding/margin を触らずに overflow を起こす手段を選ぶ）。対象プロパティを書き換えると base/PR の差そのものを潰す
- **既定で不可視な指標は可視化する**: macOS の overlay スクロールバーのように既定で見えない指標が比較対象のときは、常時表示 + 対比色（赤等）を併せて注入し、人間が差を観察できるようにする（これは自然描画ではない**検証用の可視化**）
- **発火はページの DOM/style を変える**（body 直下に重ねるだけの overlay とは別物）。注入する `<style>` には cleanup 用属性を付け、Step 6 で除去する。実装は [references/overlay-injection.md](references/overlay-injection.md) の「Force-trigger snippet」参照
- **Step 5 で宣言する**: 発火させたタブは自然な状態と異なるため、ウォークスルーに「この群は◯◯を強制発火させた状態」「default 画面では発火させないと差が見えない」旨を明記する（黙って加工しない）

#### 設計方針 (必須・実機検証で確立)

逸脱すると典型的な破綻が起きる。実装サンプルと方式比較・破綻の根拠は [references/overlay-injection.md](references/overlay-injection.md) 参照:

1. **対象要素の DOM/style への変更は最小限** — `el.style.outline` / `el.style.border` / wrapper 挿入は禁止。祖先に `overflow-x: auto` があると CSS 仕様で `overflow-y` も `auto` に強制昇格され、`outline` 上辺がクリップされる ([W3C CSS 2.2 §11.1](https://www.w3.org/TR/CSS22/visufx.html) / [drafts.csswg.org/css-overflow](https://drafts.csswg.org/css-overflow/))。**許容される変更は次の 3 つのみ** (いずれも layout 影響なし): (a) `anchor-name` の追加 (CSS Anchor Positioning の anchor 指定)、(b) `data-manual-verify-anchor-host` 属性の追加 (cleanup 時に元の `anchor-name` 値を復元するためのバックアップ)、(c) `scrollIntoView({ block: 'center', behavior: 'instant' })` の呼び出し (対象を画面中央に出すため、scroll 状態のみ変更。`'instant'` は `scroll-behavior: smooth` 環境で直後の rect 読みが過渡座標になるのを防ぐ)。**本「3 つのみ」は overlay 追従のための対象要素変更を制約するもので、検証用に画面状態を強制する「条件付き発火」(上記サブセクション) の対象外**。条件付き発火は layout を意図的に変える (`max-width` 等) が、対象の inline style を直接書き換えず cleanup 可能な `<style>` ルール (`data-manual-verify-force-trigger`) 経由で当てる別経路で、用途 (発火状態の再現) も適用面 (検証対象そのものでなく発火条件) も overlay 追従とは異なる
2. **枠とラベルは `document.body` 直下の別 overlay 要素**として配置 — `position: fixed` + `pointer-events: none` + `z-index: 2147483647`。既存 UI を一切ずらさず、操作も透過する
3. **ラベルは箇所ごとに 1 つ（必須）** — 識別子（`ⓐ ⓑ ⓒ` 等）+「何をするか / 何を確認するか」の 1 行説明を添える。before/after の期待値が数値で明確なら入れる（例: `ⓑ ここを確認: PR=6 行, base=2 行`）。赤枠だけだと意図が伝わらない。**1 箇所に複数の枠があってもラベルは代表要素 1 つに付ける**（枠ごとにラベルを足すと画面が埋まる。注入関数は複数 uid を受け取り、各 uid に枠・最初の解決成功要素にだけラベルを付ける — references/overlay-injection.md）
4. **追従は CSS Anchor Positioning を第一選択** — 対象に `anchor-name: --<unique>` を当て、follower 側で `position-anchor` + `calc(anchor(top) - 7px)` 等で宣言的に位置を書く。Compositor thread で動くため scroll lag ゼロ・static 時 CPU 0%・JS なし。Chrome 125+ stable ([MDN: Using anchor positioning](https://developer.mozilla.org/en-US/docs/Web/CSS/Guides/Anchor_positioning/Using))。`CSS.supports('anchor-name: --x')` で feature detect し、未対応環境（Firefox 等）は `getBoundingClientRect()` + capture-phase `scroll` listener に fallback。式は frame / label とも **`top` ベースで統一**する（`anchor()` は記述する inset プロパティの座標系で解決されるため、`bottom` 文脈に viewport-top 前提の式を書くとラベルが鏡映位置に飛ぶ。references/overlay-injection.md の仕様メモ参照）
5. **注入は検証して完了とする** — a11y snapshot の `uid` が**非表示クローン**（固定列テーブル等が同内容を複数レンダリングする実装の rect ゼロ側）を指す実例があり、注入が成功してもユーザーには枠が見えない・viewport 左上に縮退する破綻が起きる。注入関数の戻り値 `results` の `ok: true` 各要素の `rect` 非ゼロ確認（下記手順 5。`ok: false` は `rect` を持たず再注入対象）+ スクリーンショット目視（下記手順 6）まで行って初めて完了とする

#### 手順

1. `navigate_page` で対象ルートを開く（`ignoreCache: true`。**SPA 内遷移はリンク/ボタンを `click` で操作し、`navigate_page` でルート遷移しない** — `navigate_page` はフルリロード ([rules/chrome-devtools.md](../../../rules/chrome-devtools.md) 参照) のためクライアント状態と overlay が消える）
2. 操作が必要な該当箇所は、事前に `click` 等で画面に出す（例: ドロップダウンを開く）
   - **（発火条件ありの箇所のみ・手順 2 の直後、手順 3 の前）Force-trigger snippet を注入する**（overlay 注入＝手順 4 の前。本タブで発火させてから以降を進める。② ③ にも同じ発火を注入するのは「条件付き発火」の「構築順・手順への組み込み」bullet が SoT）。**注入後は戻り値で発火成立を確認する**（`ok` を確認し、overflow 系は `hasScroll: true`、その他の発火種別〔hover/focus/error/empty 等〕は snippet が返す状態成立フラグ〔class 付与・対象 DOM 出現等〕を確認。不成立なら再調整・再実行。「条件付き発火」の「発火成立を検証する」bullet 参照）。発火不要な箇所はスキップ
3. `take_snapshot` で要素一覧を取り、Step 2 の**アンカー対象**で特定した要素（検証対象そのもの。「画面上の位置と要素」の見出し等ではない）のテキストから、その箇所の**変更された全要素の `uid` を集める**（代表 1 つでなく Step 2 で列挙した全要素ぶん。フォーム内の全 control 等）。**`take_snapshot` が token 上限で truncate / fail した場合は uid 収集を省略し、トラブルシューティング「`take_snapshot` が token 上限で truncate される / 大規模で取れない」の代替経路（`args: []` + 関数ソース内 `querySelector` / text content match）で手順 4 へ進む。戻り値検証 (手順 5) と screenshot 目視 (手順 6) は代替経路でも同じく必須**
4. `evaluate_script` で overlay を注入する。**経路分岐**: (a) **uid 経路 (主経路)** — 手順 3 で uid を収集できた場合。**`args` にはその箇所の全 uid を並べて渡す**（`args: ["<uid1>", "<uid2>", ...]`。注入関数は `(...els)` で全 uid を受け取り、各要素に枠・最初に解決できた要素にだけ label を付ける）。**label と scroll の代表は `args` で最初に解決成功した uid になる**ため、その箇所を一言で表す主要素（フォームなら見出し直近の最初の control 等）の uid を `args` 先頭に置く。Chrome DevTools MCP は `args` の**全要素**を uid として HTMLElement に resolve するため、label 文字列を `args` に混ぜると `Element uid "..." not found` で失敗する。(b) **代替経路 (truncate 時)** — 手順 3 で snapshot truncate / fail し uid 収集を省略した場合。`args` を渡さず（または空配列で）`evaluate_script` を呼び、注入関数本体に Step 2 で列挙した全変更要素の**可視テキスト**（`label` と同じく関数ソース内の文字列リテラル）と要素特定ロジック（`visibleText` / `innermost` 等、references/overlay-injection.md「Scroll-sync snippet」の要素検索部を参考）を埋め込む。関数内で解決した `HTMLElement[]` に対して、references/overlay-injection.md「evaluate_script に渡す関数」の `makeFrame` ロジックを直接適用して N 枠を付ける（`(...els)` の引数バインドではなく関数内変数に代入する。注入時の `args: []` 経由で `(...els)` に空配列を渡しても等価で、いずれにせよ要素配列は関数内で解決した変数を使う）。`label`（識別子 + 1 行説明、方針 3。箇所ごとに 1 つ）の付与とその要素先頭ルールは uid 経路と同じく代表要素（解決成功した最初の要素）に適用する。**1 注入 = 1 箇所**（タブ構成「構築順」の群単位ループに従い、各箇所の群の①タブで label を書き換えて本手順を繰り返す）。完全な実装は [references/overlay-injection.md](references/overlay-injection.md) の「evaluate_script に渡す関数」（uid 経路）および「snapshot truncate 時の代替経路 wrapper」（代替経路）参照
5. **注入の戻り値を検証する**（方針 5）— 戻り値は `{ ok, label, results: [...] }` で `results` は要素ごとの `{ index, ok, reason?, swapped?, rect, duplicateOf? }`（`rect` は `ok: false` 以外＝新規枠・重複枠の両方が持つ。`ok: false` だけ `rect` なし）。`results` の各要素のうち `ok: false`（reason は経路で異なる: **(a) uid 経路** `zero-rect` = 可視の代替なし (rect 全ゼロの非表示クローン) / `ambiguous` = 同テキストの可視要素が複数で特定不能。 **(b) 代替経路** `not-found` = 関数内 querySelector / text match で要素特定失敗 / `ambiguous` = 同 uid 経路と同じ）のものは経路ごとにリカバリする: (a) **uid 経路** — 対象を画面に出し直す・`take_snapshot` を取り直して別の uid を選ぶ・テキストが一意な要素（値セル等）を選び直す等で**その uid だけ**再注入する。(b) **代替経路 (truncate 時)** — uid が無いため再 snapshot で別 uid を選ぶ経路は使えない。代わりに失敗要素の**可視テキストを一意な近傍テキスト**（値セル・id 風の固有文字列・親要素内ユニークなラベル等）に変更して関数ソース内の literal を書き換える / `querySelector` の selector を CSS 階層で絞り込む（`section[aria-label="..."] > input` 等）/ 対象を画面に出し直して `take_snapshot` の対象 route を縮小して uid 経路へ復帰できないか試す、を**その失敗要素だけ**順に試して部分再注入する。いずれの経路でも成功済みの枠は Cleanup で消さず残す（再注入バッチが前バッチ済みの要素に再解決しても注入関数が `data-manual-verify-anchor-host` 属性で検出し枠を作り直さない＝先行枠を壊さない）。**部分再注入では関数ソースの `label` を `''` にする**（枠のみ。箇所ラベルは初回注入で代表要素に付与済みのため、`label` を残すと再注入バッチの最初の解決成功要素に 2 個目のラベルが付き「箇所ごとに 1 つ」契約に反する。`label=''` だと注入関数末尾の `scrollIntoView` も走らないため、再注入バッチの新規枠へ視点がジャンプせず初回の代表中央位置が保たれる）。`duplicateOf` は別 uid / 別 selector が同じ要素に解決し枠を共有したサインで再注入不要（同一注入内なら先行 index、注入をまたいだ部分再注入なら `null`）。`swapped: true` は uid が非表示クローンを指していたため「同 tagName + 同 textContent の**唯一の**可視要素」へ自動差し替えたサイン — 一意でも意図と別要素の可能性は残るため、手順 6 の目視で差し替え先が意図した要素であることを必ず確認する
6. **`take_screenshot`（`filePath` なしの inline 取得）で全要素の枠とラベルが意図した要素を囲んでいるか目視検証する**。枠が漏れている要素・ずれている枠があれば Cleanup snippet → 原因修正 → 再注入。スクロールが必要な該当箇所は、スクロール後にも追従を確認する

枠・ラベルは reload で消える。**SPA 内遷移 (full reload なし) では body 直下 fixed 要素は残存する**ため、ページ確認後や別ルート確認前に明示削除したいときは references/overlay-injection.md の「Cleanup snippet」を実行する（`data-manual-verify-anchor-frame` / `data-manual-verify-label` / `data-manual-verify-anchor-host` を一括 remove + 元の inline `anchor-name` 復元 + fallback 経路の `scroll`/`resize` listener 解除）。

### Step 5: ウォークスルーをチャットに出力

#### 完了ゲート（省略禁止チェック・必須）

ウォークスルーを出力し「確認できる」「立ち上げた」「完了」と報告する**前に**、以下を全て満たすことを確認する。未達の項目があれば Step 2〜4 に戻る。Step 4 各所の不変条件を完了直前に再点検する集約ゲートで、個々の指示が context 圧縮で薄れても省略が素通りしないための最終関門:

**不変条件違反は宣言で正当化できない（item 5 宣言経路の scope 限定・先読み必須）**: 完了ゲート item 1/3/4（overlay 注入の実機検証・全変更要素の枠・3 タブ群構築 *またはそれと等価の item 4 fallback*）は本 skill の不変条件で、**ユーザーの明示承認なしに**、agent が「規範違反だが明示宣言した上で進める」と書いて完走する経路は**存在しない**（item 4 fallback = sequential / URL 交互案内 / dev skip 時の overlay なし手順は item 4 自体が定義する正常経路で不変条件違反ではない、item 5 (B) で宣言）。下記「正当 skip の扱い」3 種類のいずれにも該当しない違反、特に冒頭「skip 根拠にしない anti-pattern」(8 項目) のいずれかを skip 根拠にしている違反は、item 5 の宣言義務で正当化できない。違反に気づいた時点で**完走せず stop し、状況をユーザーに報告して判断を委ねる**（下記「skip 根拠にしない事例」直後の「不変条件違反時の停止フォーマット」）。**ユーザーが停止フォーマット (b) で明示承認した場合のみ例外的に完走しうる** — 本 skill の通常完走パスではなく、PR 限定の例外対応として宣言の上で続行する形。item 5 の宣言義務は「正当に省いた箇所の宣言」（下記）を黙って簡略化しないための装置であって、agent が anti-pattern を skip 根拠にした不変条件違反を「宣言したから OK」にする装置ではない。

**正当 skip の扱い**: 正当 skip の条件と影響範囲は対応する skip 種別で異なる。

- **第 1 種類: dev 起動機構検出不能 (Step 3「dev 起動機構が project 標準構造のどこからも検出できない場合のみ」= `CLAUDE_SKILL_DEV_COMMAND` 未設定 + `Makefile` / `package.json` scripts / `README.md` / `CONTRIBUTING.md` のいずれにも該当ターゲット無し。重量級 / port 競合可能性 / base worktree 追加は本「検出不能」に含まれない — 詳細は anti-pattern 6/7/8) / ブラウザ自体が起動できない**: item 1/3/4 (overlay 注入・全変更要素の枠・3 タブ群) のすべてを満たせない。**Chrome MCP 接続不能だが dev は起動済みで base/PR URL 交互案内が可能なケースは本第 1 種類ではなく下記第 2 種類 (item 1/3 skip) + item 5 (B) item 4 fallback (URL 交互案内) の組合せで扱う** — overlay 注入 (item 1) と全変更要素の枠 (item 3) は第 2 種類「overlay 不可」と同等で skip、3 タブ群 (item 4) は URL 交互案内が item 5 (B) の正常 fallback として item 4 invariant を満たす
- **第 2 種類: top-layer UI で overlay 不可** / **Chrome MCP 接続不能 (dev 起動済み)** / **`take_snapshot` が truncate / fail し querySelector / text content match の代替経路でも変更要素が 1 つも一意特定できない**（トラブルシューティング「`take_snapshot` が token 上限で truncate される / 大規模で取れない」の代替経路を試行後、`not-found` / `ambiguous` で対象が確定しない場合）: **overlay に依存する item 1/3 のみ skip 可**。**item 4 (3 タブ群) の扱いは sub-case で分岐**: (a) top-layer UI / 全要素特定不能ケースでは Chrome page control があるため item 4 必須 (② base 素 / ③ PR 素のタブで素の描画を切替比較する)、(b) Chrome MCP 接続不能 (dev 起動済み) ケースでは page control が無いため item 4 を item 5 (B) で fallback 宣言する: **distinct URL 同時起動可なら URL 交互案内 (base/PR を URL で交互に開く)、sequential (単一固定ポート / 判定不能) なら単一タブ + branch 切替手順** (どちらも item 4 invariant を満たす正常経路)
- **第 3 種類: 代替経路の部分失敗** (一部の変更要素は特定でき、別の一部は `not-found` / `ambiguous` で特定不能): **item 3 (全変更要素の枠) を部分緩和** — 特定できた要素に枠を付けて注入を継続し、item 5 (A) で「特定できた要素 + 特定不能だった要素 + 試行した代替経路の特定方法」を明示宣言する (item 1/4 は緩和せず、注入そのものと 3 タブ群は引き続き必須)。これにより「部分失敗で全体 skip しない」と「黙って代表絞り込みで済ませない」を区別する境界が item 5 (A) の宣言義務になる (特定不能要素を書き出すことで「枠が無い要素は何で、なぜ無いか」が監査可能になる)

**上記 3 種類のいずれかに該当する場合のみ**、その箇所は item 2 で操作手順を出し、item 5 (A) で skip 内容と理由（試行した代替経路を含む）を必ず宣言する (第 2 種類で item 4 を (B) fallback で代替する場合は (A) + (B) 両方を宣言する)。これにより「正当に省いた箇所の宣言」と「黙って省いたやった体の完了」を区別する。**上記 3 種類のいずれにも該当しない skip は item 5 宣言で正当化できない**（冒頭「不変条件違反は宣言で正当化できない」のとおり stop して報告する）。なお Step 2 で overlay 対象外とした「UI に現れない変更」は該当箇所ではなく、Step 5 末尾の「画面では確認できない項目」として確認手段を添えて列挙する（本 skip の対象外）。

**skip 根拠にしない事例**（本 SKILL.md「省略禁止」直下の anti-pattern と対称。これらを根拠にゲートを「実質クリア」と見なさず、**item 5 宣言で正当化することもできない**。これらが skip 根拠になっている時点で、上記「不変条件違反は宣言で正当化できない」に従い stop して報告する。正当 skip 経路に該当するときのみ skip し、item 5 で内容と理由を宣言する）:

- **「base 環境を立ち上げても壊れていることを確認するだけ」**: 「省略禁止」直下 anti-pattern 1 のとおり、base/PR 比較は改善箇所自体の確認 + 改善以外の regression 防止の両方を担う。base 立ち上げを skip しない
- **「unit test / snapshot test で固定済み」**: 単体 test は live UI 確認の代替にならない。test 通過を理由に live UI 検証を skip しない
- **「`take_snapshot` truncate / token 上限超過で snapshot が取れない」**: uid 経由が使えなくても `evaluate_script` の querySelector 経路で overlay 注入は成立する。代替経路を試すまでは overlay skip の根拠にしない。代替経路（querySelector / text match）を試行してもなお**変更要素が 1 つも一意特定できない**場合は「正当 skip の扱い」第 2 種類 (item 1/3 全 skip; item 4 必須) に該当し item 5 (A) で「試行した代替経路 + 不能理由」を宣言する。**部分失敗 (一部特定可能・一部不能) は「正当 skip の扱い」第 3 種類 (item 3 部分緩和; item 1/4 は緩和せず) に該当**し、特定できた要素で注入を継続しつつ item 5 (A) で「特定できた要素 + 特定不能要素 + 試行方法」を宣言する (黙って代表絞り込みで済ませない)
- **「過去 PR / 類似 PR で確認済み」**: PR ごとに変更要素は異なる。前回の確認は当 PR の代替にならない
- **「backend / schema / 生成物 / internal API のみだから UI 0 件」**: 「省略禁止」直下 anti-pattern 5 のとおり、型・API endpoint・schema・enum・i18n リソース等は app/src 側に consumer が存在し UI として顕在化する。touched ファイル単体での判定は skip 不可で、Step 2「reverse reachability 検証」(UI tree への `grep -rn` reverse lookup) を実施した上で consumer 0 件確認まで「UI 0 件」結論にしない (item 6 で試行内容を宣言)
- **「dev 起動機構が重量級 / Traefik / docker compose 多サービス / Storybook 同時起動が要る」**: 冒頭 anti-pattern 6 のとおり、重さは silent skip 根拠にしない。Step 3 silent skip (「project 標準構造のどこからも検出できない場合のみ」) は dev launcher の**存在検出失敗**専用 (`CLAUDE_SKILL_DEV_COMMAND` / `Makefile` / `package.json` scripts / `README.md` / `CONTRIBUTING.md` の "Getting Started" / "Development" のいずれにも該当ターゲット無し) で、起動コストや setup の重さは含まない
- **「他 worktree との port 競合可能性 / 既存 dev server 稼働中の可能性」**: 冒頭 anti-pattern 7 のとおり、port 競合は silent skip ではなく Step 3 の sequential 切替経路 (トラブルシューティング「base と PR が同一ポートで衝突」)。「可能性」での事前 skip ではなく、(a) host distinct URL 機構ありの case では実起動で `EADDRINUSE` を観測してから sequential に切り替え、(b) 単一固定ポート / 判定不能の case では Step 3 default に従い最初から sequential 採用 (anti-pattern 7 が両 case の判定軸を SoT として定義)。**実際に host 側で distinct な URL を発行する機構** (portless / docker compose で branch ごとに publish port や hostname を変える設定 / branch-based subdomain 等。`docker compose -p <name>` 単独はリソース名空間のみで published port を分離しないため本機構に含めない — 詳細は anti-pattern 7) がある場合は同時起動で 3 タブ群が成立する
- **「base worktree の追加切り出しが必要 / setup 時間がかかる」**: 冒頭 anti-pattern 8 のとおり、base worktree の作成 (`git worktree add .worktrees/base-<slug>`) は Step 3 の標準手順で skip 根拠にならない。worktree 作成や依存 install (`npm ci` 等) が時間を要しても完了まで待つ

**不変条件違反時の停止フォーマット**: 上記 anti-pattern を skip 根拠にしている / 「正当 skip の扱い」に該当しない不変条件違反に気づいたら、完走せず以下の形式でユーザーに報告して判断を仰ぐ（「規範違反だが宣言した上で進める」と書いて完走しない）:

```text
⛔ 完了ゲート違反 (停止して報告):
- 違反項目: <item N の内容>（例: item 4 = 3 タブ群構築未実施）
- 違反理由: <agent が skip しようとした実際の理由>（例: base worktree 切り出しと Traefik + Vite + Storybook 起動が要る）
- 該当 anti-pattern: <冒頭 8 項目のうちどれに該当するか、または「なし」>（例: 6 (dev 重量級) + 8 (base worktree 追加)。8 項目に該当しない違反 (e.g. Chrome MCP の予期しない Connection error / ツールエラー) は「なし」と書く）
- 正当 skip 経路への該当: いいえ
- 次の判断（ユーザー指示待ち）:
  (a) 違反を解消する（worktree 切り出し・dev 起動・3 タブ構築の実施）
  (b) ユーザー明示で本 skip を承認する（本 PR 限定の**例外対応**として、宣言の上で続行する。本 skill の通常完走パスではない）
  (c) skip 経路を SKILL.md の正当 skip として追加する PR を起こす（恒久対応）
```

ユーザー判断 (a)/(b)/(c) のいずれかが得られるまで、ウォークスルー出力 (Step 5 の操作手順以降) には進まない。**ユーザーが (b) を選んで完走を続行する場合**は、本 PR 限定の例外対応であり (A)〜(D) のいずれにも該当しないため、ウォークスルー冒頭に**停止フォーマットの全文 + 「ユーザー承認済み (本 PR 限定例外、(A)〜(D) 外)」の追記**を必ず転記する (item 5 (A) には書かない — (A) は正当 skip 3 種類専用で scope 限定済み。(b) 例外は監査可能性のため別チャネルで明示する)。

1. **実在検証**: overlay 注入を実施した該当箇所の枠・ラベルを**実際にライブ画面へ注入し**、戻り値の `rect` 非ゼロ確認 + `take_screenshot`（inline）で意図した要素を囲んでいることを目視した（Step 4 手順 5・6、設計方針 5）。コードを書いた / 注入したつもり / 戻り値が `ok: true` だけで完了にしない。**注入・立ち上げを実機で確認していない状態で『やった』と報告しない**。**発火条件ありの箇所は、群内 3 タブすべてで Force-trigger の発火成立（`ok` + 発火種別ごとの成立指標〔overflow 系は `hasScroll`、その他は snippet の状態成立フラグ〕）を確認した**（Step 4「条件付き発火」の「発火成立を検証する」。① だけ発火・②③ default の取りこぼしを防ぐ）
2. **全該当箇所**: Step 2 で列挙した UI 該当箇所を 1 つも飛ばさず処理した（注入した箇所は item 1/3 で検証済み、正当 skip の箇所は操作手順を出して item 5 (A) で skip 明記）
3. **全変更要素の枠**: overlay 注入を実施した各該当箇所で Step 2 のアンカー対象（**変更された全要素**）に枠が付いている（代表 1 つで済ませない）。繰り返し要素を代表数個に絞ったときのみラベルに「ほか N 件同種」と明記し、**操作手順でも全件が対象である旨を書いた**（Step 2）
4. **3 タブ群**: base/PR 同時起動可能かつ Chrome MCP も使える構成では、該当箇所ごとの専用 3 タブ群（① PR赤枠 / ② base素 / ③ PR素）を**全箇所ぶん**構築した（タブを共有して開き替えない。N 箇所 → 3 × N タブ）。3 タブ群非構築のフォールバックは Step 5「3 タブ群非構築時」の分岐に揃える: sequential（Step 3 default = 単一固定ポート / 判定不能）は単一タブ + 切替手順、別 URL 同時起動可だが Chrome MCP 接続不能は base/PR URL 交互案内、dev skip でブラウザ自体が無い場合は構築不要 (overlay なし手順)。いずれも item 5 (B) で fallback 宣言 (dev skip case は第 1 種類正当 skip でもあるため item 5 (A) + (B) 両方宣言)
5. **省略・加工は宣言**（scope 限定）: 以下 (A)〜(D) の省略・加工を行った場合は、その内容と理由をウォークスルーに明記した（黙って簡略化・加工しない）。**「正当 skip の扱い」に該当しない不変条件違反**（anti-pattern 6/7/8 等を根拠にした 3 タブ群構築・overlay 注入 skip など）**は本宣言経路で正当化できない**（冒頭「不変条件違反は宣言で正当化できない」のとおり「不変条件違反時の停止フォーマット」で停止して報告する。完走前提で本項目に書かない）:
   - (A) **「正当 skip の扱い」3 種類に該当する省略** — 第 1 種類 (dev 起動機構検出不能 / ブラウザ自体が起動できない) / 第 2 種類 (top-layer UI での overlay skip・Chrome MCP 接続不能 (dev 起動済み) による overlay skip・代替経路試行後も全要素特定不能による overlay skip) / 第 3 種類 (代替経路の部分失敗による item 3 部分緩和)
   - (B) **item 4 が要求するフォールバック宣言** — sequential 起動（Step 3 default = 単一固定ポート / 判定不能）の単一タブ + 切替手順、別 URL 同時起動可だが Chrome MCP 接続不能時の base/PR URL 交互案内、dev skip でブラウザ自体が無い場合の overlay なし手順。**不変条件違反ではないが item 4 が宣言を要求する正常経路**で、「正当 skip の扱い」3 種類とは別カテゴリ
   - (C) **視認性のための代表絞り込み** — Step 2「変更要素が多すぎて全枠が画面を埋める場合」の代表数個絞り込み (ラベルに「ほか N 件同種」明記)。**overlay 注入は継続している正常運用 + 宣言義務**で、3 種類 skip でも item 4 fallback でもない独立カテゴリ
   - (D) **検証用強制発火** — Step 4「条件付き発火」で群内 3 タブを自然状態と異なる発火状態にした加工
6. **reverse reachability 検証**: schema 系 (backend / 生成物 / internal API / enum/const 定義 / i18n リソース) を含む diff では UI 該当箇所の有無にかかわらず、Step 2「reverse reachability 検証」を実施し、diff の公開シンボル (型名・endpoint path・schema 名・i18n key 等) を UI tree (`app/src/` / `src/` / `frontend/` 等の project 標準構造) に reverse lookup した。consumer が見つかれば画面到達経路を全て列挙して item 2/3/4 の対象に含めた (UI 既特定済みでも別画面 consumer をマージする)。**reverse lookup 試行を skip して「UI 0 件」または「UI 既特定済みだから不要」と報告しない**。試行内容 (検索した symbol + 検索対象 tree) を本項目 (item 6) 内で宣言した。**skip 例外** (Step 2「reverse lookup を skip してよい条件」該当時): 試行内容の代わりに「reverse lookup 不要 — `<該当条件>`」を本項目内で宣言した (例: 「reverse lookup 不要 — pure docs のみ」「reverse lookup 不要 — pure UI 変更で schema 系不在、UI 該当箇所を diff から直接特定」)

該当箇所ごとに操作手順・確認ポイントを書く（Step 4 を実施した箇所は枠とラベルがライブ画面に注入済み。dev/Chrome を skip した箇所は overlay なしで操作手順のみ）。案内の形式は構成で分岐する:

- **3 タブ群構築時（主経路）**: 冒頭に**全該当箇所のタブ対応表**（箇所ごとに群内① PR赤枠 / ② base素 / ③ PR素 の絶対タブ番号）を出す。各該当箇所の手順はその群の**絶対タブ番号で案内**する（①に対応する絶対タブ番号の赤枠で位置確認、②・③に対応する絶対タブ番号を切替えて素の描画を比較 — 例: 2 群目なら「tab 4 で位置確認、tab 5 ⇄ 6 で比較」。①②③ の群内番号だけで案内しない。dev 再起動・branch 切替の案内は書かない）。各箇所は専用群に固定済みのため**箇所間の再同期は不要**で、人間はタブを切り替えるだけでよい。到達操作（タブ構成の節参照。PR 新規 UI のトリガーは①・③のみ）は対象が存在するタブで実施済みの状態で渡し、その旨をウォークスルーに明記する。人間に残すのは挙動そのものが確認対象の操作のみで、その場合は同じ操作を**対象が存在する各タブ**（通常は②・③の双方、対象が PR 新規なら③のみ）で実施するよう操作手順に明記する
- **3 タブ群非構築時**: 構成で 2 分岐: **(i) distinct URL ありだが Chrome DevTools MCP 接続不能** → base URL と PR URL を**交互（base ⇄ PR）**に並べる (複数箇所あれば箇所ごとに base/PR を対で並べる)。**(ii) sequential** (Step 3 default = 単一固定ポート / 判定不能) → 単一 URL に対して base branch と PR branch の**切替手順** (`git checkout` → dev 再起動 → 確認 → branch 切替 → 再起動 → 比較) を箇所ごとに案内する (URL は同一なので URL 交互は不要)

操作手順は **画面に実際に表示されているテキストに言及**して、どこの何をどう操作するかを具体的に書く（「右上の」「〜カード内の」等の位置 + 実テキスト）。

```text
## 動作確認ウォークスルー (PR #42)

（同時起動で 3 タブ群を構築した場合は冒頭に全該当箇所のタブ対応表を出す。N 箇所 → 3 × N タブ）
| 該当箇所 | ① PR赤枠 | ② base素 | ③ PR素 |
|---|---|---|---|
| 1: 設定ページ「通知設定」 | tab 1 | tab 2 | tab 3 |
| 2: 一覧ページ「ステータス」列 | tab 4 | tab 5 | tab 6 |

各群とも ①②③ は対象位置までスクロール済み・到達操作は対象が存在するタブで実施済み（PR 新規 UI のトリガーは①・③のみ、base に無いものは②で skip）。② ⇄ ③ を切替えて素の描画を比較する。

### 該当箇所 1: 設定ページの「通知設定」セクション
（3 タブ群構築時 — こちらを主経路として出力。dev 再起動・branch 切替の案内は書かない）
- tab 1 で赤枠の位置を確認 → tab 2 ⇄ 3 を切替えて比較（到達操作は実施済み。挙動確認の操作は下の操作手順を対象が存在するタブで実施）
（sequential 時・同 URL — 3 タブ群非構築の場合のみ）
- base / PR: http://localhost:3000/settings  ← base を確認 → PR 側（PR 番号モードは `.worktrees/pr-<番号>`、no-PR モードはメイン checkout）に切替えて dev 再起動し同 URL を再確認
（別 URL があるが 3 タブ群非構築 — Chrome DevTools MCP 接続不能等 — の場合のみ）
- 別 URL で交互表示: base http://localhost:3000/settings ⇄ PR http://localhost:3001/settings

（Step 4 実施時は枠とラベルがライブ画面に注入済み。skip 時は overlay なし — 下の操作手順で位置を確認する）

操作手順:
1. 見出し「通知設定」の下にあるトグル「メール通知を受け取る」を探す（赤枠の箇所・対象位置までスクロール済み）
2. トグルをクリックして ON にする（トグルは PR 側のみ — tab 3 で実施。tab 2 は文言のみであることを確認）
確認ポイント: base ではトグルが無く文言のみ → PR ではトグルが表示され、ON で「保存しました」が出る

### 該当箇所 2: 一覧ページの「ステータス」列
（箇所 1 と同型: 3 タブ群構築時は専用群 tab 4/5/6 の絶対タブ番号で案内、3 タブ群非構築時のみ base ⇄ PR の URL 交互表示）
...
```

最後に、画面で確認できない変更があれば「画面では確認できない項目」として列挙する（確認手段を 1 行添える）。

### Step 6: クリーンアップ

- 本スキルが起動した dev server プロセスを停止する（既に起動済みのものは触らない）
- 本スキルが作成した worktree（PR 用 / base 用）は、確認が終わったら停止後に削除コマンドを案内する（自動削除はせず、ユーザーが後続作業に使う可能性があるため。worktree 削除前に CWD をメインリポジトリへ戻す）
- ライブ画面に注入した枠・ラベル・`anchor-name`、および条件付き発火で注入した検証用 `<style>`（`data-manual-verify-force-trigger`）は reload で消える（SPA 内遷移では残存しうるため、必要に応じて references/overlay-injection.md の「Cleanup snippet」を実行 — force-trigger style も同 snippet で除去される）

## 環境変数（任意）

project の `.claude/settings.json` の `env` で dev 起動を明示できる（未設定でも auto-detect で動作する）:

| 環境変数 | 説明 |
|----------|------|
| `CLAUDE_SKILL_DEV_COMMAND` | dev サーバー起動コマンド |
| `CLAUDE_SKILL_DEV_PORT` | dev サーバーのポート番号 |

## トラブルシューティング

| 問題 | 対処 |
|------|------|
| diff が backend schema / 生成物のみで「UI 0 件」と判定しそう | 型・endpoint・swagger / orval 生成物は app/src 側に consumer がある可能性が高い。Step 2「reverse reachability 検証」で公開シンボルを `grep -rn` し、consumer から画面到達経路を辿る。「生成物だから UI 無関係」は anti-pattern (省略禁止 5) |
| dev 起動機構が見つからない | 完了ゲート「正当 skip の扱い」**第 1 種類** (dev 起動機構検出不能) に該当。環境起動を skip し、該当箇所・操作手順のみ出力する。`CLAUDE_SKILL_DEV_COMMAND` の設定を案内。**item 5 (A) で「第 1 種類: dev 起動機構検出不能」 + item 5 (B) で「item 4 構築不要 (overlay なし手順)」の両方を宣言する** (第 2 種類と同型で、第 1 種類でも (A) + (B) 両方の宣言を要求して監査経路を統一する) |
| base と PR が同一ポートで衝突 | sequential に切替え、URL は同一・branch 切替手順を併記 |
| Chrome DevTools MCP に接続できない | ブラウザ起動・MCP server 有効を確認 (server 未有効・profile 未設定が原因なら設定して再試行)。確認・設定後も接続不能で**再現する**ケースで分岐: **(i) dev 起動機構検出不能 / ブラウザ自体起動不能 (第 1 種類条件) → 第 1 種類** (item 1/3/4 全 skip; item 5 (A) で「第 1 種類」 + item 5 (B) で「item 4 構築不要 (overlay なし手順)」の両方を宣言)、**(ii) dev 起動済み + MCP のみ接続不能で base/PR URL 同時起動 (distinct URL) 可 → 第 2 種類 (item 1/3 skip) + item 5 (B) URL 交互案内 fallback** (item 5 (A) で「第 2 種類: Chrome MCP 接続不能」 + item 5 (B) で「URL 交互案内」の両方を宣言)、**(iii) dev 起動済み + sequential (単一固定ポート / 判定不能) → 第 2 種類 + item 5 (B) 単一タブ + branch 切替** (item 5 (A) で「第 2 種類」 + item 5 (B) で「sequential 単一タブ + 切替手順」の両方を宣言)。一過性のツールエラー (retry で解消する想定外障害) は「正当 skip 経路ではなく**不変条件違反時の停止フォーマット**」(該当 anti-pattern: なし) で停止しユーザー判断を仰ぐ。**起動機構ありだが Step 3 未実施 / 途中放棄 で dev 未起動の場合**は anti-pattern 6/7/8 経由の不変条件違反であり、第 1 種類正当 skip ではなく**停止フォーマット**へ倒す |
| 対象要素が特定できない | `take_snapshot` の一覧に該当 `uid` が無い。**まず snapshot 全体が truncate / fail しているか確認** — truncate ならこの行ではなく次行の「`take_snapshot` が token 上限で truncate される / 大規模で取れない」に従う（操作後再 snapshot ループでは token 上限問題は解消しない）。truncate でなく単に対象 uid が snapshot に含まれていないだけなら、操作（ドロップダウン展開等）後に再 snapshot する |
| `take_snapshot` が token 上限で truncate される / 大規模で取れない | snapshot は a11y tree 全体を返すため、要素数が多い画面（数百行のテーブル等）では MCP の token 上限を超えて truncate / fail することがある。これは **uid 経由経路の失敗**であって overlay 注入そのものの不能ではない。代替経路: (1) `evaluate_script` を **`args` を渡さず（または空配列 `args: []` で）** 呼び、注入関数本体に Step 2 で列挙した全変更要素の**可視テキスト** を関数ソース内の文字列 literal として埋め込んで `document.querySelector` / `document.querySelectorAll` / text content match で**全変更要素それぞれ**を取得し、関数内で解決した `HTMLElement[]` に対して references/overlay-injection.md「evaluate_script に渡す関数」の `makeFrame` ロジックを直接適用して N 枠を付ける（注入関数の `(...els)` パラメータには空配列がバインドされるため、要素配列は関数内変数として保持する。代表 1 つで済ませず Step 2 列挙の全要素を解決すること — 同じ snapshot の uid 経路と同じく完了ゲート item 3「全変更要素の枠」を満たす）。要素特定ロジック（可視テキストフィルタ + innermost match）は references/overlay-injection.md「Scroll-sync snippet」の `visibleText` / `matches` / `innermost` 構造が参考実装になる（Scroll-sync snippet 自体は scroll 同期専用で overlay 注入は行わない — 流用するのは要素検索部のみで、overlay 注入の枠生成 (`makeFrame`) は注入関数側）。**部分失敗（第 3 種類）が許容される条件**: 代替経路で要素特定ロジックを試行しても**一部の要素が `not-found` / `ambiguous` で一意特定できない**ケースに限り、特定できた要素で注入を継続してよい。この場合は完了ゲートの「正当 skip の扱い」第 3 種類 (item 3 部分緩和; item 1/4 は緩和せず) に該当し、item 5 (A) で「試行した特定方法 + 特定不能だった要素 + 部分緩和内容」を宣言する (最初から代表絞り込みで済ませてよいわけではない。視認性のための代表絞り込みは別カテゴリで item 5 (C) で宣言する)。(2) 対象を画面に出した状態で `take_snapshot` の対象 route を絞れる場合は、操作で UI tree を縮小してから取り直す。**「snapshot が取れないから overlay を簡略化」は本 SKILL.md 冒頭「省略禁止」の skip 根拠にしない anti-pattern。代替経路 (1)/(2) を試行した上で**変更要素が 1 つも一意特定できない**場合は「正当 skip の扱い」第 2 種類 (item 1/3 全 skip; item 4 必須) に該当**（item 5 (A) で試行内容と不能理由を宣言） |
| `evaluate_script` が `Element uid "ⓐ ..." not found` で失敗する | label 文字列を `args` に渡している（`args` の全要素は uid として解決される）。`args` は uid のみにし、label は関数ソースに埋め込む（Step 4 手順 4） |
| 枠が viewport 左上に小さく縮退する / 対象と無関係な場所に出る | uid が rect ゼロの非表示クローン（固定列テーブル等の複製レンダリング）を指している。注入関数の可視差し替えと戻り値 `results[i].rect` の非ゼロ確認（Step 4 手順 5）で検出する |
| ラベルが対象から大きく離れた位置（鏡映位置）に出る | `bottom` 文脈の `anchor()` に viewport-top 前提の式を書いている。frame / label とも `top` ベースの式に統一する（設計方針 4・references/overlay-injection.md） |
| タブ切替・再レンダリングで枠が消えない / 迷子になる | 対象 DOM の unmount または非表示化で anchor が解決できない（rect fallback はゼロ rect 時に display トグルで自動退避するが、anchor 経路は対象消失に自動追従しない）。Cleanup snippet → 対象を画面に出し直して再 snapshot → 再注入する |
| 枠の上辺だけが切れる | 対象要素に `outline` / `border` を直当てしている。Step 4 設計方針 1 違反。`document.body` 直下の overlay div + CSS Anchor Positioning に切替える (references/overlay-injection.md) |
| ラベルが既存 UI に重なってボタンが押せない | overlay 要素に `pointer-events: none` が欠落。設計方針 2 を満たすこと |
| スクロール時に枠の追従が遅れる / カクつく | `scroll` event listener / `requestAnimationFrame` loop は main thread のため lag が出る。CSS Anchor Positioning に切替える (設計方針 4)。未対応環境では rect fallback を使う |
| ブラウザの「戻る」/ reload で群内①の枠が消えた | full reload・履歴遷移で overlay は消える仕様。`select_page` で該当群の①を選択 → 対象 route を `navigate_page` → overlay を再注入する |
| 群内②・③をスクロールできない（`window.scrollTo` 後も `scrollY` が 0 のまま） | アプリが window でなく内部コンテナをスクロールする構造（実機で発生）。対象要素への `scrollIntoView({ block: 'center', behavior: 'instant' })` はどの祖先がスクロールするかに依らず機能する。位置検証も `scrollY` でなく対象 box 中央の viewport Y の群内タブ間比較で行う（タブ構成「スクロール位置の同期」/ references/overlay-injection.md「Scroll-sync snippet」） |
| 群内①の赤枠が snippet の中央寄せ先と別要素を囲んで見える | ①の uid が同テキスト入れ子の wrapper（`<a><span>…</span></a>` 等）を指し、snippet は最内可視要素を選ぶため。ズレが気になる場合は①の注入対象を同テキストの最内可視要素の uid に選び直して再注入する |
| 赤枠が画面見出し（ページタイトル）だけを囲み検証対象を指していない | アンカーが「どの画面か」を示す見出しに乗っている。Step 2「アンカー対象」に従い、変更を実際に検証する要素（出力不変の変更なら描画を代表するデータ行・値セル）へ注入し直す |
| 同じ画面の一部の変更要素にしか枠が付いていない | 代表 1 つの uid しか `args` に渡していない。Step 2 で箇所の変更要素を全列挙し、Step 4 手順 4 で全 uid を `args` に並べて 1 回で注入する。戻り値 `results` の `ok: false` 要素は選び直して再注入（Step 4 手順 5） |
| 対象が native `<dialog>.showModal()` / popover 内にある (top-layer UI) | `document.body` 直下の `position: fixed` overlay は top-layer の下に描画されるため `z-index` に関わらず frame/label が隠れる ([MDN: top-layer](https://developer.mozilla.org/en-US/docs/Glossary/Top_layer))。Step 5 のテキスト手順で位置を案内し、**overlay 注入 (枠/ラベル) のみ skip** する旨を明記する。**3 タブ群 (item 4) は base/PR URL + Chrome page control があれば成立するため引き続き必須** (② base 素 / ③ PR 素のタブで素の描画を切替比較する経路は残る。完了ゲート「正当 skip の扱い」第 2 種類 (top-layer UI / 全要素特定不能) 参照) |
| 群内②・③で確認対象が画面に出ていない（モーダルが閉じたまま等） | 到達操作の揃え漏れ。対象が存在する各タブを `select_page` → ①と同じ到達操作を再現して画面状態を揃える（PR 新規 UI のトリガーは①・③に存在し②には無いため、素タブで再現が要るのは③のみ。Step 4 タブ構成の節参照） |
| 到達操作で見える content（SelectBox 候補・popover・モーダル/ダイアログの中身等）が比較対象なのに、比較タブ（②・③）で閉じたまま / 結果表が未描画で渡している | 到達操作の再現漏れ（多段の場合はモーダルを開く→入力で結果表を描画まで）。「別途人間操作で」と丸投げせず、到達後の content をアンカー対象にして**対象が存在する比較タブ**（通常②・③、PR 新規 UI は③のみ）を同じ到達状態で揃える（Step 4「到達 content が比較対象」bullet・Step 2「確認に必要な操作」） |
| フォーム入力で描画される比較対象（差分表等）が `evaluate_script` での値代入 + 合成 `input` / `change` event でも出ない | controlled React（react-hook-form の `register` 等）が DOM 値の直接代入だけでは `watch` の form state を更新しないため。React 互換の native setter（要素種別に応じた prototype〔`HTMLInputElement` / `HTMLTextAreaElement` / `HTMLSelectElement`〕から `value`〔checkbox・radio は `checked`〕の descriptor を `Object.getOwnPropertyDescriptor(...).set` で取得して値設定 → `input` / `change` を dispatch）を試し、不能なら**非破壊**の実 React ハンドラ操作で同等の差分を起こす。行削除等の破壊的・不可逆に状態を変える操作は base/PR の比較可能性を壊すため使わない。いずれも不能なら当該 sub-state のみ Step 5 の人間手順に委ね、その旨を宣言する（黙って未描画のまま渡さない） |
| 変更したスタイルの差が default 画面では見えない（スクロールバー余白・hover/focus・error/empty 状態等） | 効果が default では発火しない変更。Step 4「条件付き発火」で群内 3 タブに同一の発火（overflow を `max-width` で強制・擬似状態の付与・既定で不可視な指標の可視化）を注入し、比較対象プロパティには触れない。実装は references/overlay-injection.md「Force-trigger snippet」、Step 5 で検証用強制発火を宣言する |
| UI に現れない変更 | 「画面では確認できない項目」として確認手段を添えて列挙する |
