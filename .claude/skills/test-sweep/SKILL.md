---
name: test-sweep
argument-hint: "[--staged | --worktree | BASE_BRANCH]"
description: "Reviews newly added test code in a git diff against rules/test-bloat-defense.md rules. Detects tests that fail the 3-point proof responsibility (which regression to prevent / existing coverage gap / true-positive == real bug) and reduction candidates (duplicate / type-only assertion / mock-only / empty snapshot / happy-path 重複 / assertion-less). Default scans the diff between the default branch (origin/HEAD) and HEAD for PR readiness. '--staged' scans the index, '--worktree' scans tracked uncommitted changes, BASE_BRANCH overrides the base ref. Auto-skips when the diff contains no test files or when base..HEAD is pure-revert / a tiny-json-hotfix. Use BEFORE 'gh pr create', or when the user mentions テストsweep / test review / 余計なテスト / テスト多すぎ / test bloat."
---

# test-sweep

PR / staged / worktree diff の **新規追加 test ブロック**を [rules/test-bloat-defense.md](../../../rules/test-bloat-defense.md) の規範に照らして判定し、違反箇所を報告して修正まで導く leaf skill ([rules/skills.md](../../../rules/skills.md))。`/comment-sweep` / `/co-evolve-check` / `/extension-bloat-sweep` と同型の pre-PR sweep。

## いつ使うか

- **PR 作成前 (推奨)**: `gh pr create` を実行する**前**。`/comment-sweep` と並走で呼ぶ
- **既存 PR への追加 push 前**: review 対応や bug fix の差分にも適用 (commit 後・push 前に default モードで)
- **ユーザーから「テストが多すぎ」「test sweep」「余計なテスト」等の指摘を受けた直後**
- **PR を作らない一時的な変更でも**: commit 前に `--staged` または `--worktree` モードで動かしてよい

## 引数モード

| 引数 | 対象 diff | 用途 |
|------|----------|------|
| (なし) | `git diff origin/<HEAD-branch>...HEAD` (HEAD-branch は `origin/HEAD` の symbolic-ref から決定) | PR 作成前の最終 sweep |
| `BASE_BRANCH` (`--` で始まらない任意 1 引数) | `git diff origin/<BASE_BRANCH>...HEAD` | base を明示する場合 (リモート tracking ref を使う) |
| `--staged` | `git diff --cached` (index) | commit 前 sweep |
| `--worktree` | `git diff HEAD` (tracked かつ uncommitted。**untracked は含まない**) | 未 commit の tracked 変更を全部含めたい時 |

複数指定不可。`--worktree` で untracked な新規ファイルも対象にしたい場合は事前に `git add -N <path>` で intent-to-add してから呼ぶ。

## 手順

```text
Sweep Progress:
- [ ] Step 1: モード判定と diff 取得
- [ ] Step 1.5: Lightweight-PR + test ファイル不在の auto-skip
- [ ] Step 2: 新規追加 test ブロックの抽出
- [ ] Step 3: 各ブロックを規範で判定
- [ ] Step 4: 違反テーブルをユーザーに提示
- [ ] Step 5: ユーザー承認後 Edit で修正
- [ ] Step 6: 再 sweep で残違反ゼロを確認
```

### Step 1: モード判定と diff 取得

引数を解釈してモードを決定。default モード (引数なし) の base は **`origin/HEAD` (デフォルトブランチ)** を使う。feature branch の upstream を base にすると `git diff origin/feat/x...HEAD` が空になり sweep が false-negative で通ってしまうため、必ず `origin/HEAD` 由来で決定する。

```bash
git symbolic-ref refs/remotes/origin/HEAD --short
```

これが `origin/main` 等を返したら、その branch を base として `...` (triple-dot) diff を取る:

```bash
git diff origin/main...HEAD
```

`origin/HEAD` が未設定で symbolic-ref が失敗する場合は `BASE_BRANCH` 引数を要求してユーザーに案内する (`git remote set-head origin -a` で再設定可能)。`--staged` / `--worktree` / `BASE_BRANCH` の場合はこの計算をスキップして対応コマンドを直接実行する。`BASE_BRANCH` 引数モードでは `git diff origin/<BASE_BRANCH>...HEAD` を実行する。

### Step 1.5: Lightweight diff + test ファイル不在の auto-skip

#### Lightweight diff の検出 (default / BASE_BRANCH モードのみ)

