# R2 コーパスベンチマーク — example アプリ 5 本 × 10 回（2026-07-15）

adoption-research.md の R2。
「速い」「flaky が出ない」に数字を付けるための本計測。
初回ベースライン（`r2-initial-benchmark.md`、todo-app のみ 3 回）を、
dommy-examples の system spec を持つ全 5 アプリ × 各 10 回へ拡張した。

## 方法

- 対象：dommy-examples の 5 アプリの system spec（合計 42 examples）。
  各アプリの `spec/support/capybara.rb` が `CAPYBARA_DRIVER=dommy` で
  capybara-dommy（`driven_by :dommy_js`）、未指定で selenium headless Chrome に切り替わる。
  **同一 spec・同一 seed（20260715）を両ドライバで走らせる**
- 各ドライバ・各アプリで 1 回ウォームアップ後に 10 プロセスを測定
- 各測定は独立した `bundle exec rspec` プロセス。計測項目：
  - `rspec_seconds`：RSpec が報告する example 実行時間（Rails boot を除く）
  - `wall_seconds`：プロセス全体の壁時計（boot 含む）
  - `failures`：run ごとの失敗数（**決定的ギャップと真の flake を分けるため**）
  - `peak_rss_mb`：**プロセスツリー全体**の peak RSS。
    Chrome は chromedriver + chrome が別プロセスになるため、
    rspec プロセス単体では大幅に過少計上になる。子孫プロセスを合算してサンプリングした
- 計測スクリプトは一時ファイル、対象リポジトリは無改変

## 結果

### 速度（RSpec example 実行時間、中央値・秒）

| app | ex | dommy | chrome | 倍率 |
|---|---:|---:|---:|---:|
| todo-app | 8 | 0.98 | 4.07 | 4.2x |
| live-serarch | 6 | 1.49 | 4.90 | 3.3x |
| react_board | 15 | 3.63 | 7.55 | **2.1x** |
| signup | 7 | 0.81 | 5.73 | 7.1x |
| turbo_pages | 6 | 0.63 | 3.92 | 6.2x |

- **コーパス合計（42 examples）の中央値和：dommy 7.54s vs chrome 26.17s ＝ 3.5x**
- 壁時計（boot 含む）では 2.0〜3.3x。Ruby/Rails の boot が両ドライバ共通の固定費として
  残るため、example 実行時間より差は縮む
- **react_board（重い React）が最小の 2.1x**。QuickJS 越境コストが効き、
  Dommy の相対優位が最も小さいアプリ。「Dommy は一様に速い」わけではないという正直な外れ値

### 起動オーバーヘッド（wall − rspec、中央値・秒）

| app | dommy | chrome |
|---|---:|---:|
| todo-app | 1.42 | 2.00 |
| live-serarch | 1.46 | 2.04 |
| react_board | 1.04 | 1.57 |
| signup | 1.47 | 1.91 |
| turbo_pages | 1.88 | 2.23 |

Dommy は約 1.0〜1.9s（Ruby/Rails boot のみ）、Chrome は約 1.6〜2.2s
（boot + ブラウザ起動）。Chrome のブラウザ起動ぶんが上乗せされるが、
差は小さく、両者とも Rails boot が支配的。

### flake / 決定性（10 回の失敗数の変動）

| app | dommy | chrome |
|---|---|---|
| todo-app | 決定的 PASS | 決定的 PASS |
| live-serarch | 決定的 PASS | 決定的 PASS |
| react_board | 決定的 PASS（修正後）※ | 決定的 PASS |
| signup | 決定的 PASS | 決定的 PASS |
| turbo_pages | 決定的 PASS | 決定的 PASS |

- **10 回の中で失敗数が変動したケースはゼロ**（両ドライバ・全アプリ）。
  このコーパスでは真の flake は観測されなかった
- react_board の 1 失敗は 10 回すべてで同一 example が落ちる **決定的な能力ギャップ**であり、
  flake ではない（後述）

