# Dommy Trace NDJSON v1 設計案（未実装）

**この文書は実装されていない設計案である。** 現行契約は flat v2 で、
`gems/dommy-rack/docs/trace-ndjson-spec.md` が正となる。ここに残してあるのは、
将来 span 形式（時間幅の入れ子表現）が必要になったときの参照資料としてであり、
ここに書かれた op 名・フィールド・変換手順のいずれも emitter / viewer は
実装していない。読むときは常に「案」として読むこと。

たとえば redact 後のマーカーは、本案では `[REDACTED]` と書かれているが、
実装（`Dommy::Rack::Trace::ParamFilter`）が使うのは `[FILTERED]` である。

---

## 目的

Dommy::Browser の実行中に発生したテスト操作、ブラウザイベント、JavaScript処理、Rack/Railsリクエスト、DBアクセス、レスポンス処理、DOM更新、assertion などを、追記可能な NDJSON として出力する。

この形式は以下を目的とする。

- テスト失敗後の trace viewer 表示
- ハング・強制終了時にも途中までの trace を残すこと
- 将来的なリアルタイム trace viewer への対応
- `trace.json` のような完成済み trace document への変換
- CI artifact としての保存・共有

## 基本形式

1行に1つの JSON object を出力する。

```jsonl
{"op":"trace_start","trace_id":"tr_1","at_ms":0.0}
{"op":"action_start","id":"a1","label":"click_button \"Create\"","at_ms":1.2}
{"op":"span_start","id":"s1","parent_id":"a1","lane":"rack","label":"POST /posts","at_ms":2.4}
{"op":"span_end","id":"s1","at_ms":8.9,"status":"ok"}
{"op":"action_end","id":"a1","at_ms":10.1,"status":"failed"}
{"op":"trace_end","trace_id":"tr_1","at_ms":10.2,"status":"failed"}
```

## ファイル拡張子

推奨拡張子は以下とする。

```text
.trace.ndjson
```

例:

```text
tmp/dommy_traces/posts_create_failed.trace.ndjson
```

## 時刻

各イベントの時刻は、基本的に trace 開始時点からの monotonic milliseconds とする。

```json
{"at_ms":12.345}
```

wall clock time は各イベントには原則として入れず、`trace_start` の metadata にのみ入れる。

```json
{
  "op": "trace_start",
  "trace_id": "tr_1",
  "at_ms": 0.0,
  "wall_time": "2026-06-14T09:10:00.000Z"
}
```

### 時刻フィールド

| field | 意味 |
|---|---|
| `at_ms` | イベント発生時刻 |
| `start_ms` | 完成済み span を直接出す場合の開始時刻 |
| `end_ms` | 完成済み span を直接出す場合の終了時刻 |
| `duration_ms` | 任意。viewer側で計算可能なため必須ではない |

ストリーム形式では、原則として `span_start` / `span_end` に分ける。

## 共通フィールド

すべての行は JSON object であり、少なくとも `op` を持つ。

```json
{"op":"event"}
```

共通フィールドは以下。

| field | required | description |
|---|---:|---|
| `op` | yes | 操作種別 |
| `id` | opによる | event/span/action/artifact のID |
| `trace_id` | optional | trace全体のID |
| `parent_id` | optional | 因果関係上の親ID |
| `action_id` | optional | 所属する browser/test action |
| `lane` | optional | timeline上の表示レーン |
| `label` | optional | viewer向けの短い表示名 |
| `at_ms` | optional | trace開始からの経過ms |
| `status` | optional | `ok`, `failed`, `error`, `timeout`, `skipped` など |
| `data` | optional | 詳細情報 |
| `artifact_ids` | optional | 関連 artifact ID の配列 |

## ID

IDは trace 内で一意であればよい。

推奨 prefix:

| kind | prefix | example |
|---|---|---|
| trace | `tr_` | `tr_1` |
| action | `a_` | `a_1` |
| span | `s_` | `s_1` |
| event | `e_` | `e_1` |
| artifact | `art_` | `art_dom_before_1` |

## op 一覧

最低限サポートする `op` は以下。

```text
trace_start
trace_end

action_start
action_end

span_start
span_end

event

artifact
artifact_ref

log
warning
error
```

将来的に追加してよい `op`:

```text
snapshot
mutation
assertion_start
assertion_check
assertion_end
wait_start
wait_check
wait_end
metric
```

ただし、初期実装では `event` の `type` で表現してもよい。

## lane

timeline viewer の縦レーンを表す。

推奨 lane:

```text
test
browser
js
rack
rails
db
render
response
turbo
dom
assertion
log
```