新規追加コメントが構造的に存在しない diff (純粋な revert PR や `.claude/` 配下の JSON scalar 値置換等) は新規 authored test も構造的に存在しないため auto-skip する。判定は `/comment-sweep` / `/co-evolve-check` 等と共通の helper に委譲する:

```bash
python3 -I .claude/skills/_shared/pr-skip-policy.py --base <base-ref> --head HEAD --json
```

`<base-ref>` は Step 1 で `git diff <base-ref>...HEAD` に使った base ref そのもの (default は `origin/main` 等、`BASE_BRANCH` モードは `origin/<BASE_BRANCH>`)。`origin/` は二重に付けない。

出力 JSON の `profile` で分岐:

- `pure-revert` → `✅ Revert-only diff (skipped)` を出力して終了 (base..HEAD の全 commit subject が `Revert "` で始まる)
- `tiny-json-hotfix` → `✅ Lightweight PR (tiny-json-hotfix, skipped)` を出力して終了 (`.claude/` 配下の単一 JSON scalar 値置換等の構造的軽量 diff)
- `none` → 次の test ファイル不在チェックへ進む

helper が exit code 0 以外を返した場合は通常フローに倒し次へ進む。

#### test ファイル不在 (全モード)

diff の `--stat` 出力 (default は `git diff --stat origin/main...HEAD`、各モード相当) から変更ファイル名を抽出し、test ファイル pattern に該当するものが**ゼロ件**なら以下を出力して終了:

```text
✅ No test files in diff (skipped)
```

test ファイル auto-detect pattern:

| 言語 | pattern |
|------|---------|
| TS/JS | `*.test.ts` / `*.test.tsx` / `*.test.js` / `*.test.jsx` / `*.spec.ts` / `*.spec.tsx` / `*.spec.js` / `*.spec.jsx` / path に `__tests__/` を含む |
| Python | `test_*.py` / `*_test.py` / path が `tests/` 配下 |
| Go | `*_test.go` |
| Rust | path が `tests/` 配下 (`src/` 配下で `#[cfg(test)]` 修飾子付きの inline test module は `git diff --stat` がファイル名しか出さないため判定対象外。意図的な false-negative として受容) |
| Java | `*Test.java` / `*Tests.java` / `*IT.java` / path が `src/test/` 配下 |
| Ruby | `*_spec.rb` / `*_test.rb` / path が `spec/` または `test/` 配下 |
| Scala | `*Spec.scala` / `*Test.scala` |
| C# | `*Tests.cs` / `*Test.cs` |
| Elixir | `*_test.exs` / path が `test/` 配下 |

### Step 2: 新規追加 test ブロックの抽出

**生成ファイルの除外 (抽出前)**: 自動生成ファイルは sweep 対象外。呼び出しモードに対応する検出 CLI を実行し、出力 JSON の `generated[].path` を以降の対象から外す。`<base-ref>` は Step 1.5 と同じ semantics (`origin/main` 等。`origin/` を二重に付けない):

| モード | コマンド |
|--------|---------|
| default / `BASE_BRANCH` | `bun --config=/dev/null .claude/skills/_shared/detect-generated-local.ts --range <base-ref>...HEAD` |
| `--staged` | `bun --config=/dev/null .claude/skills/_shared/detect-generated-local.ts --staged` |
| `--worktree` | `bun --config=/dev/null .claude/skills/_shared/detect-generated-local.ts --worktree` |

diff 出力から **新規追加された 1 test ブロック**を抽出する。判定単位は「test 関数全体が `+` 行で追加されたもの」。既存 test 内の assertion 追加 (関数自体は既存) は対象外。

言語別の test ブロック検出 pattern:

