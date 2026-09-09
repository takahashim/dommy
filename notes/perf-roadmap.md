# Dommy 高速化計画

Dommy 全体（core、dommy-js-quickjs、makiri、dommynx）の高速化の計画をまとめる。
2026-07 時点の計測と、これまでの高速化の成果を前提に、次に何をどの順で削るかを決める。

## 現状の計測

2026-07-06 時点の手元計測（M 系 Mac）。

| 対象 | 結果 |
|---|---|
| dommy core テスト（3339 runs） | 約 1.1 秒 |
| dommy-js-quickjs テスト（596 runs） | 約 16 秒 |
| JS↔Ruby 越境 1 回 | 約 5μs（改善前 9.8μs、pure JS 比でなお数百倍） |
| 重い実サイトの描画（dommynx） | 約 1.2 秒（改善前 20.4 秒） |

ここから読める構図は単純である。
DOM core 単体はすでに速く、コストは JS 統合（越境）と実ページ処理（CSS、ネットワーク、描画）に集中している。
したがって高速化の主戦場は core の Ruby コードではなく、境界（JS↔Ruby、Ruby↔C）の設計にある。

### これまでに終えた高速化

- QuickJS gem の per-call `Timeout.timeout` を除去し、越境コストを 48% 削減（テストスイート 42→31 秒、C 改変なし）
- CSS スキャナの O(n²) を BINARY 走査で解消、native `next_element`、query 結果の cache（`style_generation` 鍵）
- トラッカー広告ブロッカー既定 ON によるサブリソース削減

## 進捗（2026-07-14 再計測）

dommy-js-quickjs 側の互換性ロードマップ（`docs/compat-roadmap-todo.md` の戦線D）として高速化が並走し、本計画のフェーズ 0〜2 の多くが実装された。

| 対象 | 07-06 | 07-14 | 備考 |
|---|---|---|---|
| dommy core テスト | 3339 runs / 約 1.1 秒 | 約 1.1 秒 | 変化なし（もともと速い） |
| dommy-js-quickjs テスト | 596 runs / 約 16 秒 | 788 runs / 約 16 秒 | テスト 3 割増で同時間。1 run あたり約 23% 短縮 |
| 越境 1 回（読み取り系） | 約 5μs | 0.36〜0.49μs | epoch キャッシュにより 10 倍超の改善。目標（2μs 台）を大幅に超過達成 |
| 越境（setAttribute） | 計測なし | 6.2μs | 変異系は epoch bump で全キャッシュ無効化を伴う。次の主戦場 |
| 越境（querySelector） | 11μs（D2d 計測） | 3.8μs | |
| VM 起動 | 計測なし | 5.7ms | |

フェーズ別の状況。

- **フェーズ 0**：マイクロベンチは `script/bench_bridge.rb`（dommy-js-quickjs、越境系 + Ruby floor + VM boot）として実装済み（D4a）。残り：結果の JSON 保存と前回比較、凍結実ページのマクロベンチ、`--profile` オプション、実アプリプロファイル 1 本（D4b）
- **フェーズ 1**：回数削減はほぼ完了。不変値キャッシュ（CONST_NODE_PROPS）、DOM epoch カウンタと per-epoch キャッシュ（属性スナップショット 1 越境化、parentNode / textContent / nextSibling）、属性 reflection の JS 側化（read パス、D2a）。**変異パスの本命 D1b（epoch 分割）は 07-14 完了**：`dom_generation`（セレクタ結果キャッシュ）と `style_generation`（cascade キャッシュ）を分離し、属性変更は RuleIndex 収集の依存集合該当時のみ、characterData は空⇄非空反転か `<style>` 内のみ cascade を無効化。実測（300 要素 × 100 ルール）で characterData / data-* 変更 + computed_style 読みが 65ms→5μs 前後（約 14000 倍）、全 5 スイート green。**続けて RuleIndex を逆引き化（D1f、同日完了）**：plain ルールを右端セレクタでバケツ分けして要素側から lazy 照合する構造（WebKit rule hash と同型）に変え、シートテキストの parse cache と childList のみで動く `tree_generation` 鍵の style/link リストメモを追加。正当な無効化（class 変更）も 66ms→0.96ms（69 倍）、RuleIndex.build 単体は 63ms→0.71ms（89 倍）。**D1d（wrapper cache の検証スキップ、同日）**で wrap 系パスが 10〜20% 改善（fragment parse カウンタで identity 再利用不能な間は per-hit の C 往復を省略）、**D1e（matcher の属性二重読み解消、同日）**は属性系 query 約 -5% と SelectorIndex の class 分割不一致（\v）の正修正。**D4b（実アプリプロファイル、07-14）**で `profile_real_app.rb` を常設し、その実データで **B4 初弾**を実装：expando write の JS 側化 + Attr の const/epoch キャッシュ + factory の非変異分類で、React render **-27%** / re-render **-36%** / Turbo morph **-16%**。残り：イベントオブジェクトの JS 側化（morph 残の約 4200 越境）、**detached サブツリーの一括構築（fragment fast path、React 初回 render の構築系越境に直撃、素案は `notes/r2-corpus-benchmark.md`）**、バッチ読み取り RPC、reflection-*.html の vendor、長寿命 VM のメモリ衛生（D2e）、VM 起動系（D3a/D3b）
- **フェーズ 2**：cascade は実装が既に進行（`internal/css/` に cascade、rule_index、computed_style_declaration ほか）。**計画からの逸脱**：selector parsing は lexbor 委譲ではなく Ruby 自前の AST + グローバルキャッシュ（D1a、`matches?` 8.5 倍）に決定が変わった
- **フェーズ 3**：wrapper churn は `NodeWrapperCache`（wrapper 同一性 + query cache）として解決済み。C への hot path 降ろしは未着手
- **フェーズ 4〜5**：未着手。VM 起動系は D3a（ES モジュールのバイトコードキャッシュ、設計メモあり）として計画化済み

