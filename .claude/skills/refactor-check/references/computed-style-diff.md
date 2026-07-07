# computed-style fingerprint の抽出と差分

SKILL.md の Step 4 の詳細。base と PR で同じ要素を突き合わせ、`getComputedStyle` の値 + visible text + geometry を property 単位で差分する手順の本体。

## Contents

- 要素の対応付け (correspondence) の考え方
- fingerprint 抽出関数 (`evaluate_script` に渡す全文)
- 抽出する property の既定集合と根拠
- 差分の解釈 (信頼度の分類・サブピクセル許容・構造差)
- 既知の落とし穴
- 背景

## 要素の対応付け (correspondence) の考え方

リファクタは DOM 構造を変えうる (wrapper の add/remove、`h5 > h2` を `h2` 単独へ、クラスの付け替え)。そのため **CSS セレクタや DOM パスで base と PR を突き合わせてはならない** — 構造が変わると同じセレクタが別物を指す。

代わりに **画面に表示されるテキスト (visible text) を対応キー**にする。同じ見出し・ラベル・セル値は、構造が変わっても同じ文字列としてレンダリングされる。テキストから、それを実際に描画している**最も内側 (leaf-most) の可視要素** (= text leaf) を選ぶ。突き合わせは text のみで行い、geometry (`rect`) は突き合わせには使わず**比較する fingerprint の一部**として記録する。

`getComputedStyle` は **used value (解決済みの値)** を返す。base が色トークンのクラス、PR がインラインや別経路でも、最終的に効いた `color` が `rgb(...)` で返るため、実装手段の違いを跨いで純粋に「観測される見た目」を比較できる。

**継承系と box 系で測る要素を分ける**: text leaf は透明な inline wrapper (`<button><span>保存</span></button>` の `span` 等) のことがある。`color` / `font*` 等の**継承プロパティ**は leaf で正しく取れるが、`backgroundColor` / `padding*` / `border*` / `width` 等の**非継承プロパティ**は親 (button) に乗っており leaf では default が返る。そこで継承系は leaf で、box 系は leaf を含む**最も近い box を生成する祖先 (layout box)** で測る。`<button>` は既定 `display: inline-block` なので自前の box を持つ — `inline-block` / `inline-flex` 等は layout box として採用し、`display: inline` / `contents` のみ透過する。

## fingerprint 抽出関数 (`evaluate_script` に渡す全文)

下記は **arrow 関数式**で、Chrome DevTools MCP の `evaluate_script` の `function` 引数に**この式全体をそのまま渡す** (MCP は渡された関数式を invoke して戻り値を返すため、`function foo(){}` の宣言形では結果が返らない)。`anchorTexts` を**関数ソース内のリテラル**として埋め、対象 route ごとに対応キー (表示テキスト) を入れて使う。**`args` には何も渡さない** — `args` の全要素は element uid として解決されるため、文字列を渡すと失敗する。base タブと PR タブで**同じ関数**を実行し、返った配列を `anchor` で突き合わせる。

