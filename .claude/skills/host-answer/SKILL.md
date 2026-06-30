---
name: host-answer
description: "On the host side, read the latest ask file from `.claude/host-bridge/ask-<box-name>-<topic>-<seq>.md` written by a box-internal `/host-ask`, investigate the requested host-side facts (other compose projects, host port occupiers, host fs outside the box mount, host-local services), write a paste-ready answer to `.claude/host-bridge/ans-<box-name>-<topic>-<seq>.md`, then touch a done sentinel `ans-<box-name>-<topic>-<seq>.md.done` so the box-side `/host-ask` auto-pickup polling can detect completion race-free (sentinel is created after the ans body write completes, guaranteeing the body is fully flushed when the sentinel appears). Counterpart of `/host-ask` (box-from-host bridge). Use when the user says a box session has written an ask and needs host investigation."
---

# host-answer

box 内の `/host-ask` が `.claude/host-bridge/ask-<box-name>-<topic>-<seq>.md` に書いた問い合わせを host で読み、host 側で調査して `.claude/host-bridge/ans-<box-name>-<topic>-<seq>.md` に paste-ready answer を Write する skill。

`/host-ask` の counterpart (box-from-host bridge)。box 内では見えない host 情報 (他 project の compose / 既存 container / port 占有者 / mount 外の host fs / host-local service) を host claude が代理調査して box に返す経路。

## 前提条件

- **host 側で実行** する skill (box 内では意味がない)
- repo root (もしくは `.claude/host-bridge/` が見える cwd) で起動
- 対応する box session が同 repo 上で動いており、`/host-ask` で ask file を Write 済み

## 使い方

引数 = `<box-name> [<topic>]`

- `<box-name>`: box の `$SANDBOX_VM_ID` env と同値 (例: `coding-agent-playbook-4632ea`)。ask file 名と対応 (`ask-<box-name>-<topic>-<seq>.md`)。statusLine の `[<box-name>]` 表示でも確認可能
- `<topic>` (省略可): 対象 topic slug。省略時は `ls -t .claude/host-bridge/ask-<box-name>-*.md` の中で **done sentinel (`.md.done`) 未生成** かつ **mtime 最新** の ask を採用 (= box が出した直近の未完了 ask)。判定は ans body の有無ではなく sentinel の有無で行う (body だけ生成済みで sentinel 未生成 = 前回の `/host-answer` 起動が body Write 完了後に touch 失敗した中途半端な状態、これも未完了として再処理する必要があるため)

## 手順

1. **対象 ask の特定**:
   - topic 指定時: `ls .claude/host-bridge/ask-<box-name>-<topic>-[0-9][0-9][0-9].md 2>/dev/null | sort | tail -1` で同 topic の最新 seq を採用 (`[0-9][0-9][0-9]` の anchored 文字 class 形で topic prefix 衝突 = `port` glob が `port-80` を hit する罠を回避。 `<seq>` は 3 桁ゼロ埋めのため plain `sort` の lexicographic 順で数値順と一致。GNU 拡張の `sort -V` は macOS/BSD sort 非対応で cross-platform 違反のため使わない)
   - topic 省略時: `ls -t .claude/host-bridge/ask-<box-name>-*.md 2>/dev/null` を mtime 降順で並べ、対応 **done sentinel** (`ans-<box-name>-<topic>-<seq>.md.done`) が無いものの中で最新を採用 (body の有無ではなく sentinel の有無で判定。前回中途半端に終わった body だけある状態も「未完了」として再処理対象)。すべて完了 (sentinel あり) なら user に「未完了 ask なし」と返して終了
   - 0 件 hit (box-name 違い等) なら user に escalate して停止

2. **ask 読込**: 対象 ask file を Read して以下を抽出:
   - `## 欲しい事実` — host で答えるべき問い
   - `## 既知` — box 側で既に確認済みの事実 (host 側で重複調査しない)
   - `## 仮説` — host で裏取りしてほしい候補
   - `## Done when` — ans の終了条件

3. **host 側調査**: 通常の host Bash / Read で調査。よく使う手段:
   - `docker ps --format '...'` / `docker network ls` / `docker network inspect <name>` / `docker volume inspect <name>` — 他 project の container / network / volume の状態
   - `docker inspect <container> --format '{{json .Config.Cmd}}'` / 同 `.Mounts` — 既存 container の設定値
   - `lsof -nP -iTCP:<port> -sTCP:LISTEN` — host port の占有 process (lsof 側で `-iTCP:<port>` を使い anchored 照合する。`lsof -nP -iTCP -sTCP:LISTEN | grep ':<port>'` 形式は `grep ':<port>'` が unanchored で `:80` 検索が `:8080` も hit する罠があるため使わない)
   - `ls -la <path>` / `cat <path>` / `head <path>` — mount 外の host fs
   - `curl -sS http://localhost:<port>/...` — host-local service への到達
   - 必要なら別 project の compose file を読む (read-only、書き込みは禁ずる)

   **書き込み禁止**: 本 skill は read-only 調査のみ。他 project の container 起動 / 停止 / volume 編集 / 設定変更等の副作用は出さない (box session の意図と無関係に host 環境を変更してはならない)。判断材料として「変更案」を ans に書くのは可、実行は user 判断。