| 言語 | test ブロック pattern |
|------|---------------------|
| TS/JS (Jest/Vitest/Mocha) | `it('...', () => { ... })` / `test('...', () => { ... })` / `it.each(...)('...', ...)` / `test.each(...)('...', ...)` / `` test.each`...`('...', ...) `` (template literal tagged 形式) / chained modifiers (`it.only` / `it.skip` / `it.concurrent` / `test.only` / `test.skip` / `test.concurrent`) / **modifier と `.each` の組み合わせ** (`test.only.each(...)` / `` it.skip.each`...`(...) `` / `it.concurrent.only.each(...)` 等、任意の順序・段数の chain) (parametric 集約は 1 test ブロック扱いで `REDUCTION_CANDIDATE_HAPPY_PATH_DUP` 具体例節の推奨形と整合)。`describe(...)` / `describe.each(...)` は test suite ラッパーであり test ブロック単位ではない (内包する `it` / `test` を個別に判定するための grouping のみ) |
| Python (unittest/pytest) | `(async )?def test_*(...)` / `class Test*(unittest.TestCase)` 内の `(async )?def test_*` (pytest-asyncio の `async def test_*` を含む) |
| Go | `func Test*(t *testing.T) { ... }` (既存 `func Test*` 内に追加された table-driven entry や `t.Run(...)` subtest は「test 関数自体は既存」のため Step 2 の除外ルールに従い対象外。新規 `func Test*` 全体が `+` 行で追加された場合のみ抽出) |
| Rust | `#[test]` / `#[tokio::test]` / `#[async_std::test]` / `#[test_log::test]` 等の test 属性 (attribute) 直後の `fn *() { ... }` (function 名 prefix は強制しない) |
| Java (JUnit) | `@Test` / `@ParameterizedTest` / `@RepeatedTest` 等の annotation 直後の method 定義 |
| Ruby (RSpec/Minitest) | `it '...' do ... end` (RSpec) / `test "..." do ... end` (Minitest DSL) / `def test_*` (Minitest xUnit-like) |
| Scala (ScalaTest) | `it should "..." in { ... }` / `"..." in { ... }` |
| C# (xUnit/NUnit/MSTest) | `[Fact]` / `[Theory]` / `[Test]` / `[TestMethod]` 等の test 属性直後の method 定義。新規 method 全体が `+` 行で追加された場合のみ抽出 |
| Elixir (ExUnit) | `test "..." do ... end` |

判定対象から除外:

- 既存 test に assertion を追加するだけ (test 関数自体は既存)
- linter / formatter directive
- test helper 関数の定義 (test ブロックではない)
- **test suite ラッパー** (`describe(...)` / `describe.each(...)` / RSpec `context '...' do` / `xdescribe` 等): 内包する `it` / `test` を個別判定するための grouping。ラッパー自体は test ブロック単位ではないため判定対象から除外
- skill 自身の test fixture (この skill の判定パターン例を test に書いている等、メタ的な例外)

### Step 3: 各ブロックを規範で判定

[../../../rules/test-bloat-defense.md](../../../rules/test-bloat-defense.md) の規範に従い、該当する**最も重い違反 1 件**を採用:

| カテゴリ | 検出基準 |
|---|---|
| `NEEDS_JUSTIFICATION` | 新規追加 test ブロックで「証明責任 3 項目」(防ぐ regression / 既存未 cover の理由 / 落ちた時の意味) の**いずれか 1 つでも明示されていない** (test 内コメント / PR description / commit message を照合)。3 項目 AND を要求するため、欠落 1 つでも本カテゴリで flag する |
| `REDUCTION_CANDIDATE_DUPLICATE` | 同 PR 内の他 test と同じ振る舞いを別表現で確認 |
| `REDUCTION_CANDIDATE_TYPE_ONLY` | assertion が型チェック / 存在チェックのみ (例: `expect(typeof foo).toBe('function')` / `assert isinstance(x, dict)`) |
| `REDUCTION_CANDIDATE_MOCK_ONLY` | mock の戻り値を assert しているだけで production code を呼んでいない |
| `REDUCTION_CANDIDATE_EMPTY_SNAPSHOT` | snapshot のみで explicit assert なし |
| `REDUCTION_CANDIDATE_HAPPY_PATH_DUP` | 同じロジックの正常系を**個別の test ブロック**で 3 通り以上重複してテスト。**例外**: 1 test ブロック内の parametric 集約 (`it.each` / `test.each` / `describe.each` / Python `@pytest.mark.parametrize` / Go table-driven の `t.Run`-内ループ / Rust `rstest` の `#[case]` 等) は本カテゴリの対象外で `NO_VIOLATION` |
| `REDUCTION_CANDIDATE_ASSERTION_LESS` | 何も assert していない / 常に成功する自明な assertion (例: `assert True` / `expect(1).toBe(1)`) でカバレッジを稼ぐだけ (fake test、reward hacking 経路) |
| `NO_VIOLATION` | 例外規定 (security / correctness regression / flaky 抑止 / ユーザー明示要請) に該当 or 証明責任を満たしている |

判定にあたって周辺コード (test 内の assertion / 既存 test ファイル全体) が必要なケースは Read で確認する。

