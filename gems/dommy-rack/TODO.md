# TODO: dommy-rack 側で検討したい項目

## フレーム window の同一性を保持する(再入時に同じ realm を返す)

### 現状

iframe を開くたびに、フレーム文書を**毎回 fetch して新しい Window/document を生成**している。
フレームロード経路は 2 つあり、どちらも再 fetch する:

- `Session#within_frame`（`lib/dommy/rack/session.rb:284`）
  `frame_doc = fetch(resolve_document_url(src), headers: referer_headers).document`
- capybara-dommy `Driver#load_frame`（`capybara-dommy/lib/capybara/dommy/driver.rb:235`）
  `rack_session.fetch(url, headers: ...).document`

そのため、同じ iframe に**別々の `within_frame` / `switch_to_frame` で再入する**と、
document オブジェクトが毎回新規になる。

### なぜ問題になり得るか

dommy-js-quickjs の Capybara アダプタは「document → Runtime（= realm）」のマップで
JS VM を管理している（各 window が独自のグローバル・リスナー・タイマーを持つ realm）。
フレーム document が再入のたびに新規だと、**フレーム側に仕込んだ JS 状態が再入で失われる**。

```ruby
within_frame(:f) { execute_script('window.__x = 1') }
within_frame(:f) { evaluate_script('window.__x') }   # → undefined（実ブラウザなら 1）
```

実ブラウザでは iframe の window は（リロードしない限り）再入でも保持されるので、これは差分。

### 現時点で実害がない理由（=今やらない判断の根拠）

- `within_frame` は**ブロックスコープ**。1 ブロック内では document が安定するので、
  ブロックをまたがない限り状態は保持される。
- トップ window の realm 状態は dommy-js-quickjs 側で保持済み
  （フレーム往復後もトップのリスナーが発火することを確認済み）。これが本来直したかった回帰。
- compliance の js グループはまだ未有効で、この差分を踏むテストは現状ゼロ。

### 実装するときに必要なこと（簡単な一行修正ではない）

1. **フレーム window レジストリ**を導入する（キー = iframe 要素 + src、値 = Window）。
   現状フレームは「ステートレスな再 fetch」モデルなので、window 同一性という概念を新設することになる。
2. **無効化を正しく設計する**（ここを誤ると「古いフレーム内容が残る」= 今より悪い後退になる）:
   - 親ページのナビゲーション時（`on_document_loaded` はトップ用で、フレームキャッシュとは未連携）
   - iframe の `src` 変更時
   - iframe が DOM から切り離された時
3. **2 つのフレームロード経路（`within_frame` と driver `load_frame`）を統一**する。
   片方だけキャッシュ化すると不整合になる。
4. history / origin など付随状態の扱い（cookie jar 共有は既存のまま）。

### 結論

「ステートレス再 fetch → ステートフルな永続 window」というモデル変更であり、無効化バグの
リスクが高い。**需要が顕在化する前の投機的実装は避ける。** compliance の js グループで
フレーム + JS のテストが実際にこれを要求した段階で、上記 1〜4 を設計して入れる。
それまでは「フレーム realm の状態は `within_frame` ブロック内に閉じる」という制約を許容する。
