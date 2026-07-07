# Overlay 注入の実装サンプル

SKILL.md `Step 4` で参照する `evaluate_script` の完全実装。設計方針 (`document.body` 直下に枠とラベルを別 overlay、`pointer-events: none`、CSS Anchor Positioning 第一選択 + rect fallback、対象要素への変更は `anchor-name` + cleanup 用 `data-manual-verify-anchor-host` + `scrollIntoView` の 3 つに限定) は SKILL.md 本体参照。

## evaluate_script に渡す関数

`args` には `take_snapshot` で得た**その箇所の全変更要素の uid** を並べて渡す (`args: ["<uid1>", "<uid2>", ...]`。代表 1 つでなく、Step 2 で列挙した全要素ぶん)。Chrome DevTools MCP は `args` の**全要素**を uid として HTMLElement に resolve するため (tool schema の items が "The uid of an element on the page from the page content snapshot")、label 文字列を `args` に混ぜると `Error: Element uid "ⓐ ..." not found` で失敗する。`label` (identifier `ⓐ ⓑ ⓒ` 等を含めた 1 行説明。例: `"ⓐ まずここを押す"` / `"ⓑ ここを確認: PR=6 行, base=2 行"`) は**関数ソース内の文字列リテラル**として注入ごとに書き換える (画面の実テキストを引用していて `'` を含む場合はダブルクォートリテラルかエスケープを使う — SyntaxError で注入自体が失敗するため)。本サンプルは `(...els)` で**複数 uid を受け取り各要素に枠を付け、label は最初に解決できた要素 1 つだけに付ける** (1 箇所 = N 枠 + 1 label。`anchorName` は枠ごとに一意で衝突せず、Cleanup snippet は全 overlay を一括削除できる)。**1 注入 = 1 箇所** (別の箇所は label を書き換えて改めて `evaluate_script` を呼ぶ):

```js
(...els) => {
  // 箇所ごとに 1 つの label を注入ごとに書き換える。'' で label を省く (枠のみ)
  const label = 'ⓐ ここを確認: PR=6 行, base=2 行';
  const isVisible = (n) => {
    const r = n.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  };
  // uid → 可視 target に解決 (非表示クローンは同 tagName・同 textContent の唯一可視要素へ差し替え)
  const resolve = (el) => {
    if (isVisible(el)) return { target: el, swapped: false };
    const text = el.textContent.trim();
    const candidates = text
      ? [...document.querySelectorAll(el.tagName)].filter(
          (n) => n !== el && n.textContent.trim() === text && isVisible(n),
        )
      : [];
    if (candidates.length !== 1) {
      return { reason: candidates.length === 0 ? 'zero-rect' : 'ambiguous' };
    }
    return { target: candidates[0], swapped: true };
  };

  const supportsAnchor = CSS.supports('anchor-name: --x');

  const makeFrame = (target) => {
    const anchorName = `--mv-anchor-${Math.random().toString(36).slice(2, 10)}`;
    if (!target.hasAttribute('data-manual-verify-anchor-host')) {
      target.setAttribute('data-manual-verify-anchor-host', target.style.anchorName || '');
    }
    target.style.anchorName = anchorName;
    const frame = document.createElement('div');
    frame.setAttribute('data-manual-verify-anchor-frame', '');
    Object.assign(frame.style, {
      position: 'fixed',
      pointerEvents: 'none',
      zIndex: '2147483647',
      border: '3px solid red',
      borderRadius: '3px',
      boxSizing: 'border-box',
    });
    if (supportsAnchor) {
      frame.style.positionAnchor = anchorName;
      frame.style.top = 'calc(anchor(top) - 7px)';
      frame.style.left = 'calc(anchor(left) - 7px)';
      frame.style.width = 'calc(anchor-size(width) + 14px)';
      frame.style.height = 'calc(anchor-size(height) + 14px)';
    } else {
      const update = () => {
        const r = target.getBoundingClientRect();
        const visible = r.width > 0 && r.height > 0;
        frame.style.display = visible ? '' : 'none';
        frame.style.top = `${r.top - 7}px`;
        frame.style.left = `${r.left - 7}px`;
        frame.style.width = `${r.width + 14}px`;
        frame.style.height = `${r.height + 14}px`;
      };
      update();
      window.addEventListener('scroll', update, { capture: true, passive: true });
      window.addEventListener('resize', update, { passive: true });
      frame._mvCleanup = () => {
        window.removeEventListener('scroll', update, { capture: true });
        window.removeEventListener('resize', update);
      };
    }
    document.body.appendChild(frame);
    return anchorName;
  };

  const results = [];
  const framed = new Map();
  let firstAnchor = null;
  let firstTarget = null;
  els.forEach((el, i) => {
    const r = resolve(el);
    if (!r.target) {
      results.push({ index: i, ok: false, reason: r.reason });
      return;
    }
    const box = r.target.getBoundingClientRect();
    // 既に枠付きの要素を再枠すると anchorName 上書きで先行枠の position-anchor が壊れるため dedup する。
    // data-manual-verify-anchor-host は Cleanup まで残るので、同一注入内 (framed Map) に加え注入またぎの部分再注入も 1 判定で検出できる。
    if (framed.has(r.target) || r.target.hasAttribute('data-manual-verify-anchor-host')) {
      results.push({
        index: i,
        ok: true,
        swapped: r.swapped,
        duplicateOf: framed.has(r.target) ? framed.get(r.target) : null,
        rect: { top: box.top, left: box.left, w: box.width, h: box.height },
      });
      return;
    }
    const anchorName = makeFrame(r.target);
    framed.set(r.target, i);
    if (firstAnchor === null) {
      firstAnchor = anchorName;
      firstTarget = r.target;
    }
    results.push({
      index: i,
      ok: true,
      anchorName,
      swapped: r.swapped,
      rect: { top: box.top, left: box.left, w: box.width, h: box.height },
    });
  });

  // label は箇所ごとに 1 つ。最初に解決できた frame に付ける
  if (label && firstTarget) {
    const labelEl = document.createElement('div');
    labelEl.setAttribute('data-manual-verify-label', '');
    labelEl.textContent = label;
    Object.assign(labelEl.style, {
      position: 'fixed',
      pointerEvents: 'none',
      zIndex: '2147483647',
      background: 'red',
      color: 'white',
      padding: '2px 8px',
      font: '12px/1.4 system-ui, sans-serif',
      borderRadius: '3px',
      whiteSpace: 'nowrap',
    });
    if (supportsAnchor) {
      labelEl.style.positionAnchor = firstAnchor;
      labelEl.style.top = 'calc(anchor(top) - 28px)';
      labelEl.style.left = 'calc(anchor(left) - 7px)';
    } else {
      const update = () => {
        const r = firstTarget.getBoundingClientRect();
        const visible = r.width > 0 && r.height > 0;
        labelEl.style.display = visible ? '' : 'none';
        labelEl.style.top = `${r.top - 28}px`;
        labelEl.style.left = `${r.left - 7}px`;
      };
      update();
      window.addEventListener('scroll', update, { capture: true, passive: true });
      window.addEventListener('resize', update, { passive: true });
      labelEl._mvCleanup = () => {
        window.removeEventListener('scroll', update, { capture: true });
        window.removeEventListener('resize', update);
      };
    }
    document.body.appendChild(labelEl);
  }

  // label を出す初回注入のみ代表を画面中央へ。部分再注入 (label='') は初回の中央位置を保つためスクロールしない (retry の新規枠へ視点がジャンプし代表が画面外へ出るのを防ぐ)
  if (label && firstTarget) firstTarget.scrollIntoView({ block: 'center', behavior: 'instant' });

  return { ok: results.some((r) => r.ok), label: label || null, results };
}
```