### Step 4: 違反テーブルをユーザーに提示

結果は markdown 表形式で。違反ゼロなら「✅ Test sweep clean」のみ報告して終了。Step 2 で生成ファイルを除外した場合は、表の後に「除外した生成ファイル: N 件 (`path1`, `path2`, ...)」を 1 行で注記する。

```markdown
## Test sweep 結果

| # | file:line | カテゴリ | 抜粋 | 提案 |
|---|-----------|---------|------|------|
| 1 | `app/foo.test.ts:42-50` | NEEDS_JUSTIFICATION | `it('returns user', ...)` | 証明責任 3 項目を test コメントに明示、または削除 |
| 2 | `pkg/bar_test.go:88-95` | REDUCTION_CANDIDATE_MOCK_ONLY | `func TestFoo` で mock のみ呼ぶ | 削除 (production を呼んでいない) |
| 3 | `lib/baz.spec.ts:12-15` | REDUCTION_CANDIDATE_TYPE_ONLY | `expect(typeof exp).toBe('function')` | 削除 (TypeScript 型で代替済み) |

合計 N 件 / 削減候補 M 件

修正に進みますか? (y で全件修正 / 番号指定で部分修正 / n で停止)
```

### Step 5: ユーザー承認後 Edit で修正

承認方針:

- `y` / 「お願いします」 / 「全部」 → 全件 Edit で修正
- 番号指定 (例: `1,3` / `1-2`) → 該当件のみ
- `n` / 「やめる」 → 修正せず終了 (違反は報告済み)

修正方針 (カテゴリ別):

- `NEEDS_JUSTIFICATION`: ユーザーに証明責任 3 項目を聞く (or PR description で明示) → 満たせなければ test ブロックを削除提案
- `REDUCTION_CANDIDATE_DUPLICATE` / `_TYPE_ONLY` / `_MOCK_ONLY` / `_EMPTY_SNAPSHOT` / `_HAPPY_PATH_DUP` / `_ASSERTION_LESS`: 該当 test ブロックを**削除**
- `NO_VIOLATION`: 修正しない

Edit ツールで old_string に違反 test ブロックを含むコンテキスト、new_string に修正後を渡す。1 ファイル複数違反は連続して Edit する。

**モード別の Step 6 再 sweep 前提**:

- **default / `BASE_BRANCH` モード**: Edit 後に**必ず commit** する。default / `BASE_BRANCH` の再 sweep は `git diff <base-ref>...HEAD` を見るため、HEAD が動かないと working tree の修正が反映されず、Step 6 で同じ違反が再検出される (feedback loop 不全)。skill は自動 commit しない (commit 時の意図しない他ファイル混入を防ぐため)
- **`--staged` モード**: Edit は working tree のみを書き換える。修正後にユーザーが `git add <修正ファイル>` で**必ず restage** する
- **`--worktree` モード**: Edit で working tree 修正済みなので追加操作なし

### Step 6: 再 sweep で残違反ゼロを確認

修正後、モードに応じた diff で再 sweep を 1 回回す:

| モード | 再 sweep の比較対象 | 前提 |
|--------|---------------------|------|
| default / `BASE_BRANCH` | `git diff <base-ref>...HEAD` | 修正を **commit してから** 再 sweep |
| `--staged` | `git diff --cached` | Step 5 で `git add` 済みが前提 |
| `--worktree` | `git diff HEAD` | Edit で working tree 修正済みなのでそのまま反映 |

残違反がゼロになるまで Step 3〜5 を繰り返す (最大 3 回。それでも残るなら手動判断が必要としてユーザーに報告)。

## 違反パターンの具体例

### NEEDS_JUSTIFICATION (証明責任 3 項目を明示 or 削除)

```go
// 悪い例: なぜこの test を追加したか不明
func TestUserCreateHappy(t *testing.T) {
    user, err := CreateUser("alice")
    if err != nil {
        t.Fatal(err)
    }
    if user.Name != "alice" {
        t.Errorf("expected alice, got %s", user.Name)
    }
}

// 良い例: コメントで証明責任を明示
// 防ぐ regression: email nullable 化で CreateUser が email を必須パラメータに戻った場合
// 既存 cover: 既存 test は email 必須前提で書かれており nil 受け入れを検証していない
// 落ちた == バグ: CreateUser が email 必須を要求する形に戻ったか、nil 受け入れの新規ロジックが壊れた
func TestUserCreateWithNilEmail(t *testing.T) {
    user, err := CreateUser("alice")
    // ...
}
```