## フェーズ 0：計測基盤の常設

個別の高速化に入る前に、退行を検出できる状態を作る。
これまでの計測はその場限りのスクリプトで行っており、改善が維持されているかを確認する手段がない。

- **マイクロベンチマーク**：越境 1 回のコスト、selector matching（既存の `benchmark/selector_benchmark.rb` を起点に）、cascade（実装後）。結果を JSON で保存し、前回値との比較を出す
- **マクロベンチマーク**：凍結した実ページ（HTML + サブリソースを fixture 化したもの）のロード時間。SPA 調査で必要になる「フリーズ再生」と同じ仕組みを流用できるため、先にこちらを作ると一石二鳥になる
- **プロファイラ**：stackprof は dommy-tui 側にしかないので、dommy 側の dev group にも stackprof（または vernier）を入れ、ベンチマークに `--profile` オプションを付ける

ベンチマークは CI で毎回回す必要はない。
手元で `rake bench` 一発で回り、数値が残ることが条件である。

## フェーズ 1：JS↔Ruby 越境の削減（最大のレバー）

SPA の遅さの主因は越境回数×単価であることが計測済みである。
攻め方は「単価を下げる」と「回数を減らす」の二本で、効果が大きいのは回数側である。

### 回数を減らす

- **JS 側プロパティキャッシュ**：`nodeType`、`tagName`、`nodeName` のような不変値は、初回取得後に JS 側 wrapper に保持して越境を消す
- **世代カウンタによる可変値キャッシュ**：`children`、`childNodes` の走査結果などは、DOM の世代カウンタ（query cache で使った `style_generation` と同じ発想の DOM generation）を鍵に JS 側でキャッシュし、変更がなければ越境しない
- **バッチ化**：`for` ループでの連続アクセス（NodeList の全要素取得など）を 1 回の越境でまとめて返す bulk API を bridge に足す

キャッシュの無効化を間違えると DOM の意味論が壊れるため、この作業は WPT 系テストが green のまま進むことを常時確認しながら行う。

### 単価を下げる

- 残り約 5μs の内訳（wire の encode/decode、ハンドル表引き、QuickJS 評価の入口）をまずプロファイルで確定する
- wire の JSON 化で発生する文字列・Symbol の churn を削る（バッファ再利用、頻出キーの事前 intern）
- 例外を制御フローに使っている箇所があれば除去する

これまで「C 改変不要」を守ってきたが、bridge の hot path だけを薄い native 拡張にする選択肢は残しておく。
QuickJS 本体に手を入れるのとは違い、gem の再ビルドで済む範囲である。
着手はフェーズ 0 のプロファイルで Ruby 側が支配的と判明した場合に限る。

