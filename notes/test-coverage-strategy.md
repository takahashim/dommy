# テスト網羅戦略 — 構造は緑だが挙動が未検証（2026-07-15）

WPT 適合ラチェット（sustainability-research.md が最大の生存要因とした仕組み）の
ブラインドスポットを実測で洗い出し、埋める順序を決める。

## きっかけ

ラベル内チェックボックスの二重発火バグ（react_board で発見、`4046168`）が
WPT で捕まらなかった理由を追ったところ、該当テスト
`the-label-element/clicking-interactive-content.html` は upstream に実在し、
`.click()` で動く runnable なテストなのに、**dommy の vendoring 対象に入っていなかった**。
vendoring した瞬間、私の第一版修正が不完全（27/36）だと露呈し、仕様準拠版（36/36）へ導いた
（`515fecf`）。WPT は「バグ網」であると同時に「**修正の仕様完全性チェック**」である。

## 実測した網羅のブラインドスポット

vendoring 済み WPT（`test/fixtures/wpt/`）のファイル数。

| 領域 | vendoring 数 | 判定 |
|---|---:|---|
| keyboard / keydown | 0 | **空** |
| focus / blur | 0 | **空** |
| pointer / mouse / dblclick / wheel | 0 | **空** |
| drag / input-event / beforeinput | 0 | **空** |
| Range | 23 | 厚い |
| Selection | 2 | 薄い |
| editing / contenteditable / execCommand | 0 | 空（G13 未実装と対応） |
| forms（constraint validation） | 制約検証スイート ~800 subtests | 厚い |
| forms（submission / activation 連携） | 数件 | 薄い |

**DOM 構造 / API / CSS / Range / URL / Promises は厚い（全体 99.4%）。
インタラクション（クリック→活性化→イベント連鎖）と focus と編集は薄い/空。**
今セッションで見つけた 2 バグ（ラベル二重発火、react_board の制御 checkbox）は
どちらもこのインタラクションの薄い領域に住んでいた。

## 構造的な原因

穴はランダムでなく体系的。testdriver の shim（`test/support/wpt_resources.rb`）が
`get_computed_role` / `get_computed_label`（アクセシビリティ照会）**だけ**を実装し、
`test_driver.click` / `Actions`（実ユーザー操作の合成）を持たない。
vendoring 済み WPT で testdriver.click を使うファイルは**ゼロ**。
インタラクション系 WPT は testdriver を要するため、そもそも走らせられない構造だった。

## 高価値な未テスト領域（優先順）

1. **入力・インタラクションイベント（キーボード / マウス / ポインタ / focus・blur）= 空。最大の穴。**
   Rails フォーム（Enter 送信・Space トグル・Tab focus）、a11y（focus 順序）、
   フレームワーク（イベント委譲）が依存。今回の 2 バグの住処。
2. **focus 管理**：focus/blur/focusin/focusout の順序、autofocus、activeElement 遷移、
   `:focus-visible`。1 の部分集合だが微妙で個別価値あり。
3. **Selection / contenteditable / 編集 = ほぼ空**。G13（Trix / ActionText＝Rails 標準）。
   ただし**未実装**なのでテストは「穴の文書化」どまり。順序は実装 → テスト。
4. **capybara-dommy の JS モード compliance = 未実行**（compliance は非 JS モードのみ、
   `spec/compliance/dommy_spec.rb`）。実ブラウザ spec が使う本番経路 dommy_js が
   Capybara 契約レベルで未テストというメタな穴。
5. **フレームワーク相互作用マトリクス（R4、未着手）**。実アプリ関連度は最高。
   react_board が示したとおり単体 WPT が green でもフレームワーク相互作用にバグが残る。

## 梃子の効く一手：testdriver インタラクション shim

一件ずつ vendoring するより、**`test_driver.click(el)` → `el.click()` へ写す shim を作る**方が効く。
これで「クリック要のインタラクション系 WPT」がまとめて走り、優先度 1（空のドメイン）を
一挙に解禁できる。`Actions`（キーボード/ポインタ列）はインタラクション層
（EventSynthesis / send_keys）に写せる余地あり。runnable にできない領域（真のレイアウト依存）は
手書きテスト（`test_input_activation.rb` 型）で補う、という併用戦略。

想定される難所：
- `test_driver.click` は「実ユーザークリック」= trusted な activation。dommy の `.click()`
  （untrusted だが activation は走る）に写すのは概ね妥当だが、isTrusted を期待する
  サブテストは一部落ちる可能性。その差は expected-fail として記録する
- `Actions`（`new test_driver.Actions().pointerMove().pointerDown()...`）はポインタ座標を
  伴い、dommy はレイアウト非対応なので座標依存のテストは対象外。キー入力・単純クリックに絞る

## 価値の低い領域（バランス）

レイアウト/レンダリング（構造的に対象外）、既に 99%+ の領域（Range・URL・Promises・
DOM 構造）は、網羅を増やしても得るものが薄い。

## 推奨順序

1. testdriver.click shim → 入力/インタラクション WPT の一括解禁（優先度 1・2 を同時に埋める）
2. capybara-dommy の JS モード compliance を回す（本番経路の契約テスト、優先度 4）
3. R4（フレームワーク相互作用マトリクス、優先度 5）
4. G13（Selection/編集）は実装が入ってから

## 関連文書

- `sustainability-research.md`：ラチェットが最大の生存要因（本戦略の根拠）
- `functional-gaps.md`：G4（send_keys）、G11（hover/mouse）、G13（contenteditable）
- `driver-diff-matrix.md`：compliance が非 JS モードで回る宿題
- `adoption-research.md`：R4（フレームワーク互換マトリクス）
