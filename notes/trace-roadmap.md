# Dommy Trace ロードマップ

Dommy::Browser と Dommy::Rack::Trace で Rails からブラウザまでのトレース情報を集め、Rails アプリ開発の支援を強化するための方向性をまとめる。
ビューアは dommy-tui リポジトリの dommylizer で開発している。
本文書は 2026-07 時点の現状整理と、優先順位付きのロードマップ、将来の展開案からなる。

## 現状整理

### emitter 側（dommy-rack）

`Dommy::Rack::Trace` は Session の seam に購読し、次のイベントを flat な NDJSON v2 として出力する。

- **action**：ユーザー操作／テスト操作のグループ開始。以後のイベントが `action_seq` で参照する
- **http**：リクエスト／レスポンス 1 往復。リダイレクトの各ホップが 1 イベント
- **form / document / dom / error**：フォーム送信、document ロード、DOM mutation（opt-in）、失敗
- **script / console / js_error**：`:verbose` レベルで加わる JS レルムのストリーム

時刻は仮想クロック `t` と実時間 `wall_ms` の二本立て。
パラメータは ParamFilter で redact される。
DOM snapshot などの大きな内容は artifact として分離できる。

Rack 境界の内側、つまり Rails の controller、SQL、テンプレート描画はまだ何も記録していない。
ActiveSupport::Notifications への購読はどの gem にも存在しない。

### viewer 側（dommylizer）

timeline pane、detail pane、source pane、time bar、status bar を持つ TUI。
folding、follow、artifact 表示、timing 表示までテスト付きで動いている。
未知の op は generic な Event として保持するため、新しい emitter の出力も落とさず表示できる。

### 仕様文書との乖離

v1 系の設計（span_start/span_end と lane）は実装の flat v2 形式と乖離していたため、現行契約を `gems/dommy-rack/docs/trace-ndjson-spec.md` に、v1 案を `notes/trace-ndjson-v1-draft.md` に分離済み。
Rails 計装を入れる前に、この契約を確定させる必要がある（後述のフェーズ 1）。

## ロードマップ

実施順に並べる。
フェーズ 1 と 2 が本丸で、ここまで終えると「Capybara + Selenium では得られない、DB まで届く一本線のトレース」という dommy 固有の価値が完成する。

### フェーズ 1：NDJSON 契約の再確定 — 完了（2026-07-14）

flat v2 を正として `gems/dommy-rack/docs/trace-ndjson-spec.md` に現行契約を置く（v1 本文は
span 導入時の将来案として保持）。golden fixture
（`gems/dommy-rack/test/fixtures/contract.trace.ndjson`、生成・正規化・検証は
`test/support/trace_contract.rb`）を両リポジトリに置き、emitter 側
（dommy-rack `TraceContractTest`）と viewer 側（dommylizer `ContractTest`）の
契約テストが同一ファイルで結合するようにした。以下は当初の計画。

Rails 計装を入れると、時間幅を持つ入れ子の処理（request の中の controller、その中の SQL）を初めて表現する必要が生じる。
flat v2 のまま拡張するか、v1 系の span 形式へ寄せるかをここで決める。

推奨は v2 flat を正とする最小拡張である。
dommy の Rack 呼び出しは同期実行なので、span_start/span_end に分ける必然性は薄く、完成形 span（`t` + `duration_ms` + `parent`）で表現できる。
`gems/dommy-rack/docs/trace-ndjson-spec.md` を実装に合わせて書き直す。

あわせて、両リポジトリで共有する **golden fixture**（dommy 側で生成したサンプル .trace.ndjson を dommylizer 側でパース検証する契約テスト）を導入する。
リポジトリ分割時に採った「境界契約で疎結合」方針の trace 版であり、emitter と viewer が互いのコードに依存せず進化できるようになる。

### フェーズ 2：Rails 内部の計装 — 初弾完了（2026-07-14）