目標値：越境単価を 5μs→2μs 台、または代表 SPA でのロード中の越境回数を 1/10。
どちらを先に達成しても、JS テストスイート（16 秒）と SPA ロードの体感が変わる。

## フェーズ 2：CSS cascade を最初から速く作る

cascade（`css-cascade.md`）はこれから実装する機能であり、後から高速化するのではなく設計段階で速度を織り込む。

- **rule index**：スタイルシートの全ルールを、右端の simple selector（id、class、tag）でバケツ分けして持つ。要素ごとの候補ルールを全ルール走査ではなくハッシュ引きで得る
- **computed style のキャッシュと共有**：継承値は親の computed を構造共有し、要素ごとに全プロパティを複製しない
- **無効化**：`style_generation` を鍵にした既存の query cache と同じ機構で、DOM 変更・stylesheet 変更時のみ再計算する
- parsing と specificity は計画どおり lexbor 3.1.0 に委譲する（Ruby で書かない、が最大の高速化になる）

cascade は dommynx の描画品質向上と直結するため、フェーズ 1 と並行で進めてよい。

## フェーズ 3：Ruby↔C 境界（makiri）の削減

`next_element` の native 化と同じパターンで、Ruby 側でループしている hot path を C に降ろす。

- 候補：テキスト抽出（`text` の再帰）、クラス判定の一括化、部分木の要素数え上げ、属性の bulk 取得
- **wrapper churn の削減**：同一ノードへのアクセスのたびに Ruby wrapper を作り直しているなら、`pointer_id` を鍵にした wrapper cache で割り当てと GC 圧を減らす

候補の選定は推測でなくフェーズ 0 のプロファイル結果で行う。
core テストが 1.1 秒である以上、ここは「テストを速くする」ためではなく「実ページ処理を速くする」ための投資である。

## フェーズ 4：Rails テスト体験の高速化

Rails アプリのテストランナーとしての体感を上げる。

- **JS VM の遅延起動**：script を持たないページでは QuickJS を起動しない（既にそうなっているかをまず確認する）
- **セッション再利用**：spec 間で app と VM をどこまで再利用できるかを検討する。状態リークとのトレードオフがあるため、opt-in で始める
- **並列実行との相性確認**：parallelize（プロセス並列）で問題なく動くことをサンプルアプリで確認し、ドキュメント化する
- **トレースのゼロコスト化**：trace 無効時のオーバーヘッドが実質ゼロであることをベンチマークで保証する（notes/trace-roadmap.md の計装追加と同時に確認する）

## フェーズ 5：dommynx の体感速度

実ブラウジングの残りの遅さを削る。

- **HTTP キャッシュ**：ETag / max-age を尊重する応答キャッシュ。再訪問と同一サイト内の遷移が速くなる（ScriptCache は URL 鍵で導入済みなので、その一般化）
- **インクリメンタル reflow**：DOM 変更時に全体を組み直さず、変更のあった部分木だけ再 reflow する。cascade 側の世代カウンタと同じ無効化機構に載せられる
- ナビゲーション時の体感を「操作から初回描画まで」で計測し、フェーズ 0 のマクロベンチに加える

## 進め方

1. フェーズ 0（計測基盤）。以降の全フェーズの前提であり、規模も小さい
2. フェーズ 1（越境削減）。計測済みの最大ボトルネックであり、効果が最も広く波及する
3. フェーズ 2（cascade）は機能開発として独立に走らせ、設計レビューの観点に速度を含める
4. フェーズ 3〜5 は、フェーズ 0 のプロファイルと利用場面の優先度（テスト重視か、ブラウジング重視か）で順番を決める

## 当面やらないこと

- **QuickJS 本体の改造**：越境の単価は bridge 側で削れる余地が残っており、fork の保守コストに見合わない
- **Ractor / スレッド並列化**：プロセス並列（Rails の parallelize）で足りる場面が多く、共有状態の検証コストが大きい
- **core Ruby コードの網羅的チューニング**：計測上ボトルネックではない。プロファイルに現れた箇所だけを個別に直す

## 関連文書

- `project.md` / `lightweight-test-browser.md`：全体設計
- `css-cascade.md` / `css-cascade-selector-ast.md`：cascade 設計（フェーズ 2 の対象）
- `notes/trace-roadmap.md`：トレース強化計画（フェーズ 4 のゼロコスト化と接点）
- `gems/dommy/benchmark/`：既存ベンチマーク（フェーズ 0 の起点）