### REDUCTION_CANDIDATE_TYPE_ONLY (削除推奨)

```typescript
// 悪い例: 静的型で代替可能
it('exports correctly', () => {
  expect(typeof foo).toBe('function')
})

// 良い例: 削除 (TypeScript の import が同じことを保証)
```

### REDUCTION_CANDIDATE_MOCK_ONLY (削除推奨)

```typescript
// 悪い例: mock の戻り値を assert しているだけで production を呼んでいない
it('returns user from mocked api', () => {
  const apiMock = jest.fn().mockReturnValue({ id: 1 })
  expect(apiMock()).toEqual({ id: 1 })
})

// 良い例: 削除 or production の getUser を呼ぶ
```

### REDUCTION_CANDIDATE_ASSERTION_LESS (削除推奨)

```python
# 悪い例: 何も assert していない (実行するだけ)
def test_foo():
    foo()

# 良い例: 削除 or 振る舞いを assert
def test_foo_returns_zero():
    assert foo() == 0
```

### REDUCTION_CANDIDATE_HAPPY_PATH_DUP (削除推奨)

```typescript
// 悪い例: 同じロジックの正常系を 3 通りでテスト
it('returns sum for 2+2', () => { expect(add(2, 2)).toBe(4) })
it('returns sum for 1+1', () => { expect(add(1, 1)).toBe(2) })
it('returns sum for 10+10', () => { expect(add(10, 10)).toBe(20) })

// 良い例: parametric test に集約、または境界値 / failure path のみ残す
it.each([[2, 2, 4], [1, 1, 2], [10, 10, 20]])('add(%d, %d) = %d', (a, b, sum) => {
  expect(add(a, b)).toBe(sum)
})
```

### NO_VIOLATION (残す)

```typescript
// security regression 防止
it('rejects timing attack via constant-time compare', () => {
  // ...
})

// 過去に flaky で revert された機能の retry test
// 防ぐ regression: 一時的な network error で fail せず retry すること
// 既存 cover: happy path のみ既存。retry 経路は未テスト
// 落ちた == バグ: retry ロジックが壊れた / interval が変わって時間切れになった
it('retries on transient network error', () => {
  // ...
})
```

## PR 作成 flow への統合

[CLAUDE.md](../../../CLAUDE.md)「コミット / PR 運用」の autonomy 連鎖で `gh pr create` の**前**に `/comment-sweep` と並走で呼ぶ。`/co-evolve-check` / `/extension-bloat-sweep` とも併走可能 (重複しない、それぞれ別軸の bloat を検出)。

本 skill は **non-blocking report-only**。違反検出は強く nudge するが PR 作成を block しない。違反を残して PR を作る場合は PR description に 1 行で温存理由を明示する (例外規定: security / correctness regression / flaky 抑止 / ユーザー明示要請)。

## トラブルシューティング

| 問題 | 対処 |
|------|------|
| `git symbolic-ref refs/remotes/origin/HEAD --short` が失敗 | `git remote set-head origin -a` で再設定。それでも失敗なら明示引数 (`BASE_BRANCH`) を要求 |
| diff が空 | base 指定ミス (feature branch upstream を渡していないか確認) または HEAD が base に追いついている。`git log --oneline <base>...HEAD` で範囲を確認 |
| 違反テーブルが大量 (>20 件) | レガシー test を含む大規模差分の可能性。base を見直すか、ファイル単位で分割実行 |
| 周辺コード読み込みが多くて遅い | 同じファイル複数違反はまとめて Read。LLM 判定は 1 ファイル単位でバッチ化 |
| 修正後に lint / formatter が走って再差分 | 再 sweep 時に新たな違反として誤検出しないよう、formatter 自動修正分は無視 |
| `--worktree` モードで新規 test ファイルが拾われない | `git diff HEAD` は tracked のみ。事前に `git add -N <path>` で intent-to-add してから再実行 |
| test ファイルが diff に含まれず silent skip された | 期待挙動。test を含まない PR では sweep する対象がない |

## 根拠

判定基準は [rules/test-bloat-defense.md](../../../rules/test-bloat-defense.md) を SoT とし、本 skill は**判定タイミング** (PR 作成前 / commit 前) を強制する。`/comment-sweep` と同型の deterministic な発火点として skill 化している。