Trace に完成形 span（`parent` = 包含する http 行の seq、`duration_ms`、
`kind`/`label` + 平坦化フィールド）を追加し、リクエスト中は thread-local で
trace を計装層に公開、レスポンス時に http 行の直後へ flush する構造にした。
dommy-rails に `TraceInstrumentation.install!`（idempotent）を追加:
`process_action` / `sql.active_record`（SCHEMA/TRANSACTION は除外、bind 値は
最初から出力しない）/ `render_template` / `render_partial` を
monotonic_subscribe で購読して span 化。同日中に仕上げも完了：
ActiveJob（enqueue/perform）と ActionMailer（deliver）の購読、BrowserSpec の
browser 起動時の自動 install!、bind 値の opt-in 出力（`install!(binds: true)`、
form params と同じ機微キーのマスクを適用）、CI artifact 化の手引き
（dommy-rails README）。以下は当初の計画。

現状のトレースは「POST /posts → 422」で止まり、なぜ 422 だったかは見えない。
dommy-rails に ActiveSupport::Notifications subscriber を追加し、リクエストの内側を埋める。

- `process_action.action_controller`：controller、action、format、status
- `sql.active_record`：SQL。binds は既存の ParamFilter で redact する
- `render_template` / `render_partial`：どのテンプレートに時間を使ったか
- 余力があれば `enqueue.active_job` / `deliver.action_mailer`。dommy-rails には既に MailPart があり相性が良い

相関は単純に取れる。
Rack リクエストは dommy 自身が同期的に呼ぶため、Notifications のイベントは「現在処理中の http イベントの子」としてぶら下げられる。
分散トレーシングのような request id の伝播は要らない。

これが完成すると、次の因果の一本線が初めてつながる。

```text
click_button "Create"
  → POST /posts
    → PostsController#create
      → INSERT 失敗（Validation failed）
      → render posts/_form
  → turbo-stream replace #post_form
  → DOM mutation
→ assertion 失敗（"Created" が見つからない）
```

テスト失敗の原因説明能力が、Rack 境界止まりの現状から一段変わる。

### フェーズ 3：テスト失敗バンドルと viewer への動線 — 完了（2026-07-14）

調べてみると BrowserSpec の失敗アーティファクト機構（`tmp/dommy/failures/
<slug>/` に current.html / trace.txt / visible-text / NDJSON バンドルを保存、
RSpec と minitest の両フック済み）が既に本フェーズの大半を実装していた。
欠けていたのは「保存した」という事実の提示だけだったので、
`dommy_browser_after` が保存先を返すようにし、RSpec は失敗メッセージ
（extra_failure_lines）、minitest は警告出力で `Trace bundle: <dir>` と
`View it with: dommylizer <dir>/trace.ndjson` を出すようにした。
残り：CI artifact 化の手引き。以下は当初の計画。

技術より体験の改善だが、日常的に使われるかどうかを決めるのはここである。

- 失敗時に `tmp/dommy_traces/<example名>/run.trace.ndjson` と `artifacts/` を自動保存する。RSpec / minitest の integration は既にあるので、失敗フックに追加するだけでよい
- 失敗メッセージの末尾に `dommylizer tmp/dommy_traces/.../run.trace.ndjson` と一行出す
- CI ではディレクトリごと artifact 化する

「失敗したらコマンド 1 つで timeline が開く」が成立すると、トレースは調査の起点として定着する。

### フェーズ 4：開発モードのライブトレース — emitter 分完了（2026-07-14）

`Trace#stream_to(path_or_io)` / `#finish_stream(status:)` を追加：イベント発生の
瞬間に 1 行 append + flush（trace_start 先行、artifact は書き込み時に inline
解決、死んだ sink は捨ててセッションを守る）。ストリーム文書はバッチ
`to_ndjson` と行単位で一致する。残り：dommynx からの配線と
`dommylizer --follow` での実地確認。以下は当初の計画。

テストの外への拡張である。
dommynx で手元の Rails アプリを触りながら、別ペインで `dommylizer --follow` にトレースが流れる、という使い方を成立させる。