### lane の意味

| lane | 内容 |
|---|---|
| `test` | spec/example/action/assertion など |
| `browser` | click, submit, focus, navigation など |
| `js` | event handler, timer, promise, fetch など |
| `rack` | Rack request/response |
| `rails` | routing, controller, callback など |
| `db` | SQL, transaction など |
| `render` | template rendering, partial rendering など |
| `response` | HTTP response, redirect, turbo-stream response など |
| `turbo` | Turbo Drive / Frame / Stream 処理 |
| `dom` | DOM mutation, snapshot, diff など |
| `assertion` | expectation, wait, retry, failure |
| `log` | log/warning/error |

## trace_start

trace の開始を表す。

```json
{
  "op": "trace_start",
  "trace_id": "tr_1",
  "at_ms": 0.0,
  "wall_time": "2026-06-14T09:10:00.000Z",
  "version": 1,
  "metadata": {
    "framework": "rails",
    "ruby_version": "3.4.4",
    "dommy_version": "0.1.0",
    "example": "Posts creates post",
    "file": "spec/browser/posts_spec.rb",
    "line": 12
  }
}
```

### required

| field | required |
|---|---:|
| `op` | yes |
| `trace_id` | yes |
| `at_ms` | yes |
| `version` | yes |

## trace_end

trace の終了を表す。

```json
{
  "op": "trace_end",
  "trace_id": "tr_1",
  "at_ms": 120.5,
  "status": "failed",
  "data": {
    "exception_class": "RSpec::Expectations::ExpectationNotMetError",
    "message": "expected to find text \"Created\""
  }
}
```

## action_start

ユーザー操作またはテスト操作の開始を表す。

```json
{
  "op": "action_start",
  "id": "a_1",
  "lane": "test",
  "type": "click",
  "label": "click_button \"Create\"",
  "at_ms": 1.2,
  "data": {
    "method": "click_button",
    "argument": "Create",
    "locator": "button[name=commit]"
  }
}
```

### action の例

```text
visit "/posts"
click_button "Create"
fill_in "Title", with: "Hello"
select "Published"
expect page to have_text "Created"
```

## action_end

action の終了を表す。

```json
{
  "op": "action_end",
  "id": "a_1",
  "at_ms": 10.1,
  "status": "failed",
  "artifact_ids": [
    "art_dom_before_a_1",
    "art_dom_after_a_1"
  ]
}
```

`action_start` と `action_end` の `id` は同じにする。

## span_start

時間幅を持つ処理の開始を表す。

```json
{
  "op": "span_start",
  "id": "s_1",
  "parent_id": "a_1",
  "action_id": "a_1",
  "lane": "rack",
  "type": "request",
  "label": "POST /posts",
  "at_ms": 2.4,
  "data": {
    "method": "POST",
    "path": "/posts"
  }
}
```

## span_end

時間幅を持つ処理の終了を表す。

```json
{
  "op": "span_end",
  "id": "s_1",
  "at_ms": 8.9,
  "status": "ok",
  "data": {
    "status_code": 422,
    "content_type": "text/vnd.turbo-stream.html"
  }
}
```

`span_start` と `span_end` の `id` は同じにする。

## event

瞬間的なイベントを表す。

```json
{
  "op": "event",
  "id": "e_1",
  "parent_id": "a_1",
  "action_id": "a_1",
  "lane": "browser",
  "type": "dispatch_event",
  "label": "dispatch click",
  "at_ms": 1.5,
  "data": {
    "event_type": "click",
    "target": "button[name=commit]"
  }
}
```

## log

ログ出力を表す。

```json
{
  "op": "log",
  "id": "e_log_1",
  "lane": "log",
  "level": "info",
  "label": "Processing by PostsController#create",
  "at_ms": 2.8,
  "data": {
    "source": "rails",
    "message": "Processing by PostsController#create as TURBO_STREAM"
  }
}
```

## warning

警告を表す。

```json
{
  "op": "warning",
  "id": "e_warn_1",
  "lane": "log",
  "label": "Turbo frame target not found",
  "at_ms": 9.1,
  "data": {
    "source": "turbo",
    "message": "target frame was not found"
  }
}
```

## error

例外や致命的エラーを表す。

```json
{
  "op": "error",
  "id": "e_error_1",
  "lane": "assertion",
  "parent_id": "a_1",
  "action_id": "a_1",
  "label": "Expectation failed",
  "at_ms": 10.1,
  "status": "failed",
  "data": {
    "exception_class": "RSpec::Expectations::ExpectationNotMetError",
    "message": "expected to find text \"Created\""
  },
  "artifact_ids": [
    "art_dom_after_a_1"
  ]
}
```