### メモリ（peak プロセスツリー RSS、中央値・MB）

| app | dommy | chrome | 倍率 |
|---|---:|---:|---:|
| todo-app | 148 | 930 | 6.3x |
| live-serarch | 147 | 1446 | 9.8x |
| react_board | 175 | 1701 | 9.7x |
| signup | 172 | 1592 | 9.3x |
| turbo_pages | 149 | 1474 | 9.9x |

事実のみ記録する。
Dommy はアプリによらず約 150〜175MB でほぼ一定、Chrome は 930〜1701MB。
Dommy は in-process のためこの値が総フットプリント、Chrome は
chromedriver + chrome の子プロセスを含む値。
（この差が並列度に効くかは CPU など他の律速との兼ね合いで、本計測の範囲外。R6 で扱う）

## react_board の決定的失敗

- 落ちる example：`Customer operations dashboard filters accounts to follow-up items only`
  （customer_dashboard_system_spec.rb:100）
- 内容：`check "Needs follow-up"` を**単独フィルタ**として使い、テーブルが 3 行に
  絞られることを期待する。直前の `combines tab, owner, and follow-up filters`
  （同じチェックボックスを使うが tab + owner で先に 1 行へ絞る）は PASS するため、
  React の制御 checkbox に対する `check` のイベント列が、単独フィルタ時に
  期待どおりの結果集合を生まないと見られる
- 10 回すべてで同一に失敗（flake でなく能力ギャップ）。Chrome では PASS
- **根本原因を特定・修正済み（2026-07-15、dommy f2dc62a）**：react_board 固有ではなく、
  **`<label>` 内チェックボックスを直接クリックしたときの二重発火バグ**だった。
  click がラベルへバブル → ラベルの activation が対象コントロール（そのチェックボックス）を
  再クリック → 2 回目トグルで元に戻り、React（value tracker で 2 回目の checked=false を読む）が
  変更を検知せず DOM を復元。HTML label activation のガード（click が対象コントロール由来なら
  何もしない）が欠けていた。**修正後 react_board は 15/15 green**。
  `<label><input type=checkbox></label>` は極めて一般的な構造なので広範な実バグだった

## 解釈

- 速度：Rails system spec のコーパスで **example 実行時間 3.5x（中央値和）**、
  アプリ単位で 2.1〜7.1x。boot 込みの壁時計では 2.0〜3.3x
- 決定性：50 プロセス（5 アプリ × 10 回）で flake ゼロ。
  「dommy 側で flake が出たら即バグ」というラチェットの初期母集団としては良好だが、
  結論には反復とアプリ数がまだ少ない。R6 で CI 上 30 回以上、実 OSS アプリ（R1）へ拡張する
- 忠実度：react_board の 1 件が、実ブラウザとの唯一の挙動差。
  「Dommy は速いが React の一部相互作用に穴がある」という正直な現在地を示す 1 データ点

## React 越境高速化の候補（次の一手 / B4 の続き）

react_board が唯一 2.1x に留まる原因は React の JS↔Ruby 越境コストである。
B4（expando の JS 側化ほか、`perf-roadmap.md` 参照）で初回レンダリングは
約 6929→**5138 越境**に下がった（この実数は 2026-07-15 に `profile_real_app.rb` の
二重計上バグ＝カテゴリ別 `__total__` をメンバーと重複加算していた、を修正した後の値。
以前引用していた 10269 等は約 2 倍だった。相対比較 = B4 の -27% 等は影響なし）。

残りの越境は**ほぼ全て初回のノード構築**である。
post-B4 のプロファイル（300 行 React、初回 render、実数 5138）の内訳：

```
Document#createElement         901   構築 write
HTMLLIElement/UList#appendChild 901   構築 write
setAttribute (li/span/button)  1201   構築 write
textContent (span/button)       601   構築 write
HTMLDivElement#ownerDocument    901   構築中の read
firstChild (reconcile 時 read)   600   構築中の read
```