```js
() => {
  // 対象 route の対応キー (画面に表示される一意なテキスト) をここに列挙する
  const anchorTexts = [
    "品目を新規登録",
    "保存",
  ];

  // 継承プロパティ (テキストの見た目): text leaf で測る
  const INHERITED = [
    "color", "fontSize", "fontWeight", "fontFamily", "fontStyle",
    "lineHeight", "letterSpacing", "textAlign", "textTransform",
    "whiteSpace", "visibility",
  ];
  // 非継承プロパティ (box / 装飾): leaf が透明な inline wrapper のことがあるため layout box で測る。
  // shorthand (border-radius 等) は getComputedStyle で値が返らない実装があるため longhand を並べる
  const BOX = [
    "backgroundColor", "opacity", "display", "width", "height",
    "borderTopWidth", "borderTopStyle", "borderTopColor",
    "borderRightWidth", "borderRightStyle", "borderRightColor",
    "borderBottomWidth", "borderBottomStyle", "borderBottomColor",
    "borderLeftWidth", "borderLeftStyle", "borderLeftColor",
    "borderTopLeftRadius", "borderTopRightRadius",
    "borderBottomRightRadius", "borderBottomLeftRadius",
    "paddingTop", "paddingRight", "paddingBottom", "paddingLeft",
    "marginTop", "marginRight", "marginBottom", "marginLeft",
    "textDecorationLine",
  ];

  const norm = (s) => (s || "").replace(/\s+/g, " ").trim();
  // display:none は layout box が消えるため getClientRects で、visibility は継承値で捕捉できる。
  // display:contents は box を持たない (rect なし) が text は描画されるため除外しない。
  // opacity は非継承なので、自要素が opacity:1 でも opacity:0 の祖先配下なら不可視 → 祖先を遡る
  const visible = (el) => {
    const cs = getComputedStyle(el);
    if (el.getClientRects().length === 0 && cs.display !== "contents") return false;
    if (cs.visibility === "hidden") return false;
    for (let n = el; n; n = n.parentElement) {
      if (getComputedStyle(n).opacity === "0") return false;
    }
    return true;
  };
  // layout box = 自要素を含む最も近い「box を生成する」祖先。
  // inline-block / inline-flex 等は自前の box / bg / border を持つので採用し、inline / contents のみ透過
  const boxOf = (el) => {
    for (let n = el; n; n = n.parentElement) {
      const d = getComputedStyle(n).display;
      if (d !== "inline" && d !== "contents") return n;
    }
    return el;
  };
  const pick = (el, props) => {
    const cs = getComputedStyle(el);
    const o = {};
    for (const p of props) o[p] = cs[p];
    return o;
  };

  // 先に anchor を含む候補へ粗く絞り、全 body 要素への getComputedStyle を避ける
  const all = Array.from(document.querySelectorAll("body *"))
    .filter((el) => { const t = norm(el.textContent); return anchorTexts.some((a) => t.includes(norm(a))); })
    .filter(visible);
  const results = [];

  for (const anchor of anchorTexts) {
    const target = norm(anchor);
    // visible text は innerText で照合する (textContent は display:none 子孫の文字も含む)
    const exact = all.filter((el) => norm(el.innerText) === target);
    const partial = exact.length === 0;
    const pool = partial ? all.filter((el) => norm(el.innerText).includes(target)) : exact;
    if (pool.length === 0) { results.push({ anchor, ok: false, reason: "not-found" }); continue; }

    // 他の候補を含まない要素 = 最も内側で描画している候補 (leaf-most)。
    // 別サブツリーに複数残れば (完全一致せず text が異なる partial 候補が並ぶ場合も) 突き合わせ不能
    const leaves = pool.filter((a) => !pool.some((b) => a !== b && a.contains(b)));
    if (leaves.length > 1) { results.push({ anchor, ok: false, reason: "ambiguous" }); continue; }
    const best = leaves[0];

    const box = boxOf(best);
    const r = box.getBoundingClientRect();
    results.push({
      anchor,
      ok: true,
      match: partial ? "partial" : "exact",
      tag: best.tagName.toLowerCase(),
      boxTag: box.tagName.toLowerCase(),
      text: norm(best.innerText),
      // x/y も記録する: width/height だけでは margin/order/container 変更等による
      // 純粋な位置シフト (サイズ不変) を検出できない
      rect: { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) },
      // 継承系は leaf、box 系は layout box で測る (非継承 box プロパティが祖先にあるため)
      styles: { ...pick(best, INHERITED), ...pick(box, BOX) },
    });
  }
  return results;
}
```

base タブと PR タブそれぞれで `evaluate_script` にこの関数式を渡し、返った 2 つの配列を `anchor` で対応付け、両タブ `ok: true` かつ `match: "exact"` の anchor のみ **`styles` / `rect` を比較する** (`text` は対応キーと同値なので差は出ない)。`ok: false` (reason: `not-found` / `ambiguous`)、`match: "partial"`、または片側でしか `ok: true` にならない anchor は突き合わせが不確実なので、**`styles` / `rect` の差を regression として report せず**、表示テキストの変更 (content 変更) を疑いつつ対応キーを見直す (correspondence failure として扱う)。

## 抽出する property の既定集合と根拠

`getComputedStyle` は ~400 個の property を返すが、その大半は default や同一継承値で base/PR が一致するため、全件比較はノイズになる。既定集合は **見た目に直結し、リファクタで変わりうる** ものに絞っている。`INHERITED` 先頭の継承系 (`color` / `font*` / `lineHeight`) は、クラスや wrapper を削った結果**親からの継承で変わる**典型穴 (本スキルの主目的) のため最優先。`border*` は 4 辺すべて (input の下線・tab・divider 等は bottom/left/right border の変更が多い)、`border-radius` は shorthand が getComputedStyle で空を返す実装があるため 4 隅 longhand で並べる。

diff が触れた property がこの集合に無い場合 (例: `boxShadow` / `gap` / flex 系 / `zIndex`) は、その route の変更内容に応じて `INHERITED` / `BOX` のどちらかに足す。逆に明らかに無関係な property を足してノイズを増やさない。

## 差分の解釈 (信頼度の分類・サブピクセル許容・構造差)