## artifact

DOM snapshot、response body、params、SQL bind values、diff などの大きめの情報を表す。

```json
{
  "op": "artifact",
  "id": "art_dom_after_a_1",
  "type": "dom_snapshot",
  "label": "DOM after click_button \"Create\"",
  "created_at_ms": 10.0,
  "encoding": "utf-8",
  "content_type": "text/html",
  "content": "<html><body>...</body></html>"
}
```

### artifact を外部ファイルに分ける場合

大きな artifact は NDJSON 内に直接埋め込まず、外部ファイル参照にしてよい。

```json
{
  "op": "artifact_ref",
  "id": "art_dom_after_a_1",
  "type": "dom_snapshot",
  "label": "DOM after click_button \"Create\"",
  "created_at_ms": 10.0,
  "content_type": "text/html",
  "path": "artifacts/art_dom_after_a_1.html"
}
```

## data フィールド

`data` は op/type ごとの詳細情報を入れる。

### Rack request

```json
{
  "method": "POST",
  "path": "/posts",
  "query_string": "",
  "params": {
    "post": {
      "title": "Hello"
    }
  }
}
```

### Rack response

```json
{
  "status_code": 422,
  "content_type": "text/vnd.turbo-stream.html",
  "location": null
}
```

### Rails controller

```json
{
  "controller": "PostsController",
  "action": "create",
  "format": "turbo_stream"
}
```

### SQL

```json
{
  "sql": "INSERT INTO posts (title, created_at, updated_at) VALUES (?, ?, ?)",
  "name": "Post Create",
  "binds": [
    ["title", "Hello"]
  ]
}
```

bind values は機密情報を含む可能性があるため、出力オプションで redact できることが望ましい。

### DOM mutation

```json
{
  "operation": "replace",
  "target": "#post_form",
  "before_artifact_id": "art_dom_before_patch_1",
  "after_artifact_id": "art_dom_after_patch_1"
}
```

### Assertion

```json
{
  "matcher": "have_text",
  "expected": "Created",
  "actual": null,
  "timeout_ms": 5000
}
```

## parent_id と action_id

`parent_id` は因果関係上の直接の親を表す。

`action_id` は、そのイベントが属する browser/test action を表す。

例:

```jsonl
{"op":"action_start","id":"a_1","label":"click_button \"Create\"","at_ms":1.0}
{"op":"event","id":"e_1","parent_id":"a_1","action_id":"a_1","lane":"browser","type":"click","label":"dispatch click","at_ms":1.2}
{"op":"span_start","id":"s_1","parent_id":"e_1","action_id":"a_1","lane":"rack","type":"request","label":"POST /posts","at_ms":2.0}
{"op":"span_end","id":"s_1","at_ms":8.0,"status":"ok"}
{"op":"event","id":"e_2","parent_id":"s_1","action_id":"a_1","lane":"dom","type":"mutation","label":"replace #post_form","at_ms":8.5}
{"op":"action_end","id":"a_1","at_ms":9.0,"status":"failed"}
```

viewer は `action_id` を使って、選択中 action に関連するイベントをハイライトできる。

## status

推奨 status:

```text
ok
failed
error
timeout
skipped
pending
cancelled
```

未終了 span は viewer 上では `pending` として扱う。

## type

`type` は `op` より細かい分類を表す。

例:

| op | type |
|---|---|
| `action_start` | `visit`, `click`, `fill_in`, `select`, `assertion` |
| `span_start` | `request`, `controller`, `sql`, `render`, `wait` |
| `event` | `dispatch_event`, `mutation`, `redirect`, `snapshot`, `assertion_check` |
| `artifact` | `dom_snapshot`, `response_body`, `request_params`, `dom_diff` |

## 完成済み trace.json への変換

NDJSON は append-only log であり、viewer はこれを fold して完成済み trace document に変換できる。

入力:

```jsonl
{"op":"span_start","id":"s_1","lane":"rack","label":"POST /posts","at_ms":2.0}
{"op":"span_end","id":"s_1","at_ms":8.0,"status":"ok"}
```

変換後:

```json
{
  "spans": [
    {
      "id": "s_1",
      "lane": "rack",
      "label": "POST /posts",
      "start_ms": 2.0,
      "end_ms": 8.0,
      "status": "ok"
    }
  ]
}
```

## 出力例