仕様メモ:

- **複数 uid を 1 回で注入する**: `(...els)` で全 uid を受け取り、各要素に枠を 1 つ、**label は最初に解決成功した要素にだけ** 1 つ付ける (箇所ごとに枠 N + label 1)。戻り値 `results` は uid ごとの `{ index, ok, reason?, swapped?, rect, duplicateOf? }`。`ok: false` (resolve 失敗) のみ `rect` を持たず、それ以外 (新規枠・dedup された重複) は `rect` を持つ。`ok: false` の要素だけ呼び出し側が選び直して再注入する (SKILL.md Step 4 手順 5)。全 uid が `zero-rect` / `ambiguous` でも他要素の枠は残る (`ok` は `results.some`)
- **同じ要素に解決した重複 uid は枠を 1 つだけ作る** (`framed` Map と `data-manual-verify-anchor-host` 属性で dedup)。2 件目以降は枠を作らず `{ ok: true, duplicateOf, rect }` を返す (`duplicateOf` は同一注入内の先行 index、注入をまたいだ重複は `null`) — `makeFrame` を同じ要素に 2 度呼ぶと `target.style.anchorName` が後勝ちで上書きされ、先行枠の `position-anchor` が解決できず viewport 原点へ縮退するため。固定列テーブルの非表示クローン (同 tagName・同 textContent) が複数 uid として渡り `resolve` の差し替えで同じ可視要素に集約されるケースで発生しうる
- **dedup は同一注入内と注入またぎの両方をカバーする**: `framed` Map は単一 `evaluate_script` 呼び出し内の重複を、`data-manual-verify-anchor-host` 属性 (makeFrame が付与し Cleanup まで残る) は**部分再注入** (Step 4 手順 5、成功枠を Cleanup せず残したまま失敗 uid のみ再注入) で前バッチ済みの要素に再解決した場合の上書きを防ぐ。`anchorName` は枠ごとに一意 (`Math.random()`) で別要素なら何枠でも衝突しない。なお full reload を挟む再注入は overlay が消えて属性も無くなるため通常どおり新規枠を作る
- `data-manual-verify-anchor-host` には元の `anchor-name` 値を保存 (空でも `''`)。Cleanup で復元する
- `pointer-events: none` を入れているので overlay は click を透過し、既存 UI のボタン操作を阻害しない
- `z-index: 2147483647` (32-bit signed int の最大値) を使う。CSS 仕様自体は `<integer>` の上限を定めていないが、主要ブラウザは内部で 32-bit signed int に clamp するため実用上の最大値として機能し、sticky header 等の上に出る。ただし native `<dialog>.showModal()` や popover による [top-layer UI](https://developer.mozilla.org/en-US/docs/Glossary/Top_layer) の下に描画される制約はあり、これらの target には overlay 注入を skip し Step 5 のテキスト手順で位置を案内する
- **冒頭の可視差し替え (`isVisible` + 同 tagName・同 textContent 検索)**: a11y snapshot の uid は、固定列対応等で同内容を複数レンダリングするテーブル実装の**非表示側クローン** (rect が全ゼロ) を指すことがある (実機で発生)。rect ゼロのまま注入すると枠が viewport 左上に 12px 四方で縮退する。差し替えは**同 tagName + 同 textContent の可視要素がちょうど 1 つ**のときだけ実行し、0 件は `reason: 'zero-rect'`、複数一致 (行ごとの同名ボタン等の曖昧ケース) は `reason: 'ambiguous'` で **fail closed** する (誤った行・列へ `ok: true` のまま差し替わる経路を排除)。いずれも呼び出し側は SKILL.md Step 4 手順 5 に従い、テキストが一意な要素 (値セル等) を対象に選び直して再注入する。検索を「同じ行内」等に狭めると主シナリオ (可視クローンは**別の** tr に居る) が壊れるため絞り込みはせず、`swapped: true` 時の目視確認 (SKILL.md Step 4 手順 6) は維持する
- **`anchor()` は記述する inset プロパティの座標系で解決される** ([CSS Anchor Positioning §anchor()](https://drafts.csswg.org/css-anchor-position-1/#anchor-pos))。`top: anchor(top)` は containing block (fixed では viewport) 上端からの距離、`bottom: anchor(top)` は下端からの距離。viewport-top 座標前提で `bottom: calc(100% - anchor(top) + 11px)` のように書くと二重変換になりラベルが鏡映位置に飛ぶ (実機で発生)。本サンプルは frame / label とも `top` ベースで統一している。follower 側は `position: fixed` で anchor と座標系を揃える
- **rect fallback の `display` トグル**: 対象が後から非表示になる (タブ切替等) と rect が全ゼロになり枠が viewport 左上に縮退して残るため、ゼロ rect 時は overlay を隠す。**anchor 経路にはこの自動退避がない** — 対象の非表示化・unmount で anchor が解決できなくなり overlay が迷子になるため、タブ切替等を挟む確認では Cleanup snippet → 再注入で対処する (SKILL.md トラブルシューティング参照。observer 等の JS 追従を足すと anchor positioning 採用理由の「JS なし・compositor 同期」と矛盾するため入れない)
- **戻り値の `results`**: uid ごとの `{ index, ok, reason?, swapped?, rect, duplicateOf? }` 配列。注入後検証 (SKILL.md Step 4 手順 5) で**`ok: true` 各要素の `rect` 非ゼロ確認**に使い (`ok: false` は `rect` を持たない)、`ok: false` の uid だけ選び直して再注入する。`swapped: true` は当該 uid が非表示クローンを指しており可視要素へ差し替えたことを示す
- **label の追従 listener**: anchor 非対応環境では label も自前の `scroll`/`resize` listener を持つため `_mvCleanup` を持つ。Cleanup snippet は frame と label の両方で `_mvCleanup` を呼ぶ (枠は anchor 経路では JS listener 無し、label は最初の要素 1 つにのみ存在)

## snapshot truncate 時の代替経路 wrapper

SKILL.md トラブルシューティング「`take_snapshot` が token 上限で truncate される / 大規模で取れない」の代替経路 (1) で参照する wrapper。主経路の「evaluate_script に渡す関数」が `(...els)` で uid 解決済み HTMLElement を受け取る前提なのに対し、本 wrapper は **`args` を渡さず (または空配列で) 呼び**、関数内で Step 2 で列挙した全変更要素の**可視テキスト**から要素を解決する。要素解決には Scroll-sync snippet の `visibleText` / `innermost` 構造を流用し、枠生成 (`makeFrame`) は主経路と同じロジックを使う:

```js
(...els) => {
  // `(...els)` は呼び出し側が `args: []` で呼ぶ前提のため空配列がバインドされる (関数内未使用)。
  // 主経路と同じシグネチャで宣言することで「(...els) パラメータは空配列がバインドされる」の trouble­shooting 記述と整合する。
  // 箇所ごとに 1 つの label。代替経路でも主経路と同じ契約 (代表要素 = 列挙順で最初に解決成功した要素にのみ付与)
  const label = 'ⓐ ここを確認: PR=6 行, base=2 行';
  // Step 2 で列挙した全変更要素の可視テキストを literal で列挙する (先頭から順に探索)。
  // 主経路と同型: label は targetTexts 先頭でなく「列挙順で最初に解決成功した要素」へ付与する。
  const targetTexts = [
    '通知設定', // 列挙順先頭 (解決成功すれば label 付与対象)
    'メール通知を受け取る',
    'プッシュ通知を受け取る',
    // ...全変更要素ぶん
  ];

  // Scroll-sync snippet と同じ visibleText / innermost を流用する。実装本体は同 snippet からコピペすること
  // (この wrapper はそれを前提とした薄い orchestrator)。閾値 `width > 1 && height > 1` も同 snippet に合わせる
  // (sr-only 1x1 px 除外の根拠は Scroll-sync の設計メモ参照)。
  const isVisible = (n) => {
    const r = n.getBoundingClientRect();
    return r.width > 1 && r.height > 1;
  };
  // visibleText / normalize は Scroll-sync snippet と同じ実装をコピペして使う
  // (display: contents 透過、sr-only 除外、空白正規化の細部は同 snippet が SoT)。
  const visibleText = (n) => /* Scroll-sync snippet の visibleText 関数をコピペ */ '';
  const normalize = (s) => s.replace(/\s+/g, ' ').trim();
  // innermost 判定は Scroll-sync と同じ「子孫に同テキスト可視要素が無い」基準を使う (contains() 判定は子孫が居ても親が外れる場合に最内を誤判定するため、同 snippet と等価実装を流用する)。
  const findOne = (text) => {
    const matches = [...document.querySelectorAll('body *')].filter(
      (n) => isVisible(n) && normalize(visibleText(n)) === text,
    );
    const innermost = matches.filter(
      (n) => !matches.some((m) => m !== n && n.contains(m) && normalize(visibleText(m)) === text),
    );
    if (innermost.length !== 1) {
      return { reason: innermost.length === 0 ? 'not-found' : 'ambiguous' };
    }
    return { target: innermost[0] };
  };

  // makeFrame / visibleText / normalize / addLabel は主経路「evaluate_script に渡す関数」(本ファイル冒頭) の同名関数を**コピペして使う**。
  // 本 wrapper は薄い orchestrator で、これらの関数本体は SoT (主経路) から流用する前提。
  // 本サンプルがそのまま callable な完成形ではなく、コピペ統合後に動く設計。
  // - makeFrame 本体: 主経路 L34-L100 周辺 (anchor-name 付与・frame/label DOM 構築・rect fallback・data-manual-verify-anchor-host 属性)。返り値は anchorName 文字列
  // - visibleText 本体: Scroll-sync snippet L260-L270 周辺 (display: contents 透過 + sr-only 除外)
  // - addLabel (label DOM 注入): 主経路 L103-L106 の firstAnchor === null 分岐内の label 構築
  const supportsAnchor = CSS.supports('anchor-name: --x');
  // 未実装のまま呼ばれると "ok: true" の偽陽性 (枠もラベルも無いのに注入成功と誤判定) を返すため、
  // コピペ前に呼ばれた場合は例外で fail closed にする (fail-open で完了ゲートの実在検証をすり抜けさせない)
  const makeFrame = (target) => { throw new Error('makeFrame is a TODO placeholder: 主経路 L34-L100 をコピペしてから使うこと (anchorName を返す実装が必要)'); };
  const addLabel = (target, labelText) => { throw new Error('addLabel is a TODO placeholder: 主経路 L103-L106 をコピペしてから使うこと'); };

  let firstSuccessIndex = -1;
  const results = targetTexts.map((text, index) => {
    const resolved = findOne(text);
    if (resolved.reason) return { index, ok: false, reason: resolved.reason };
    makeFrame(resolved.target);
    const r = resolved.target.getBoundingClientRect();
    const rect = { top: r.top, left: r.left, w: r.width, h: r.height };
    if (firstSuccessIndex === -1) {
      firstSuccessIndex = index;
      // 列挙順で最初に解決成功した要素にだけ label を付与 (主経路の firstAnchor === null 分岐と同型)
      if (label) addLabel(resolved.target, label);
    }
    return { index, ok: true, rect };
  });

  // ok は主経路と同じ contract: results に 1 件でも ok:true があれば true
  // (全要素が not-found / ambiguous なら ok: false を返し、呼び出し側で完了ゲート正当 skip 判定へ)
  return { ok: results.some((r) => r.ok), label, results };
}
```

呼び出し側 (Chrome DevTools MCP) では `args` を省略するか空配列を渡す:

```text
evaluate_script({ function: <上記関数ソース> })
// または
evaluate_script({ function: <上記関数ソース>, args: [] })
```

**設計メモ**:

- **`args` は uid 専用**: 主経路の `args` は uid 解決機構で、テキスト解決には使えない。代替経路は `args` を渡さず関数内で `document.querySelector` 系で解決する経路を取る (`args: []` でも等価。`(...els)` は空配列がバインドされて関数内未使用)。Scroll-sync snippet と同じ I/O モデル
- **代表要素の決め方**: 主経路 (`args` 先頭から解決成功した最初の uid) と代替経路 (`targetTexts` の列挙順で解決成功した最初の要素) で同型。いずれも呼び出し側 (Claude) が「その箇所を一言で表す主要素」を列挙順先頭に置く。`targetTexts[0]` が `not-found` / `ambiguous` で失敗しても、後続要素の最初の成功要素に label が付与される
- **失敗要素のリカバリ** (SKILL.md Step 4 手順 5 代替経路リカバリ): 失敗要素の可視テキストを近傍ユニークなテキスト・selector に変更して関数ソース内 literal を書き換えて部分再注入する (`label = ''` で枠のみ)。`take_snapshot` 再取得で別 uid を選ぶ経路は uid が無いため使えない。**`makeFrame` をコピペする際は主経路の dedup ガード (`framed` Map + `data-manual-verify-anchor-host` 属性の二重チェック) も併せて流用すること** — retry バッチが前バッチ済みの要素に再解決した場合、ガード無しの `makeFrame` は対象の `anchor-name` を上書きし先行枠の `position-anchor` 解決を壊す。主経路と同型の冒頭ガード ("既に `data-manual-verify-anchor-host` を持つ要素は枠生成 skip + `duplicateOf` で既存 frame の anchorName を返す") を wrapper の `makeFrame` 内にも保持する
- **代表絞り込み (item 5 宣言要件)**: 試行後も一部要素が `not-found` / `ambiguous` で一意特定不能なケースに限り、特定できた要素のみで進めて完了ゲート item 5 で宣言する。最初から代表絞り込みで済ませてよいわけではない。**部分失敗 (一部成功 + 一部失敗) は完了ゲートの「正当 skip」対象外**で、特定できた要素で注入を継続する (SKILL.md 「正当 skip の扱い」は「変更要素が 1 つも一意特定できない」場合のみ該当)
- **失敗 reason の語彙**: 代替経路では text 不一致を `'not-found'` で返す (Scroll-sync snippet と同じ)。主経路 (uid 経路) の `'zero-rect'` (rect 全ゼロの非表示クローン) は別状態で、両者は意味が異なる。SKILL.md「正当 skip の扱い」と troubleshooting「`take_snapshot` が token 上限で truncate される」行の「正当 skip / 代表絞り込み」条件は代替経路の `'not-found'` / `'ambiguous'` を指す (行番号は編集で動くため見出し参照)
- **textless controls (form input / icon button / aria 名のみの要素) の制約**: 本 wrapper の `findOne` は **`visibleText` 一致** で要素を特定するため、可視テキストを持たない要素 (form `<input>` / `<button>` の icon-only / `aria-label` のみで装飾 label / placeholder のみ等) は親要素の label テキストにマッチしてラッパーを枠付けする / `ambiguous` で失敗する可能性がある。対処: (a) Step 2 で textless control の**近傍可視テキスト** (ラベル text・値セル text・親 section 内のユニークな text) を `targetTexts` に列挙し findOne でその近傍要素を取得後、agent が手動で `closest()` / `querySelector(':scope > input')` 等で対象 control を絞り込む。(b) ラベル要素自体に対象 control への `for=` 関係や `aria-labelledby` がある場合は label 要素を `findOne` で特定して `document.getElementById(label.getAttribute('for'))` で対象に到達する。これらの per-target selector / accessibility lookup は本 wrapper の orchestrator scope を超えるため、本 PR では補足にとどめ完全実装は将来の改善で対応する (本 PR の目的は anti-pattern の構造的拒否)

## Cleanup snippet

reload で overlay は消える。**SPA 内遷移 (full reload なし) では `document.body` 直下の fixed 要素は残存しうる**ため、同一ページ上で明示削除したいとき、または別ルート確認に進む前に実行する:

```js
document
  .querySelectorAll('[data-manual-verify-anchor-frame], [data-manual-verify-label]')
  .forEach((n) => {
    if (n._mvCleanup) n._mvCleanup();
    n.remove();
  });
document.querySelectorAll('[data-manual-verify-anchor-host]').forEach((el) => {
  el.style.anchorName = el.getAttribute('data-manual-verify-anchor-host') || '';
  el.removeAttribute('data-manual-verify-anchor-host');
});
// 条件付き発火で注入した検証用 <style> も除去する (Force-trigger snippet 参照)
document
  .querySelectorAll('style[data-manual-verify-force-trigger]')
  .forEach((n) => n.remove());
```

## Force-trigger snippet

SKILL.md Step 4「条件付き発火」で使う。**差が default 画面では出ない変更**（横スクロール overflow が有効なときだけ効く footer の `pb-*`→`mb-*`、`:hover`/`:focus`、error/empty 状態、既定で不可視な overlay スクロールバー等）について、群内 3 タブ（①②③）に**同一の発火**を注入して比較可能な状態を作る。各タブを `select_page` で選択してから `evaluate_script` で実行する。overlay 注入・スクロール同期の**前**に行う。

設計上の不変条件 (SKILL.md「条件付き発火」と対):

- **全タブに同一発火** — base/PR で発火条件を揃える (片方だけ発火させると差が発火の有無に化ける)
- **比較対象プロパティに触れない** — トリガー条件だけを作る。比較する `pb`/`mb` 等は変えない (対象 box の padding/margin を書き換えず overflow を起こす)
- **検証用 `<style>` に `data-manual-verify-force-trigger` を付ける** — Cleanup snippet / reload で除去できるようにする
- **既定で不可視な指標は可視化する** — overlay スクロールバーは常時表示 + 対比色 (自然描画でない検証用の可視化)

下記は session で実際に踏んだ「`overflow-x-auto` footer の `pb-1`→`mb-1`」を一般化した例。対象セレクタ・強制幅は箇所ごとに書き換える:

```js
() => {
  // 比較対象 (footer のスクロールバー余白) を出すため、footer を絞って横スクロールを強制発火する。
  // padding/margin は触らず max-width のみ絞る (比較対象プロパティを潰さない)。
  const targetSelector = '.search-footer'; // 該当箇所の対象を一意に指すセレクタに書き換える
  // 再実行 (max-width 絞り直し等) や対象不在でも残留しないよう、まず既存の発火 style を除去 (idempotency)
  document.querySelectorAll('style[data-manual-verify-force-trigger]').forEach((n) => n.remove());
  const el = document.querySelector(targetSelector);
  // 対象不在は誤セレクタ / 未描画。style を注入せず fail を返す (発火後状態を残さない)
  if (!el) return { ok: false, hasScroll: false, metrics: null };
  const css = `
    /* overflow-x: auto は対象が元々スクロールコンテナでなくてもバーを出すため含める (既に持つ対象には無害) */
    ${targetSelector} { max-width: 420px !important; overflow-x: auto !important; }
    /* overlay スクロールバーを常時表示 + 赤で可視化 (検証用) */
    ${targetSelector}::-webkit-scrollbar { height: 8px; }
    ${targetSelector}::-webkit-scrollbar-thumb { background: red; }
  `;
  const style = document.createElement('style');
  style.setAttribute('data-manual-verify-force-trigger', '');
  style.textContent = css;
  document.head.appendChild(style);
  // metrics は発火判定用の scroll 計測 (DOMRect ではない。overlay 注入関数の rect とは別物)
  const metrics = { scrollWidth: el.scrollWidth, clientWidth: el.clientWidth };
  // hasScroll が true なら発火成功。false なら max-width をさらに絞る / overflow 未設定を疑う
  return { ok: true, hasScroll: metrics.scrollWidth > metrics.clientWidth, metrics };
}
```

仕様メモ:

- **戻り値で発火を検証する**: `hasScroll: false` なら overflow が起きていない (強制幅が足りない / 対象セレクタ違い / 下記 overflow 未設定)。`max-width` を絞り直して再実行する。`metrics: null` + `ok: false` は対象不在 (誤セレクタ / 未描画)。`metrics` は発火判定用の scroll 計測で DOMRect ではない (overlay 注入関数の `rect` とは別物・別契約)。pseudo-state や error 状態の発火では `hasScroll` の代わりにその状態が反映されたか (class の付与・対象 DOM の出現等) を返して検証する
- **`overflow-x: auto` を含める理由**: 対象に元々 `overflow-x: auto` / `scroll` が無いと `max-width` で幅を絞ってもスクロールバーは出ず内容がはみ出る (または隠れる) だけ。本例は対象がスクロールコンテナか不明でもバーが出るよう `overflow-x: auto !important` を含めている (既に持つ対象には無害、持たない対象では必須。比較対象は `pb`/`mb` であり overflow は発火条件側のため base/PR 両タブに同一に当たって比較は保たれる)。スクロールでなく hover/error 等の発火ではこの宣言は外す
- **セレクタは対象を一意に指す**: example は `hasScroll` を先頭 1 要素 (`querySelector`) で計測する一方、CSS は一致する全要素に当たる。`document.querySelectorAll(targetSelector)` が 2 件以上なら計測対象と適用範囲がずれるため、一意なセレクタ (id・固有 class・`:nth-of-type` 等) に絞る
- **PR 前後でセレクタが変わる場合**: 「全タブに同一発火」は**発火条件の同一性**を指し、セレクタ文字列の同一性ではない。rename 等で対象の class/id が PR で変わるときは ② (base) に before セレクタ・③ (PR) に after セレクタを使う (Scroll-sync の例外 2〔テキスト変更〕と同型)。同一文字列を全タブに使うと一方で `ok: false` (対象不在) になり発火できない
- **`::-webkit-scrollbar` は Chromium 系専用**: Chrome DevTools MCP が操作するブラウザは Chromium のため本 snippet で可視化できる。Firefox 等での確認が要る場合は `scrollbar-color` / `scrollbar-width` 標準プロパティを使う
- **発火は overlay と独立**: 本 snippet は overlay (body 直下 fixed 要素) と別に対象自身を絞る。発火後に対象 rect が変わるが、CSS Anchor Positioning の枠は対象に追従するため overlay 注入を先にしても後にしても枠は対象を囲む。順序は「発火 → overlay 注入 → スクロール同期」を推奨 (発火後の最終レイアウトで枠位置・中央 Y を確定させる)
- **cleanup**: reload で消えるが、SPA 内遷移では残るため Cleanup snippet (`style[data-manual-verify-force-trigger]` を remove) で明示除去する

## Scroll-sync snippet

SKILL.md「タブ構成」のスクロール位置同期で使う。各群内で **①から順に各タブ**を `select_page` で選択してから `evaluate_script` で実行し、対象を viewport 中央へスクロールして中央 Y を計測する (群内 3 タブとも本 snippet で計測し、①の注入時 `rect` は比較に使わない)。`args` は使わない (uid はページごとの snapshot に紐づくため素タブでは流用できない) — 対象は **①で注入した要素と同じ可視テキスト** を関数ソース内のリテラルとして書き換えて検索する (画面の実テキストを引用していて `'` を含む場合はダブルクォートリテラルかエスケープを使う — SyntaxError で実行自体が失敗するため。注入関数の label と同じ注意):

```js
async () => {
  const text = '通知設定'; // 群内①の代表 (label を付けた最初の要素 = firstTarget) を一意に指す画面上の実テキストに書き換える。1 箇所に複数枠があるときも同期は代表要素基準
  const isVisible = (n) => {
    const r = n.getBoundingClientRect();
    return r.width > 1 && r.height > 1;
  };
  // 非表示 subtree (sr-only / display:none) を除いた可視テキストを連結する
  const visibleText = (n) =>
    [...n.childNodes]
      .map((c) =>
        c.nodeType === Node.TEXT_NODE
          ? c.textContent
          : c.nodeType === Node.ELEMENT_NODE &&
              (isVisible(c) || getComputedStyle(c).display === 'contents')
            ? visibleText(c)
            : '',
      )
      .join('');
  // マークアップ内の改行・インデント・&nbsp; を画面見た目の 1 スペースへ寄せる
  const normalize = (s) => s.replace(/\s+/g, ' ').trim();
  // innermost match: 同テキストを含む wrapper 連鎖から最内の可視要素のみ拾う
  const matches = [...document.querySelectorAll('body *')].filter(
    (n) =>
      isVisible(n) &&
      normalize(visibleText(n)) === normalize(text) &&
      ![...n.querySelectorAll('*')].some(
        (c) => isVisible(c) && normalize(visibleText(c)) === normalize(text),
      ),
  );
  if (matches.length !== 1) {
    return { ok: false, reason: matches.length === 0 ? 'not-found' : 'ambiguous' };
  }
  const target = matches[0];
  const centerY = () => {
    const r = target.getBoundingClientRect();
    return Math.round(r.y + r.height / 2);
  };
  // 遅延ロード (画像/font swap/lazy) で対象上のコンテンツが計測後に動き中央 Y がズレるため、計測が 2 回連続一致 (sample-stable) するまで再 scroll で収束させる
  // hidden / 非フォーカスで rAF が発火しないと Promise 未解決で evaluate_script がハングするため、setTimeout を backstop に rAF と競争させ先着で resolve する (visible は rAF×2 が勝ち 2 frame 確定、それ以外も 100ms で必ず resolve。100ms は 30Hz の 2 frame ≈66ms を上回り低リフレッシュ visible でも rAF を勝たせる幅)
  const twoFrames = () =>
    new Promise((res) => {
      let done = false;
      const resolve = () => {
        if (done) return;
        done = true;
        res();
      };
      setTimeout(resolve, 100);
      requestAnimationFrame(() => requestAnimationFrame(resolve));
    });
  let y = null;
  let settled = false;
  for (let i = 0; i < 8; i++) {
    target.scrollIntoView({ block: 'center', behavior: 'instant' });
    await twoFrames();
    const next = centerY();
    if (y === next) {
      settled = true;
      break;
    }
    y = next;
  }
  return { ok: true, y, settled };
}
```

仕様メモ:

- **`window.scrollTo` / `window.scrollY` を使わない**: アプリが window でなく内部コンテナ (`overflow: auto` の main 領域等) をスクロールする構造だと `window.scrollTo` は無効で `scrollY` は 0 のまま (実機で発生)。`scrollIntoView` はどの祖先がスクロールコンテナかに依らず機能する
- **戻り値は `{ ok, y, settled }`。`y` は対象 box 中央の viewport Y** (`r.y + r.height / 2`、`settled` は後述「再 scroll 収束ループ」bullet 参照): `block: 'center'` は要素 box の中央を viewport 中央へ寄せるため、top (`r.y`) を比較すると base / PR で要素高さが異なる変更 (見出し level・折返し等) で正しく中央寄せされていても偽性ズレが出る。①もこの snippet を実行して `y` を得る (overlay 注入の戻り値 `rect` は②・③構築中の遅延レイアウトで stale になりうるため比較に使わない)。成功条件・許容誤差・例外 (PR 新規要素 / テキスト変更) の SoT は SKILL.md「スクロール位置の同期」bullet
- **raw `textContent` でなく `visibleText` で比較する理由**: `textContent` は非表示 subtree のテキストも連結するため、(a) 可視ラベルと同一テキストの隠し子 (`display: none` のメタデータ等) が併存すると親のテキストが連結二重化して等価判定が落ち `not-found`、(b) テキストが sr-only 子にしか無い icon ボタンでは可視親が innermost から除外され `not-found`、の両方が起きる。可視 subtree のみを連結する `visibleText` を候補・最内判定の両方に使うことで一貫させる。この設計の帰結として **sr-only テキストでは対象を探せない** — 識別テキストが sr-only にしか無い対象は、両環境に共通する近傍の可視テキストを anchor に選ぶ (SKILL.md の例外 1 と同じ要領)
- **normalize (空白正規化) の理由**: 画面では 1 スペースに見えるテキストが HTML 上は改行 + インデントや `&nbsp;` でマークアップされていることがあり、生の連結文字列と画面見た目どおりの `text` リテラルが一致しない。`\s+` → 単一スペースの正規化を両辺に掛けて吸収する (JS の `\s` は ` ` = `&nbsp;` を含む)
- **可視判定が `> 1` の理由**: `display: none` は zero-rect だが、sr-only の代表実装は 1×1 px + clip で rect 非ゼロのため、`> 0` だと clip 型 sr-only が可視扱いになり上記 (a)(b) の除外契約と機構が乖離する。`visibility: hidden` / `opacity: 0` は rect が通常サイズのため本判定の対象外 (除外しない — 実害の Evidence が出るまで computed style 検査は導入しない)。なお注入関数側の `isVisible` は zero-rect クローン検出が目的のため `> 0` のまま (用途が異なる)
- **`display: contents` の透過と最内判定の子孫走査**: `display: contents` は box を生成せず rect ゼロだが子は描画されるため、visibleText の降下条件に `display === 'contents'` を加える (加えないと wrapper 配下の可視テキストが落ちて not-found)。最内判定は**直接の子でなく子孫全体** (`querySelectorAll('*')`) から「box を持つ同テキスト要素」の有無で行う — 直接の子だけ見ると contents の透過をどちらに倒しても穴が出る (透過しないと可視 div > contents > 可視 span で両方 match して ambiguous、透過すると `<button><span style="display:contents">…</span></button>` のように contents 子が唯一のテキスト保持者のケースで唯一の box 親が除外され not-found)。**候補**は box を持つ要素に限定したまま (box の無い要素は scrollIntoView / 中央 Y 計測の対象として不安定なため)
- **`behavior: 'instant'` の理由**: 対象アプリが `scroll-behavior: smooth` をグローバル有効化していると、既定 (`behavior: 'auto'` = CSS に従う) ではスクロールがアニメーションになり、直後の `getBoundingClientRect()` が完了前の過渡座標を返して中央 Y 検証が偽性失敗する。`'instant'` は CSS 指定に関わらず同期的にスクロールを確定させる (注入関数側の `scrollIntoView` も同様)
- **再 scroll 収束ループ (`settled`) の理由**: `scrollIntoView` + 単発計測では、対象**より上**の遅延ロード要素 (寸法未指定画像・web font swap・lazy コンポーネント) が計測後にレイアウトを動かすと、scroll 量は固定のまま中央 Y が数 px ズレる (`wait_for` は対象テキスト自身の出現を待つだけで対象より上の確定は保証しない)。`scrollIntoView` は毎回現在のレイアウトで再センタリングするため、double-`requestAnimationFrame` (1 frame の layout+paint 確定待ち。single rAF は paint 前に発火する) を挟んで再 scroll + 再計測を**連続 2 回一致まで**繰り返す (上限 8 回)。`settled: true` が保証するのは **sample-stable (直近 2 計測サイクルで中央 Y が不変)** であって「レイアウト確定」ではない — 返却後にさらに遅延ロードが入れば再シフトしうるが、その残余はタブ間 |Δ| 比較と SKILL.md の `wait_for` 再実行で扱う (snippet 単体で layout 完了を待ち切らない責務分界)。`settled: false` (上限まで不一致) は連続アニメーション等でレイアウトが止まらないことを示し、その `y` はタブ間 |Δ| 比較の信頼度が低い (再同期・待機の判断材料)。本ループで人手の「微妙にズレてる」指摘→再同期の round-trip の多くを snippet 内で吸収する。`evaluate_script` は `async` 関数を await するため `await` がそのまま機能する。`twoFrames` を double-rAF 単体でなく `setTimeout(100)` を backstop に rAF と競争させ先着 (`done` guard) で resolve するのは、hidden / 非フォーカスで rAF callback が発火せず Promise が未解決のまま `evaluate_script` がハングするのを防ぐため (visible は rAF×2 が勝ち 2 frame 確定待ち、それ以外も 100ms で必ず resolve。`document.hidden` の時点判定では visible だが rAF が発火しない edge を取りこぼすため race にする)。backstop を 100ms にするのは 30Hz の 2 frame ≈66ms を上回り低リフレッシュ visible でも timer が rAF を追い越さないため (backstop が効くのは rAF 非発火時のみで、common path の visible は常に rAF×2 が勝つ)
- **テキスト検索にする理由**: tagName で絞ると PR が要素の tag 自体を変える変更 (見出し level 変更等) で base 側と一致しなくなる。可視テキスト一致 + innermost 絞り込みで両環境共通に解決する。複数一致 (`ambiguous`) はより一意なテキスト (近傍の値セル等) に選び直して再実行する (注入関数と同じ fail closed)
- **①と素タブで対象テキスト自体が異なる場合** (PR がテキストを変える変更): ② (base) には before テキスト、③ (PR) には after テキストをそれぞれリテラルに書く (成功条件は SKILL.md の例外 2 参照)

## 方式比較 (実機検証で確立した順)

| 方式 | scroll lag | CPU | thread | 採否 |
|------|-----------|-----|--------|------|
| 対象要素に `outline` 直当て | — | — | — | **NG**: 祖先 `overflow-x: auto` で上辺がクリップされる |
| `position: fixed` overlay + `scroll` listener | 1–複数 frame | 低 | main | fallback |
| `position: fixed` overlay + `requestAnimationFrame` loop | 体感ゼロ | 常時 60Hz 浪費 | main | 不採用 |
| **CSS Anchor Positioning** | **ゼロ** | **ゼロ** | **compositor** | **第一選択** |

### `outline` が NG な理由 (W3C 仕様)

`outline` は祖先の `overflow: hidden/auto/scroll` で padding box にクリップされる ([W3C CSS 2.2 §11.1](https://www.w3.org/TR/CSS22/visufx.html))。さらに `overflow-x: auto` を指定すると CSS 仕様で `overflow-y: visible` が `auto` に強制昇格される ([drafts.csswg.org/css-overflow](https://drafts.csswg.org/css-overflow/) "computed value" rule)。結果、横スクロール用に `overflow-x-auto` を持つ Tailwind コンポーネント等で、対象ボタンの outline 上辺だけが祖先境界でカットされる。実機検証では `outline-offset: 2px` + `outline-width: 3px` の組み合わせで上 5px が消えた。

### CSS Anchor Positioning が compositor で動く理由

scroll-driven 系のプロパティと同様、anchor 追従は paint 段階のスタイル解決ではなく compositor thread の transform として処理される ([Chrome for Developers: scroll-driven animations performance](https://developer.chrome.com/blog/scroll-animation-performance-case-study))。JS が main thread を専有していても overlay は scroll に**完全同期**する。

## 参考資料

- [Using CSS anchor positioning - MDN](https://developer.mozilla.org/en-US/docs/Web/CSS/Guides/Anchor_positioning/Using)
- [CSS Anchor Positioning Module Level 1 §anchor() - W3C Editor's Draft](https://drafts.csswg.org/css-anchor-position-1/#anchor-pos)
- [outline - MDN](https://developer.mozilla.org/en-US/docs/Web/CSS/outline)
- [CSS Overflow Module Level 3 - W3C Editor's Draft](https://drafts.csswg.org/css-overflow/)
- [Visual effects: Overflow, clipping - W3C CSS 2.2 §11.1](https://www.w3.org/TR/CSS22/visufx.html)
- [A case study on scroll-driven animations performance - Chrome for Developers](https://developer.chrome.com/blog/scroll-animation-performance-case-study)