- **表示テキストの変更**: `text` は対応キーそのもので、両タブ `match: "exact"` 一致時は同値 (差は出ない)。表示テキストが変わると anchor は片側で `ok: false` / `match: "partial"` になる「突き合わせ非対称」として現れる。これは「振る舞いを変えない」リファクタではなく content 変更の候補なので、消えてはいけないテキストの欠落か意図した copy 変更かを確認して報告する
- **高信頼 (離散値の style 差は実 regression とみなす)**: `color` / `backgroundColor` / `border*Color` / `fontWeight` / `fontSize` / `fontStyle` / `textDecorationLine` / `border*Style` / `display` / `visibility`。これらが base と PR で違えば、ほぼ確実に意図しない変化。最優先で報告する
- **低信頼 (連続値の微差はレンダリング誤差)**: `width` / `height` / `padding*` / `margin*` / `rect`（`x`/`y`/`w`/`h` いずれも）が **1px 未満**でずれる場合はフォントレンダリング由来の誤差の可能性が高い。低信頼として扱う。ただし **数 px 以上の geometry 差は実 regression** (レイアウトがずれている、または `margin`/`order`/コンテナ変更等でサイズを保ったまま位置だけがシフトしている) なので高信頼に格上げする
- **突き合わせ不成立 (`styles` / `rect` を信用しない)**: ある対応キーが base で `ok: true` だが PR で `ok: false` (または逆)、`reason: "ambiguous"`、または `match: "partial"` のときは要素を正しく突き合わせられていない。この場合 `styles` / `rect` の差は誤要素由来の偽陽性・偽陰性なので regression として report せず、対応キーを一意化して測り直す。wrapper の add/remove ならテキストが残っているリーフ要素同士で再測定する
- **box プロパティの出所**: `boxTag` が `tag` と異なるとき、box 系 (`backgroundColor` / `padding*` / `border*` 等) は text leaf ではなく layout box 祖先で測られている。base/PR で `boxTag` が食い違う場合は構造変化を疑う
- base/PR の **viewport / window サイズが不一致**だと全 geometry に差が出る。両タブを同一サイズで開いていることを先に確認する

## 既知の落とし穴

| 症状 | 原因 / 対処 |
|------|------------|
| `reason: "not-found"` が返る | テキストが操作で隠れている (モーダル未表示・ドロップダウン未展開)。両タブで同じ `click` を実施してから再測定する |
| `reason: "ambiguous"` が返る | 同じ/部分一致テキストの candidate が別サブツリーに複数ある。対応キーをセクション見出し等で限定するか、より一意なテキストに変える |
| `match: "partial"` が返る | 完全一致が無く部分一致で拾っている (例 anchor "合計" が「合計金額」に部分一致)。誤要素の可能性があるため対応キーを完全一致するテキストにする (style 差は信用しない) |
| 全 property が一致するのに見た目が違う気がする | `boxTag` を確認。box 系が想定外の祖先で測られている場合や、対象が複数の box に跨る場合は対応キーを変える |
| box 系 property (`backgroundColor` / `border*` / `padding*` 等) の regression が検出できない | **既知の制限**: `boxOf` は「box を生成する最も近い祖先」(`display` が `inline`/`contents` でない要素) を採用するため、実際にスタイルを持つ要素 (button, card 等) の**内側**に `display: block` の透明なラッパー (`<span class="block">` 等) があると、そのラッパーで測定が止まり、外側の本来スタイル変更を検出したい要素まで届かない。`boxTag` がテキスト内容から見て意外な要素名なら、`text` を持つ要素を減らす等で対応キーを更に内側の control 直下のテキストに変えるか、`getComputedStyle` を手動で祖先方向に追加確認する |
| `args` を渡したら `Element uid ... not found` で失敗 | 文字列を `args` に渡している。`anchorTexts` は関数ソースに埋め、`args` は空にする |
| 関数を渡しても結果が返らない / undefined | `function foo(){}` の宣言形を渡している。`() => { ... }` の arrow 関数式をそのまま渡す |

## 背景

リファクタは「外部から観測できる振る舞いを変えずに内部構造を変える」操作 ( [https://martinfowler.com/bliki/Yagni.html](https://martinfowler.com/bliki/Yagni.html) の前提と同じ「振る舞い保存」)。その不変条件を**観測出力のスナップショット差分**で守るのは characterization test / golden master の考え方 ( [https://en.wikipedia.org/wiki/Characterization_test](https://en.wikipedia.org/wiki/Characterization_test) )。本スキルはそれを frontend に適用し、pixel ではなく `getComputedStyle` ( [https://developer.mozilla.org/en-US/docs/Web/API/Window/getComputedStyle](https://developer.mozilla.org/en-US/docs/Web/API/Window/getComputedStyle) ) の used value を property 単位で差分することで、継承で変わった color 等の「画面では気づきにくい差」を機械的に捕捉する。
