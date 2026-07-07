---
name: fact-vs-speculation
description: "調査結果・原因推定・修正方針・コードレビューを提示する際に、観測した事実とモデルの推測・解釈を混同せず書き分けるための出力規範。file 読込・grep・コマンド実行結果に基づく報告、バグや障害の原因推定、実装計画・差分レビュー、またはユーザーが「事実と推測の分離が甘い」と指摘した時に発動する。一般的な技術知識（言語仕様・標準ライブラリ等）には適用しない。"
---

# Fact vs Speculation

## When to apply

調査結果・コードベース内挙動・原因推定・修正方針・コードレビュー（差分レビュー）を提示する時に発動する。一般的な技術知識（「Python は動的型付け」「git rebase は履歴を書き換える」等の言語仕様・標準ツールの確立した挙動）は対象外。

## Rules

断定形（「〜である」「〜する」）は以下のいずれかに限定する:

1. このセッションで実際に読み込んだファイル内容またはコマンド出力にそのまま現れた記述
2. このセッションで `path:line` を実際に開いて該当箇所を確認した記述

観測していない原因推定・挙動予測・推論は、推測として読める言い回し（「〜と推測」「〜と思われる」「〜の可能性が高い」）を省略しない。

引用（`path:line` / コマンド出力）は出所の証明であり、正しさの保証ではない。引用付きでも解釈には推測表現を残す。

## 「未確認」の使い方

ユーザーの次の行動（実行・判断・共有・マージ・デプロイ）が変わる未検証事項のみ「未確認」と明示する。単に確認していないが行動に影響しない事項には付けない。

## やってはいけないこと

- **全主張へのラベル付け** — `[Fact]` / `[Inferred]` 等を毎文に付与すると ritual 化して情報量がゼロに収束する
- **引用を装って未確認の解釈を断定する** — `path:line` を添えつつそのコードの意味を推測で書くと、citation が誤った安心を与える（grounding hallucination）
- **文末の機械的置換** — `〜である` を `〜と考えられる` に置換するだけでは compliance theater にすぎず、根拠の弱さは隠れていない

## 根拠

主要な参考文献:

- LLM の verbalized confidence は internal confidence と乖離する: [https://arxiv.org/abs/2408.09773](https://arxiv.org/abs/2408.09773)
- CoT explanation は実際の推論を反映しない（unfaithful）: [https://arxiv.org/abs/2305.04388](https://arxiv.org/abs/2305.04388)
- AI explanations は overreliance を減らさず増やしうる: [https://www.eecs.harvard.edu/~kgajos/papers/2021/bucinca2021trust.shtml](https://www.eecs.harvard.edu/~kgajos/papers/2021/bucinca2021trust.shtml)
- Long context での中間情報の利用性能は低下する（Lost in the Middle）: [https://arxiv.org/abs/2307.03172](https://arxiv.org/abs/2307.03172)