viewer 側の follow 機能は下地が既にある。
emitter 側に、行ごとに append + flush する streaming writer を足せば成立する。
NDJSON 仕様が append-only を前提にしているのは、もともとこの用途とハング調査のためである。

これはトレースの位置づけを「テストのデバッグツール」から「Rails 開発の常用計器」へ変える転換点になる。

### フェーズ 5：エージェント向け出力

`to_text` の延長として、失敗トレースを診断サマリに畳む機能を作る。
たとえば「422 の原因は Post の title validation 失敗。turbo-stream は replace #post_form を適用済み。assertion は 'Created' を 5 秒待ってタイムアウト」という一段落である。

NDJSON は既に機械可読なので、Claude Code のスキル（`/dommy-diagnose <trace>` のような形）や将来の MCP ツールから読ませる形にする。
人間用 viewer（dommylizer）と AI 用（diagnose）が同じ NDJSON を読む対称性を保つ。
「AI と一緒に Rails 開発する」文脈で、dommy 固有の売りになる。

フェーズ 4 と 5 は独立しており、フェーズ 3 のあと並行して進められる。

## 将来の拡張案

ロードマップ本線の外側にある展開の候補を挙げる。
着手順は決めず、需要が見えたものから取る。

### 性能分析への展開

`wall_ms` と SQL span が揃うと、性能系の解析が載せられる。

- N+1 検出：同一 action 内で同型 SQL が閾値回数を超えたら warning イベントを出す
- slow span のハイライト：viewer 側で duration の分布から外れた span を強調する
- render perf の定点観測：重いページの trace を保存しておき、変更前後で比較する

### DOM diff と ARIA snapshot の artifact 化

action 前後の DOM snapshot は既にあるので、その差分（どの部分木が変わったか）を artifact として持てば、turbo-stream の適用結果を目視確認できる。
Accessibility Tree と ARIA Snapshot は実装済みなので、trace に載せれば「操作のたびにアクセシビリティ構造がどう変わったか」も追える。
dommynx の reflow テキスト（テキストブラウザとしての描画結果）を artifact に入れれば、スクリーンショット相当の役割も果たせる。

### OpenTelemetry への変換

外部 APM に流す需要が出た場合は、NDJSON → OTLP の一方向変換器を別 gem として作る。
trace 本体を OTel のデータモデルに合わせる必要はない。
NDJSON が意味論を保持している限り、変換は後付けできる。

### トレースの比較と回帰検出

同じ spec の trace を green のときに保存しておき、失敗時の trace と突き合わせる。
「前回と比べてどこから分岐したか」（リクエストが増えた、SQL が変わった、DOM mutation が消えた）を機械的に出せると、flaky テストや意図しない挙動変化の調査が短くなる。

### 教材・デモとしての展開

Rails のリクエスト処理の全行程が 1 ファイルの NDJSON に落ち、TUI で追えるという性質は、Rails 初学者向けの教材やカンファレンスのデモに向く。
「click から DB まで」を実物のイベント列で見せられるツールは他にない。

## 当面やらないこと

- **OpenTelemetry 互換のデータモデル採用**：上述のとおり変換で足りる
- **viewer からの双方向操作**（trace 上のイベントを選んで再実行するなど）：follow 表示で十分
- **span_start/span_end のストリーム形式**：同期実行の dommy では完成形 span で足りる。非同期処理（ActiveJob の実行側など）を trace に取り込む段になったら再検討する

## 関連文書

- `gems/dommy-rack/docs/trace-ndjson-spec.md`：NDJSON 仕様（現行契約 = flat v2）
- `notes/trace-ndjson-v1-draft.md`：未実装の v1 設計案（参照資料）
- `trace-ndjson.md` / `trace-viewer-tui.md` / `obs.md`：初期の設計メモ
- emitter 実装：`gems/dommy-rack/lib/dommy/rack/trace.rb` 以下
- viewer 実装：dommy-tui リポジトリ `gems/dommylizer`