```jsonl
{"op":"trace_start","trace_id":"tr_1","version":1,"at_ms":0.0,"wall_time":"2026-06-14T09:10:00.000Z","metadata":{"framework":"rails","example":"Posts creates post","file":"spec/browser/posts_spec.rb","line":12}}
{"op":"action_start","id":"a_1","lane":"test","type":"visit","label":"visit \"/posts/new\"","at_ms":0.4,"data":{"path":"/posts/new"}}
{"op":"span_start","id":"s_1","parent_id":"a_1","action_id":"a_1","lane":"rack","type":"request","label":"GET /posts/new","at_ms":0.6,"data":{"method":"GET","path":"/posts/new"}}
{"op":"span_start","id":"s_2","parent_id":"s_1","action_id":"a_1","lane":"rails","type":"controller","label":"PostsController#new","at_ms":1.0,"data":{"controller":"PostsController","action":"new"}}
{"op":"span_end","id":"s_2","at_ms":3.4,"status":"ok"}
{"op":"span_start","id":"s_3","parent_id":"s_1","action_id":"a_1","lane":"render","type":"render","label":"render posts/new","at_ms":3.5,"data":{"template":"posts/new"}}
{"op":"span_end","id":"s_3","at_ms":5.1,"status":"ok"}
{"op":"span_end","id":"s_1","at_ms":5.5,"status":"ok","data":{"status_code":200,"content_type":"text/html"}}
{"op":"event","id":"e_1","parent_id":"s_1","action_id":"a_1","lane":"dom","type":"snapshot","label":"initial DOM loaded","at_ms":5.8,"artifact_ids":["art_dom_1"]}
{"op":"artifact_ref","id":"art_dom_1","type":"dom_snapshot","label":"DOM after visit","created_at_ms":5.8,"content_type":"text/html","path":"artifacts/art_dom_1.html"}
{"op":"action_end","id":"a_1","at_ms":6.0,"status":"ok"}

{"op":"action_start","id":"a_2","lane":"test","type":"fill_in","label":"fill_in \"Title\", with: \"Hello\"","at_ms":7.0,"data":{"field":"Title","value":"Hello"}}
{"op":"event","id":"e_2","parent_id":"a_2","action_id":"a_2","lane":"browser","type":"input","label":"input title","at_ms":7.2,"data":{"target":"input[name='post[title]']"}}
{"op":"action_end","id":"a_2","at_ms":7.4,"status":"ok"}

{"op":"action_start","id":"a_3","lane":"test","type":"click","label":"click_button \"Create\"","at_ms":8.0,"data":{"method":"click_button","argument":"Create"}}
{"op":"event","id":"e_3","parent_id":"a_3","action_id":"a_3","lane":"browser","type":"dispatch_event","label":"dispatch click","at_ms":8.1,"data":{"event_type":"click","target":"button[name='commit']"}}
{"op":"event","id":"e_4","parent_id":"e_3","action_id":"a_3","lane":"browser","type":"submit","label":"submit form","at_ms":8.3,"data":{"target":"form[action='/posts']"}}
{"op":"span_start","id":"s_4","parent_id":"e_4","action_id":"a_3","lane":"rack","type":"request","label":"POST /posts","at_ms":8.8,"data":{"method":"POST","path":"/posts"}}
{"op":"span_start","id":"s_5","parent_id":"s_4","action_id":"a_3","lane":"rails","type":"controller","label":"PostsController#create","at_ms":9.1,"data":{"controller":"PostsController","action":"create","format":"turbo_stream"}}
{"op":"span_start","id":"s_6","parent_id":"s_5","action_id":"a_3","lane":"db","type":"sql","label":"Post Create","at_ms":10.0,"data":{"name":"Post Create","sql":"INSERT INTO posts (...) VALUES (...)"}}
{"op":"span_end","id":"s_6","at_ms":10.8,"status":"error","data":{"exception_class":"ActiveRecord::RecordInvalid","message":"Validation failed"}}
{"op":"span_end","id":"s_5","at_ms":12.2,"status":"ok"}
{"op":"span_start","id":"s_7","parent_id":"s_4","action_id":"a_3","lane":"render","type":"render","label":"render posts/_form","at_ms":12.4,"data":{"template":"posts/_form"}}
{"op":"span_end","id":"s_7","at_ms":14.0,"status":"ok"}
{"op":"span_end","id":"s_4","at_ms":14.4,"status":"ok","data":{"status_code":422,"content_type":"text/vnd.turbo-stream.html"}}
{"op":"event","id":"e_5","parent_id":"s_4","action_id":"a_3","lane":"turbo","type":"turbo_stream","label":"turbo-stream replace #post_form","at_ms":14.9,"data":{"action":"replace","target":"post_form"}}
{"op":"event","id":"e_6","parent_id":"e_5","action_id":"a_3","lane":"dom","type":"mutation","label":"replace #post_form","at_ms":15.2,"data":{"operation":"replace","target":"#post_form"},"artifact_ids":["art_dom_2","art_dom_3"]}
{"op":"artifact_ref","id":"art_dom_2","type":"dom_snapshot","label":"DOM before replace #post_form","created_at_ms":15.1,"content_type":"text/html","path":"artifacts/art_dom_2.html"}
{"op":"artifact_ref","id":"art_dom_3","type":"dom_snapshot","label":"DOM after replace #post_form","created_at_ms":15.3,"content_type":"text/html","path":"artifacts/art_dom_3.html"}
{"op":"action_end","id":"a_3","at_ms":15.5,"status":"ok"}

{"op":"action_start","id":"a_4","lane":"assertion","type":"assertion","label":"expect page to have_text \"Created\"","at_ms":16.0,"data":{"matcher":"have_text","expected":"Created","timeout_ms":5000}}
{"op":"event","id":"e_7","parent_id":"a_4","action_id":"a_4","lane":"assertion","type":"assertion_check","label":"text not found","at_ms":16.1,"status":"failed","data":{"expected":"Created","found":false}}
{"op":"event","id":"e_8","parent_id":"a_4","action_id":"a_4","lane":"assertion","type":"assertion_check","label":"text not found","at_ms":116.2,"status":"failed","data":{"expected":"Created","found":false}}
{"op":"error","id":"e_9","parent_id":"a_4","action_id":"a_4","lane":"assertion","label":"Expectation failed","at_ms":5016.5,"status":"failed","data":{"exception_class":"RSpec::Expectations::ExpectationNotMetError","message":"expected to find text \"Created\""},"artifact_ids":["art_dom_3"]}
{"op":"action_end","id":"a_4","at_ms":5016.6,"status":"failed"}
{"op":"trace_end","trace_id":"tr_1","at_ms":5017.0,"status":"failed","data":{"failed_action_id":"a_4","exception_class":"RSpec::Expectations::ExpectationNotMetError","message":"expected to find text \"Created\""}}
```

