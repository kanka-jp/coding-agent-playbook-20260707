# テスト肥大化への防御 (subtractive test default)

coding agent は「テストを過剰に書く / 削らない」ことで test suite の一方向 ratchet を起こしやすい。新規テスト追加には証明責任を課し、削減は default で proceed する。

## テスト追加の証明責任

新規テストを追加するときは以下を **1 行で言えること**:

1. **どの mutation / regression を防ぐか**: 具体的に (nullable 化、境界値、副作用、race condition 等)。「念のため」「カバレッジ上げる」は根拠にしない
2. **既存テストでカバーされていない理由**: 既存テストを grep / Read で確認し「覆っていない」を実証する
3. **このテストが落ちる == プロダクションコードのバグ**: と言える経路。落ちても「テストの書き方が悪い」「mock の設定が古い」等になるテストは追加しない

3 項目のいずれかが書けないテストは追加しない。

## テスト削減の default 続行

既存テストが以下のいずれかに該当する場合、refactor 時に削減候補として proceed する (「削るか残すか」を質問せず削除提案を出す):

- **duplicate**: 別テストと同じ振る舞いを別表現で確認している
- **type-only**: assertion が型チェック / 存在チェックのみ
- **mock-only**: mock しか触っておらず実プロダクションコードを呼んでいない
- **empty snapshot**: snapshot だけで意味のある explicit assert がない
- **happy-path 重複**: 同じロジックの正常系を 3-5 通りの書き方で重複テストしている
- **assertion-less**: 何も assert していない / 常に成功する自明な assertion でカバレッジを稼ぐだけ (fake test)

## 例外 (証明責任 / 削減 default の対象外)

- **security / correctness regression を防ぐ test**: 既存契約違反を直接捕捉するテスト
- **CI で flaky を抑止する test**: 過去に flaky で revert された機能の retry / waiting / cleanup test
- **ユーザー明示要請**: 「このパス全部テストして」と明示指示された場合は指示優先

## 背景

原因論 (一次文献):

- **addition bias**: LLM は「足す」default に偏る傾向がある ([Santagata & De Nobili 2024](https://arxiv.org/abs/2409.02569))
- **LLM 生成 test の体系的 test smell**: Assertion Roulette / Magic Number Test / Eager Test / Duplicate Assert 等が LLM 固有 pattern として頻出する ([Ouedraogo et al. 2024](https://arxiv.org/abs/2410.10628))
- **RL post-training が reward hacking を増幅**: 「カバレッジを上げる」「失敗テストを通す」指示が assertion を緩める / mock で実装を置き換える / fake test を追加する shortcut を誘発する ([arXiv:2605.02964](https://arxiv.org/abs/2605.02964))

`/test-sweep` skill ([../.claude/skills/test-sweep/SKILL.md](../.claude/skills/test-sweep/SKILL.md)) が PR 作成前の判定発火点として本規範を強制する。
