# Dommy Trace NDJSON 仕様

## 現行契約 (version 2, 2026-07 確定)

実装済みの契約は当初の v1 案ではなく **flat v2** である。本書はその flat v2
だけを記述する（v1 案は `notes/trace-ndjson-v1-draft.md` に分離）。正は次の 3 点。

- **emitter**: `Dommy::Rack::Trace::Ndjson`（1 行 1 JSON、`seq` が正順、
  op 固有フィールドは行に平坦化）
- **golden fixture**: `../test/fixtures/contract.trace.ndjson` —
  emitter（`test/support/trace_contract.rb` が生成・検証）と viewer
  （dommylizer が同一ファイルを vendored fixture としてパース検証）が
  コードを共有せずこのファイル形式だけで結合する契約テスト
- **viewer**: dommylizer の `Document.from_lines`（未知 op は捨てずに
  generic Event として保持 — 前方互換）

### v2 の行形式

全行が `seq`（正順）と `op` を持ち、時刻は `t`（仮想クロック、文書出現前は
null）と `wall_ms`（trace 開始からの実 ms）の二本立て。op 固有フィールドは
`data` に包まず行に直接置く。

| op | 主フィールド |
|---|---|
| `trace_start` | `version: 2`, `level`, 任意で `wall_time`/`metadata` |
| `action` | `verb`, `label`, `source`。後続行が `action` フィールドでこの seq を参照 |
| `http` | `method`, `path`, `query`, `status`, `content_type`, `location`, `set_cookie`（リダイレクトは 1 ホップ 1 行） |
| `form` | `method`, `path`, `params`（ParamFilter で redact 済み） |
| `document` | `url`, `title` |
| `script` / `console` / `js_error` | `:verbose` レベルのみ |
| `dom` | mutation。内部の種別は `kind` |
| `artifact_ref` | `path` または `content`/`encoding` |
| `error` | `label`, `source`, `data: {exception_class, message}` |
| `trace_end` | `status` |

時間幅の表現（span）は v2 に無い。Rails 内部計装（notes/trace-roadmap.md
フェーズ 2）で入れ子が必要になった時点で、`parent` + `duration_ms` を持つ
完成形 span 行を最小拡張として追加する（v1 案の span_start/end 分割は
同期実行の dommy には過剰、の判断も notes/trace-roadmap.md に記録済み）。

## v1 設計案について

当初の v1 設計案（`span_start` / `span_end` の分割、`lane`、`trace.json`
への変換など）は実装されていない。将来 span 形式を拡張する際の参照資料と
して `notes/trace-ndjson-v1-draft.md` に分離してある。本書に書かれている
ことだけが現行契約である。