4. **bridge dir 確保 → 旧 sentinel 削除 → ans body Write → done sentinel touch (この順序が race-free 契約)**: `mkdir -p .claude/host-bridge` を実行 (host 側で本 skill 単独実行時に dir が無いケース、冪等で副作用なし)。次に、同 path の ans を再 Write するケース (前回中途半端に終わった ask の再処理 / 同一 seq の上書き) に備えて **対象 sentinel を先に削除**してから body を Write、Write 完了後に sentinel を touch する。順序を間違えると race window が再発する (詳細は下記):

   ```bash
   # (a) 旧 sentinel を削除 (body Write 中に古い sentinel を polling が見て早期 cat する事故防止)
   rm -f .claude/host-bridge/ans-<box-name>-<topic>-<seq>.md.done
   ```

   続けて `.claude/host-bridge/ans-<box-name>-<topic>-<seq>.md` を下記 format で Write (`<seq>` は対象 ask と同値 = 1 ask に対し 1 ans)。

   ```bash
   # (b) Write 完了後に done sentinel を touch (box 側 polling が sentinel を待つ)
   touch .claude/host-bridge/ans-<box-name>-<topic>-<seq>.md.done
   ```

   **(a) → body Write → (b) の順序が必須**: Write ツールは大きい file を非 atomic に書く可能性があり (truncate + sequential write)、box 側 polling が `[ -f ans...md ]` で本体を直接見ると half-written 状態を `cat` するリスクがある。sentinel は **ans 本体の Write が完了してから別 step で作る serialization** で、sentinel 出現 = 本体完成済みを保証する (race-free)。順序を逆 (sentinel を先に touch / 古い sentinel を残したまま body を Write) にすると、polling が **古い body** や **半書きの新 body** を早期に `cat` してしまう。fresh ask (sentinel が存在しない初回) では (a) の `rm -f` は no-op (`-f` で error しない) で冪等。

5. **escalate**: user に以下を伝えて自走を止める:
   ```text
   📥 host info reply 書きました: .claude/host-bridge/ans-<box-name>-<topic>-<seq>.md
      (done sentinel: ans-<box-name>-<topic>-<seq>.md.done)

   box 側 (auto-pickup 対応の /host-ask) は background polling が sentinel を検出して自動取り込みします (手動 cat 不要)。
   旧版 /host-ask を使っている box では手動で:
     cat .claude/host-bridge/ans-<box-name>-<topic>-<seq>.md
   ```

## ans file format

````markdown
# Host info reply

- **to**: box `<box-name>`
- **topic**: `<topic>`
- **seq**: `<seq>`
- **ts**: `<iso8601 UTC>`

```host-ctx
<box が `cat` してそのまま context に取り込める paste-ready ブロック>
<事実関係を箇条書きで・推測と事実を分離 (fact-vs-speculation 規範)>
<必要なら「推奨判断軸」「相乗りに倒す場合の障害」等の素材も含める>
```

## Notes (任意、host 側コメント)

- <box に取り込ませる必要のない host 側補足>
- <調査の限界・未確認事項>
````

`host-ctx` fence は box 側で `awk '/^```host-ctx/,/^```$/'` 等の機械抽出も可能 (sentinel として安定形式を維持)。

## 並列 ask の扱い

1 box session が複数 topic を同時に走らせる場合、host 側も topic 別に独立して ans を返す (`/host-answer <box-name> <topic>` を topic ごとに呼ぶ)。topic 省略の auto-detect は「未回答 ask の中の mtime 最新」を採るため、複数未回答が並んでいるときは古いものから順に topic 明示で回す方が安全。

## limitations / caveats

- **read-only 限定**: host 環境への書き込み (container 起動・volume 編集・compose up 等) は禁ずる。判断材料の提示までが本 skill の責務、実行は user 判断
- **secret / 機密**: ans file 内に host の credential / API key / 個人情報を貼らない (host ↔ box で平文共有される、git ignore で永続化されないが box context には載る)。`docker inspect` の出力に env が含まれる場合は redact してから ans に書く
- **fact vs speculation**: ans 内の `host-ctx` ブロックは事実関係を中心にし、推測は明示的に分離する ([rules/skills.md](../../../rules/skills.md) の leaf skill 規範 + fact-vs-speculation 一般規範)
- **lifecycle**: ans file は `.gitignore` 対象だが**自動削除しない**。debug 価値で残し、気になったら手動 `rm`
- **box 跨ぎ**: host 側 claude session は box 側 box-name と独立。本 skill が `<box-name>` を引数で受けるため、複数 box (parallel dev 等) に対しても順次対応できる

## トラブルシューティング

| 問題 | 対処 |
|------|------|
| `.claude/host-bridge/` が空 / 該当 ask file 無し | box 側で `/host-ask` が実行されたか確認。`ls .claude/host-bridge/` で実在 file を確認 |
| `<box-name>` 指定で 0 件 hit | box 側 statusLine の `[<box-name>]` と比較。typo / 別 box の可能性 (`sbx ls` で active box 名を確認) |
| 複数 topic が未回答で並んでいる | topic 明示で 1 件ずつ回す。auto-detect は mtime 最新を採るため曖昧 |
| host 側調査で副作用 (container 起動等) が必要に見える | 本 skill では実行しない。ans に「user に提案: `docker compose -f <file> up -d <svc>` 実行」と書いて user 判断に委ねる |
| 同 topic で box 側が follow-up ask を出してきた (seq が増えた) | 新 seq の ask を読み直して新 seq の ans を書く (古い ans は残しても新しい ans を書いても OK、box 側は最新 seq を `cat` する) |