## viewer 側の解釈

viewer は NDJSON を行ごとに読み、以下のように内部モデルを構築する。

```text
trace_start
  -> TraceDocument 初期化

action_start
  -> Action 作成、未終了状態にする

action_end
  -> Action を終了、statusを設定

span_start
  -> Span 作成、未終了状態にする

span_end
  -> 既存 Span を終了、end_ms/status/dataをmerge

event
  -> Event 作成

artifact / artifact_ref
  -> Artifact 登録

trace_end
  -> TraceDocument 終了
```

## 未終了 span の扱い

`span_start` があり `span_end` がない場合、viewer は未終了 span として表示する。

```text
status: pending
end_ms: current_time または trace_end.at_ms
```

これにより、ハング時にも「どこで止まったか」が見える。

## 書き込み方針

trace emitter は各行を書いた後、必要に応じて flush する。

推奨:

- ローカル実行では action/span/event ごとに flush
- CIではバッファリングしてもよいが、ハング調査を重視する場合はこまめに flush
- 最低でも `span_start`, `action_start`, `error` は即 flush する

## redact

機密情報を含む可能性のある項目は redact できることが望ましい。

対象例:

```text
password
token
authorization
cookie
secret
api_key
credit_card
```

redact 後の例:

```json
{
  "params": {
    "email": "user@example.com",
    "password": "[REDACTED]"
  }
}
```

## バージョニング

`trace_start.version` で仕様バージョンを示す。

```json
{"op":"trace_start","version":1}
```

破壊的変更を行う場合は version を上げる。

## 最小実装セット

初期実装では以下だけでよい。

```text
trace_start
trace_end
action_start
action_end
span_start
span_end
event
artifact_ref
error
```

最低限の lane:

```text
test
browser
rack
rails
db
render
dom
assertion
log
```

最低限の viewer 表示:

```text
横軸: at_ms
縦軸: lane
span_start/span_end: bar
event/error: marker
action_id: 関連イベントのハイライト
artifact_ref: details panel で表示
```

## 設計上の原則

- NDJSON は描画座標ではなく trace の意味論を表す
- Canvas 用の `x`, `y`, `width` は出力しない
- 時刻は monotonic ms を基本にする
- 大きな情報は artifact として分離する
- `parent_id` で因果関係を表す
- `action_id` で browser/test action 単位の関連を表す
- 未終了 span を許容する
- 完成済み `trace.json` は NDJSON から生成可能にする
- リアルタイム viewer は NDJSON stream を逐次 apply して実現する
