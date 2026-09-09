# 採用に向けた残調査計画（2026-07-15）

Dommy::Browser が headless ブラウザ並みに使われるために、まだ埋まっていない調査領域の一覧。
既存文書（functional-gaps.md / driver-diff-matrix.md / compat-hypothesis.md /
trace-export-design.md）はラボ内監査で得られるものをほぼ出し切ったため、
ここに残るのは性格の違う調査である。
各項目に「その調査が何の意思決定を変えるか」を付す。

## 優先度高

### R1. 実アプリコーパス調査（フィールドデータ）

これまでの監査は仕様と実装の突き合わせによる予測にとどまる。
実在の OSS Rails アプリ（Devise + Hotwire 構成を中心に数本。候補：Docuseal、Maybe、
Chatwoot、Solidus、authentication-zero 系）のテストスイートを dommy で実走し、
無変更通過率と失敗理由の分布を取る。

- 決まること：functional-gaps の G 番号の優先順が実測ランキングになる。
- 成果（2026-07-15）：react_board の唯一の失敗の根本原因を特定・修正（label 内 checkbox 二重発火、dommy f2dc62a）。実アプリ由来で広範な実バグを 1 件回収。
  compat-hypothesis H4 の移行実験そのものであり、trace diff ツールの最初の実戦投入先
- 方法：対象選定 → clone → capybara-dommy 差し替え → 実走 → 失敗分類
- 状態：**初回ベースライン完了**（2026-07-15）→ `r2-initial-benchmark.md`。
  todo-app の同一 system spec（8 examples、各3回）で Dommy は headless Chrome に対し
  RSpec 実行時間中央値 7.3x、process wall 中央値 3.2x。flake 率の結論には反復不足。

### R2. 対 headless 実測ベンチ + flaky 率の定量化

「速い」「flaky が消える」に現状数字が一つもない。
同一スイートを dommy / cuprite / selenium で回し、スイート壁時計・1 テストあたり・
コールドスタート・メモリフットプリント・**同一スイート N 回実行での flake 数**を計測する。
flake 数は決定性という中核主張の裏付けであり、「dommy 側で flake が出たら即バグ」
というエンジニアリング上のラチェットにもなる。

- 決まること：ピッチに載せる数字と、性能ロードマップの次の目標値
- 方法：R1 のコーパス（または dommy-examples）を計測台に流用
- 状態：**本計測完了**（2026-07-15）→ `r2-corpus-benchmark.md`。
  example アプリ 5 本（42 examples）× 各 10 回。RSpec 実行時間 中央値和で 3.5x
  高速（アプリ単位 2.1〜7.1x）、壁時計 2.0〜3.3x。50 プロセスで flake ゼロ。
  react_board のみ決定的に 1/15 失敗（React 制御 checkbox、R4 送り）。
  メモリは事実のみ記録（dommy 約 150MB 一定 / chrome 930〜1701MB）。
  並列度への含意は R6。

### R3. capybara-webkit / PhantomJS の死因研究（持続可能性への反論材料）

採用検討者の最強の反論は「この種のツールは前例が全部死んだ」である。
capybara-webkit と PhantomJS がなぜ死んだか、jsdom がなぜ長期生存しているか、
Vitest の browser mode 等「実ブラウザ回帰」の潮流が何を意味するかを一次情報で調べ、
「なぜ dommy は capybara-webkit にならないのか」への文書化された回答を作る。
仮説：死んだのは「実エンジンの fork を抱えた」系であり、
生き残ったのは「仕様の再実装 + 適合テストのラチェット」系である。
dommy は構造的に後者に属する——この主張自体を検証する。

- 決まること：技術リード説得用の持続可能性文書。ポジショニングの根幹
- 方法：一次情報（deprecation 告知、メンテナ声明、issue）の収集と構造分析
- 状態：**完了**（2026-07-15）→ `sustainability-research.md`

