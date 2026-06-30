# box persona と権限ティア

coding agent を **権限ティアごとに別 box / 別 identity に分離**して回すための規約。
通常開発（write）・AWS 可観測性の調査（read-only）・deploy（host privileged）を**混ぜない**。
全体の実行モデルは [box-ops.md](box-ops.md)、PR ライフサイクルは [pr-followup.md](pr-followup.md) 参照。

## なぜ分けるか（原則）

業界の SRE/agent セキュリティ実践（AWS DevOps Agent の read-first・Agent Space per environment、
PagerDuty の Review/Autonomous ゲート、WorkOS の agent identity 分離、CoSAI の JIT 権限、
Simon Willison の lethal trifecta、Grafana MCP の opt-in read-only）に共通する原則を、本 playbook に写す。

- **P1 read-first / write-gated**: 調査(read)は自走、修正・再 deploy(write/remediation)は人間承認。
- **P2 persona ごとに別 identity・別 credential**: 1 つの広域資格を使い回さない／ユーザー資格を借用しない。
- **P3 standing 権限を持たせない**: 短命・task-scoped・即失効。長期 full-access key の直焼きはアンチパターン（blast radius）。
- **P4 read-only の境界は権限層(IAM)で作る**: tool 層(CLI/MCP)に依存しない。read-only は IAM ロールで強制する。
- **P5 観測データ(ログ本文)は untrusted**: lethal trifecta（private data + untrusted content + external comms）の
  同時成立を避ける。観測 persona は private data(AWS read) と untrusted content(ログ) を持つので、
  **external comms を AWS API endpoint のみに絞って** trifecta を崩す。

## persona マトリクス

| persona | 実行場所 | repo | git | AWS cred | network | 役割 |
|---|---|---|---|---|---|---|
| **dev box** | sbx microVM | bind-mount (write) | push/PR | なし | github + codex pair + MCP | 通常開発・実装・codex review・PR |
| **observe box** | sbx microVM | **clone copy**（`dev.sh observe` = `--clone .`。host checkout を mount せず host repo を汚さない＝read-only 相当・push しない。committed runbook を含む） | なし | read-only・短命 session・スコープ済 | **AWS read API endpoint のみ**（CDN 不可） | AWS 可観測性の調査（ログ/状態を読む） |
| **host** | host | working tree | — | write/deploy | full | deploy/destroy・headful browser 確認・bridge 応答 |

**不変条件**:
- write/deploy の AWS cred は **host だけ**。observe box は **read-only cred だけ**。dev box は **AWS cred ゼロ**。
- identity は 3 つに分離（P2）。observe box の cred は **host が mint した短命 session を実行時注入**し、
  box 内では `AssumeRole` しない（IAM で `sts:AssumeRole` を明示 Deny。credential broker 化を防ぐ。P3）。
- **アプリ閲覧（CDN/ブラウザ）は observe box でやらない**（CDN を許可すると `https://<cdn>/<path>` で
  観測データを exfil できる＝trifecta 復活。P5）。閲覧は AWS cred 非保持側（host か dev box の headless chrome）で行う。

## CLI 既定・MCP 任意

read-only の境界は IAM が作る（P4）ので、CloudWatch MCP 等は**必須でない**。observe box では **`aws` CLI を既定**とする
（最小・clone で再現できる）。MCP は「作り込み済み観測ツール(anomaly/analyze)が欲しい」「多サービス統一面が要る」時だけの
任意オプション（MCP tool 面自体が prompt-injection surface を増やすため最小では入れない）。
具体コマンドは [../examples/observe/runbook.md](../examples/observe/runbook.md)、read-only IAM は
[../examples/observe/readonly-iam-policy.json](../examples/observe/readonly-iam-policy.json) を参照。

## ユーザーストーリー

### US1 通常開発（dev box）※本体
dev box で worktree → 実装 → `/a2a-review` → `gh pr create` → `/pr-codex-ci` → merge-ready。
AWS cred はこの経路に出てこない。大半の作業はここ。

### US2 host 側で使うケース（privileged / 人手）
- **deploy**: host で `npm run deploy`（write cred は host のみ）→ 出力 URL を控える（**非 commit**・口頭/非公開メモで提示）。
  後始末は `cdk destroy`（NAT/ALB/Fargate の課金停止）。
- **headful 確認**: host Chrome で deploy 済み URL を目視 / box からは cdp-bridge（[headful-bridge.md](../docs/headful-bridge.md)）か、
  CDN を `sbx policy allow` 後に dev box の headless chrome-devtools MCP で閲覧（dev box は AWS cred 非保持なので trifecta 不成立）。
- **bridge**: box が host しか見えない事実を `/host-ask` → host が `/host-answer`。

### US3 AWS 調査（observe box）※運用保守フェーズの実環境版
deploy 済み環境で異常（例: 診断が 502）→ observe box を起こし、host が mint した read-only session で
`aws logs filter-log-events` 等から `external_call{kind:upstream,path:...}` を読む → 構造化ログがそのまま切り分け材料 → 原因特定。
**read=observe box で自走 / 修正=dev box(write) / 再 deploy=host(privileged)** の read-first・write-gated 3 段（P1）。
既定は **Review 相当**（人間が修正/再 deploy を承認）。Autonomous な自動修正は扱わない（教材の安全側）。

## 公開リポ制約

実 URL / account ID / ARN / log group 実名は **commit しない**（[../README.md](../README.md) / 公開リポ前提）。
committed なのは placeholder 入りテンプレと runbook だけ。実値は実行時に env/file 注入し、ランタイムメモは
gitignore 済みの `.claude/tmp/` に置く。
