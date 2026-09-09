# 2026-07-14 の一連の修正に対するコードレビュー指摘

2026-07-14 のコミット群（dommy d1a7f04..HEAD、dommy-js-quickjs d8309d0..HEAD）を
6 アングルでレビューし、検証を通過した指摘。上から重大度順。
修正したら `[x]` にして修正コミットを併記する。

## 要修正（正しさ）

- [x] **R1. trace の thread-local がアプリ例外時にリークする**
  `gems/dommy-rack/lib/dommy/rack/trace.rb`（__internal_on_request / on_response）。
  `Thread.current[:__dommy_active_trace__]` と `@pending_spans` は on_response で
  しか解除されないが、HttpExchange#call は `@app.call` を ensure なしで呼ぶ。
  アプリが raise すると thread-local が残留し、以後同スレッドの全
  ActiveSupport::Notifications（テスト本体の SQL 等）が死んだ trace に蓄積され、
  次のリクエストで無関係な http 行に parent 付けされて flush される。
  修正方針：HttpExchange の request/response ブラケットを例外安全にする
  （exchange 層で ensure）か、trace 側の on_request で前回分を必ず掃除する。

- [x] **R2. RuleIndex の class 分割が HTML ASCII 空白と不一致**
  `gems/dommy/lib/dommy/internal/css/rule_index.rb` each_candidate_entry。
  `classes.split`（Ruby 既定、\v を含む）で分割しており、`class="a\vb"`
  （HTML 上は 1 トークン）が ["a","b"] に割れて `.a\vb` ルールのバケツが
  参照されず、宣言が cascade から静かに消える。selector_index.rb で今回
  直したのと同種のバグの作り込み。`/[ \t\n\f\r]+/` に統一する。
  （修正時の追記：lexbor は \00000B エスケープ入りセレクタを drop するため現状の
  sheet 経路では発火不能と確認。bucket 充填側との整合性強化として修正）

- [x] **R3. streaming + snapshots で artifact 行の content が常に欠落**
  `gems/dommy-rack/lib/dommy/rack/trace.rb` __internal_snapshot_dom。
  `__internal_emit`（= stream 書き込み）の後に `@artifacts[event.seq] = html`
  が実行されるため、StreamingArtifacts#[] が常に nil を返す。
  格納を emit より先に行える構造（seq 予約 or 引数渡し）に直し、
  snapshots 付きの stream 一致テストを追加する。

- [x] **R4. JS 側イベントの stop propagation フラグが dispatch 後に解除されない**
  `gems/dommy/lib/dommy/js/host_runtime.js`（dispatchEvent slow path）。
  DOM 仕様は dispatch 終了時に stop フラグを解除するが、state.stopped が
  残り続け、同一イベントの再 dispatch で twin.stopPropagation() を再適用して
  しまう。slow path の finally で state.stopped を false に戻す。

- [x] **R5. prototype 抽出経由の host 呼び出しに JS イベントを渡すと壊れる**
  `gems/dommy/lib/dommy/js/host_runtime.js` memberMethodStub。
  `EventTarget.prototype.dispatchEvent.call(el, ev)` のような呼び方は proxy
  get trap のラッパーを通らず、JS イベントが opaque な __rb_js_ref として
  dehydrate され Ruby の dispatch_event が失敗する（host イベント時代は
  動いていた退行）。memberMethodStub（少なくとも dispatchEvent）で JS
  イベントを検出して proxy ラッパーと同じ経路に載せる。

- [x] **R6. slot 属性変更が cascade キャッシュを無効化しない（要再現確認）→ 反証・修正不要**
  再現を 2 通り（index 未構築 / 構築済み）試みたがどちらも正しく再計算された。
  理由：Cascade#computed_style は not_rendered? を**キャッシュ参照より前に毎回
  素で評価**し、{} の結果はキャッシュに入れないため、slot 変更（assigned_slot
  の変化）は次の読みで必ず反映される。::slotted マッチングの方は依存集合の
  slot/name で既にカバー済み。
  `gems/dommy/lib/dommy/document.rb` __internal_style_affected_by_attribute__。
  slot 属性はセレクタ依存集合に載らない限り style_generation を動かさないが、
  Cascade#not_rendered? は assigned_slot（slot 属性で決まる）を読むため、
  shadow ページで未スロット→スロット化の変更後も computed が {} のまま
  返りうる。まず再現テストを書き、slot/name を（shadow root 存在時の）
  常時依存に含めるか、not_rendered? 経路の依存として明示する。