### R4. JS モードのコンプライアンス計測 + JS ライブラリ互換マトリクス

driver-diff-matrix.md の宿題（dommy 列が非 JS 計測のまま）に加え、Rails アプリ頻出
ライブラリの動作可否マトリクスを作る。
対象候補：jQuery、Alpine、htmx、select2 / tom-select、flatpickr、chartkick、
ActionCable JS、（既知の非対応として Trix = G13）。
fixture は react / vue / alpine / htmx / lit / solid が vendoring 済みで、
Turbo / Stimulus でやった公式スイート方式の横展開になる。

- 決まること：「うちのアプリで動くか」への即答表と、conformance 投資の次の的
- 関連：`test-coverage-strategy.md`（WPT のブラインドスポット分析。インタラクション系が
  空で、testdriver.click shim が最も梃子の効く一手。R4 の前提となる網羅拡大の設計）
- 状態：未着手

## 優先度中

### R5. テストエコシステム互換調査

WebMock / VCR は dommy の外部 fetch を横取りできるか。
**ActiveStorage の direct upload**（XHR でストレージへ直接上げる JS。
system test の頻出シナリオ）は動くか。
Sidekiq::Testing、ActionMailbox、axe-core（dommy 上で a11y 監査が回れば独自の差別化）。

- 決まること：移行ガイドの「動く・動かない」章と、functional-gaps への追加項目
- 状態：未着手

### R6. スケール特性（長寿命・並列・メモリ）

数千テスト規模での VM とメモリの伸び（D2e の callbacks / jsRefs 成長が実際いつ痛むか）、
`parallelize` の実測（G21 は静的解析のみ）、CI の 2 コア runner での並列効率。
headless Chrome はメモリが並列度の上限になるため、ここで勝てるなら強い数字になる。

- 決まること：D2e の優先度と、CI 向け推奨構成
- 状態：**着手・初回完了**（2026-07-15）→ `r6-parallel-scaling.md`。
  8 コア/16GB・todo-app で同時実行 1〜8 を実測。メモリは線形（dommy 144MB/worker、
  Chrome 760MB〜1GB/worker）。C=8 で dommy 6.06s/1153MB/1.32 t/s vs Chrome
  51.48s/6079MB/0.16 t/s（壁時計 8.5x / メモリ 5.3x / throughput 8.3x）。
  Chrome は throughput が横ばい（プロセス競合）。**fork 安全性は確認**（VM 相続問題なし）。
  DB 分離が並列の前提と実証。残：長 suite での throughput、Rails parallelize end-to-end。

### R7. プラットフォーム・バージョンマトリクス

Ruby 3.2〜4.0、Windows（makiri は対応済み。quickjs gem は未確認）、
JRuby / TruffleRuby（C 拡張依存のため恐らく不可。不可なら不可と明記）、Rails 7.1〜8.x。

- 決まること：CI マトリクスの範囲と README の対応表
- 状態：未着手

## 優先度低（文書化すれば足りる）

### R8. セキュリティモデルの整理

アプリの JS をテストプロセス内で実行することの含意：タイムアウト、メモリ上限、
外部ホストへの egress（subresource blocker の既定挙動）。
エンタープライズの審査で聞かれる項目の先回り。

### R9. 依存のバスファクター監査

quickjs.rb（単一メンテナ。module-bytecode-cache の upstream PR も係争中）、
lexbor、tui_tui。フォーク許容性とライセンスの確認。

## 推奨順序

R3（本文書と同時に着手）→ R1（一石五鳥：H1/H2/H4/H6・G ランキング・R2 の素材が
一度に入る）→ R2 → R4 → R5〜R7 → R8/R9。

## 関連文書

- `compat-hypothesis.md`：R1 が検証する仮説群
- `functional-gaps.md`：R1 の失敗分類の照合先、R5 の追記先
- `driver-diff-matrix.md`：R4（JS モード計測）の宿題元
- `trace-export-design.md`：R1 の triage 道具
