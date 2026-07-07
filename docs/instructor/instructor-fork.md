# 講師個人 fork での workshop 運営

講師は配布用の workshop snapshot repo を自分個人の GitHub アカウントに fork し、そこで実演の準備を進め、そのまま受講者に配布できる。[workshop snapshot repo への sync](workshop-sync.md) が「本体 (upstream) → kanka-jp 傘下の配布 repo」への反映を扱うのに対し、本 doc は **講師個人の fork を起点にした運用** を扱う。fork 自体が受講者向けの配布先になるため、fork へ `git push` すること自体が「進捗の反映」であり、別の反映先 repo は要らない。

## 前提

- fork 元は既存の **public な workshop snapshot repo**（`kanka-jp/coding-agent-playbook-YYYYMMDD` 等）。まだ無ければ [workshop-sync.md](workshop-sync.md)「新しい開催回の snapshot repo を作る」で先に用意してから fork する。本体（`kanka-jp/coding-agent-playbook`）は private のため fork 元にしない
- `.github/workflows/*.yml` は repository secrets / vars を使わないため、fork 後の追加 secret 設定は不要
- スライド配信（`pages.yml`）を使う場合は fork 先の Settings > Pages で Source = "GitHub Actions" を設定する（fork ごとに個別設定が必要。fork 元の設定は引き継がれない）。**deploy job は main ブランチ限定のガードがある**（[README.md](README.md)「スライド」参照）ため、fork の main branch へ push した場合のみ配信される。手順 2 で main 以外の branch に push している間は配信されない点に注意

## 手順

1. **fork + clone + remote 設定**（`gh` が一括で行う。`<snapshot-repo>` は fork 元の `owner/repo`）:

   ```bash
   gh repo fork <snapshot-repo> --clone --remote
   ```

   `origin` = 自分の fork、`upstream` = fork 元の snapshot repo になる。`scripts/internal/new-stage.sh` は `origin` を前提に動くため、この remote 構成のままで支障はない。

2. **実演の準備**: 通常の worktree ベースの開発フロー（[../../rules/worktrees.md](../../rules/worktrees.md) / [../../rules/commit-pr.md](../../rules/commit-pr.md)）に従い branch を切って進める。**本体の ruleset（[repo-settings.md](repo-settings.md) の全 review thread resolve 必須等）は fork 先には引き継がれない** — 講師個人の fork では PR を経ずに直接 push してよい（受講者に見せる進捗を素早く積み上げるための個人作業環境のため）

3. **進捗の反映 = push するだけ**: fork は元の snapshot repo と同じく public なので、`git push` した時点で受講者はそのまま最新を見られる。受講者には fork の URL（`https://github.com/<自分の login>/<snapshot-repo 名>`）を案内する

4. **（任意）fork 元の更新を取り込む**: fork 元の snapshot repo 側で追加の sync（[workshop-sync.md](workshop-sync.md) 経由）があった場合、`git fetch upstream` してから必要な branch を merge / cherry-pick する

## 新しい stage を追加する場合

fork 内でも `scripts/internal/new-stage.sh` はそのまま使える（[README.md](README.md)「新しい stage を作る」）。stage の規約（`app/` 配下のみ編集等）は [../../rules/stages.md](../../rules/stages.md) 参照。
