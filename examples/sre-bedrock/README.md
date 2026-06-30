# cloud 常駐の無人 SRE 自動化（Bedrock）リファレンス

このディレクトリは、決定記録 [docs/decisions/cloud-unattended-sre.md](../../docs/decisions/cloud-unattended-sre.md) が定める
**cloud 常駐（HOTU）パターン** — CloudWatch 5xx → agent → 自動 fix PR — の自己完結リファレンス。

手元で人間が read-only 調査する **local（HOTL）パターン**は [examples/observe](../observe/runbook.md) と
[rules/box-personas.md](../../rules/box-personas.md) US3。両者は別軸で補完（local=人が深掘り / cloud=無人で一次対応）。

## 中身

| path | 役割 |
|---|---|
| [spike/](spike/) | ADR の核心仮説「**Bedrock 上の agent が sanitized triage から妥当な fix を導けるか**」を、インフラを作らず最小コストで検証する harness。ADR を `Proposed → Accepted` に進めるためのゲート |
| [pipeline/](pipeline/) | spike の上に乗る **trigger 配線 + identity 境界の設計**（CloudWatch 5xx → Lambda triage → fixer → PR）。観測/修正 2 つの least-privilege IAM 雛形と、dispatch を sanitize gate にする handoff 設計。IaC/実体は stage 系へ |

## 段階

ADR の「残差・未決」に沿った構築順:

1. **spike**（[spike/](spike/)）— 核心仮説の検証。← 通過済み（直 Anthropic key で初回 PASS）
2. **trigger 配線 + identity 設計**（[pipeline/](pipeline/)）— CloudWatch 5XX alarm → SNS → Lambda triage、観測/修正 identity の IAM 境界。← いまここ（設計）
3. パターン A（Fargate / CodeBuild で `claude -p`）→ B（AgentCore Runtime で Agent SDK）を end-to-end
4. 教材化（`stage/06→07` を pipeline 実演に + `slides/` の運用保守フェーズ）

2 以降のパイプライン実体と仕込みバグは demo アプリ（stage 系）側に置く。本ディレクトリは main 側の
横断リファレンス（認証/実行基盤・検証 harness）に徹する（[CLAUDE.md](../../CLAUDE.md)「stage ブランチの規約」）。