- 構築 write（createElement + appendChild + setAttribute + textContent）
  = 3604 ≈ **越境の 70%**
- 構築フェーズの read（ownerDocument + firstChild）を足すと ≈ 5105 ≈ **99%**

つまり React 初回 render の越境はほぼ構築で占められている。
fragment fast path が直接消せるのは 70% の構築 write、残り 29% の read も
JS 側 shadow が答えれば消せる。

### 案 1：JS 側 shadow DOM 全面化（見送り寄り）

全ノードを JS 側の軽量表現で持ち、越境を最小化する。
効果は最大だが、Ruby が権威を持つ DOM との **read 一貫性**（getComputedStyle、
セレクタ照合、Ruby 側から観測する属性など）が全域で問題になり、実装が重い。
bridge-redesign.md 領域。

### 案 2：detached サブツリーの一括構築（fragment fast path）— 現実的

React は多くの場合、新規ノードを **detached** な状態で組み立ててから 1 回 attach する。
detached ノードへの appendChild / setAttribute は connectedCallback もライフサイクルも
走らない（D1c のミューテーションゲーティングで確認済み）。
この間の書き込みを **JS 側の軽量な shadow representation に貯め**、attach 時に
HTML 文字列 or 構造化データとして 1 回で Ruby に渡す。

- 案 1 より限定的だが **read 一貫性の問題が小さい**：detached サブツリーは Ruby から
  観測されないため、バッファ中に一貫性を保つ相手が少ない。構築中の read
  （ownerDocument は既知の document を JS 側で即答、firstChild 等は必要時に
  バッファを flush してから読む）も detached 限定なら扱いやすい
- 直接効くのは createElement / appendChild / setAttribute / textContent /
  ownerDocument の構築系越境 = 上記内訳の大半。React の初回レンダリングに直撃する
- attach（`el.appendChild(detachedRoot)`）の 1 回で subtree 全体を Ruby に materialize。
  attach 時に connected ライフサイクルが subtree 全体へ発火するのは従来どおり

### 実装上の要点

- バッファの flush 契機：(a) detached ルートの attach、(b) バッファ中ノードへの
  未対応な read/操作。(b) で必ず flush すれば read 一貫性は保てる（write-only 蓄積 +
  read で確定）
- materialize は既存の `Parser.fragment`（HTML 文字列）か、構造化データの一括 API。
  fragment 経由なら NodeWrapperCache の identity 再利用（D1d）と整合を取る必要がある
- 越境が消える分、`profile_real_app.rb` の React initial の越境数で before/after を測る
  （必ず `bundle exec` で local dommy を測ること — 素の ruby は公開 gem を測る footgun）

canonical な追跡は `perf-roadmap.md` の B4（越境削減）。本節はその「次の一手」の素案。

## 再現

```sh
cd ~/git/dommy-examples/todo-app   # 任意のアプリ dir から（bundle 解決のため）
BENCH_RUNS=10 mise exec ruby@4.0.5 -- ruby /private/tmp/r2_corpus_benchmark.rb
# APPS=todo-app,signup のように絞り込み可。OUT= で JSON 出力先を指定
```

harness は `/private/tmp/r2_corpus_benchmark.rb`、集計は `/private/tmp/r2_aggregate.rb`
（いずれも一時ファイル。恒久化するなら dommy-examples 側の bench ディレクトリへ）。

## 次

- R6：`parallelize(workers:)` の実測（実効ワーカー数・throughput・メモリと並列度の関係）
- R1/R4：react_board の失敗の根本原因、実 OSS アプリへの harness 適用
- 反復増（CI 上 30 回以上）で flake 率の結論を固める

## 関連文書

- `r2-initial-benchmark.md`：初回ベースライン（todo-app のみ）
- `adoption-research.md`：R2 / R6 / R1 / R4 の位置づけ
- `functional-gaps.md`：react_board 失敗の分類先候補