- [x] **R7. host イベント proxy の initCustomEvent が defaultPrevented shadow を
  無効化しない**
  `gems/dommy/lib/dommy/js/host_runtime.js`。shadow 無効化は
  preventDefault / initEvent / returnValue / 再 dispatch の列挙で守られて
  いるが、Ruby 側で canceled をリセットする initCustomEvent が漏れている。
  canceled 状態を変えうるメソッド名の単一集合（choke point）に寄せる。

- [x] **R8. masked_binds が ParamFilter を毎回生成し、設定済みフィルタを無視**
  `gems/dommy-rails/lib/dommy/rails/trace_instrumentation.rb`。
  SQL 通知のたびに `ParamFilter.new(DEFAULT)` を生成（最ホットな topic で
  純粋なオーバーヘッド）。さらに DEFAULT 固定のため、アプリが
  filter_parameters 由来のカスタムキーを設定していても bind 値には適用
  されない。フィルタをメモ化し、可能なら thread-local 経由で当該 trace の
  設定済みフィルタを使う。

## 低優先（品質・効率、対応任意）

- [x] Q1. `declinedSetProps` が無制限成長（React の `__reactFiber$<乱数>` は
  ロード毎に変わる）— 他キャッシュ同様の cap を付ける
- [x] Q2. set trap の fast path が全書き込みに regex + 文字列連結を追加 —
  per-interface Set を makeHandler closure に持ち上げる
- [x] Q3. `collect_dependencies` 調査中に**正しさバグを発見・修正**：
  early-return が `@all_attr_deps` で打ち切られ、未マップ疑似クラスより後ろの
  `:empty`/`:blank` が text-sensitivity 収集から漏れて characterData 変更で
  cascade が stale になっていた（属性軸とテキスト軸は独立）。両軸が maxed に
  なるまで歩くよう修正。効率案（PARSE_CACHE への依存集合同居）は据え置き：
  依存集合は live な media 環境に依存する（マッチ中の @media のみ走査）ため
  text だけをキーにしたキャッシュは不健全、かつ text-sensitivity 収集が
  全走査を要するようになったので早期打ち切りの余地が減った
- [x] Q4. `__internal_inside_style_element__` が `<style>` ゼロの文書でも
  毎テキスト編集で祖先歩行 — sheet-elements メモで早期 return
- [x] Q5. `makeJsEvent` が 1 構築あたり約 20 defineProperty — interface 別の
  中間 prototype に共有メンバを寄せる
- [x] Q6. `stream_to` の未 finish（dispose 時）と二重呼び出し時の File リーク
- [~] Q7. `fragment_generation` が一発失効 → **据え置き（安全側、要設計）**。
  検証：`<template>` を含むページのパースで global counter が 0→1 に bump し、
  process-global なので**別文書の fragment parse が無関係な文書の cache の
  検証スキップを無効化**する（レビュー指摘どおりの cross-document 汚染）。
  正しい修正は per-backend-arena（Makiri は arena 内でのみ pointer を recycle
  するため per-document 計数が健全）だが、実装は WeakMap（Ruby バージョン依存）
  か backend オブジェクトへの ivar 注入（脆い）か D1d が集約した呼び出し箇所の
  再分散のいずれかを要する。現状は**正しさは保たれ**（安全側に倒れ、per-hit
  検証に戻るだけ）、影響は `<template>`/shadow を使うページでの有界な per-hit
  C 往復コストのみ。再武装は不健全（recycle された pointer は永続的に stale の
  ため、armed window 中の hit が誤 wrapper を返す）ので不可。D1d が守る recycle
  バグの再導入リスクに見合わないため据え置く
- [x] Q8. `PSEUDO_CLASS_ATTR_DEPS` と matcher のドリフト防止テスト
  （matcher 対応疑似クラスの全列挙 assert）
- [x] Q9. `to_ndjson` の transform_values と StreamingArtifacts の artifact
  整形が二重管理 — StreamingArtifacts に一本化
- [x] Q10. `__internal_record_span__` の `public :` 後付けをやめ、public 領域へ
  定義を移動
