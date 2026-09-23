# 3. ブラウザのライフサイクル

## ブラウザの生成と破棄

ブラウザを生成する方法は二つあります。どちらを選ぶかは、ブラウザを使う範囲で決まります。

一つはブロック形式です。
`Dommy::Browser.open(html) { |browser| ... }` はブロックの中だけブラウザを使い、ブロックを抜けると自動的に `dispose` します。
一つのテスト内で完結する場合は、こちらを使います。

もう一つは `new` で作る形です。
`Dommy::Browser.new(html)` で生成し、使い終えたら自分で `dispose` を呼びます。
複数のステップやテストでブラウザを使い回したいときに選びます。

```ruby
browser = Dommy::Browser.new(html)
# ページを検査する
browser.dispose
```

`dispose` は、ブラウザが抱えていた JS ランタイムなどのリソースを解放します。
どちらの形でも後始末は欠かせません。
ブロック形式に任せるか、`new` を使うなら RSpec の `after` フックで `dispose` を呼ぶか、いずれかで必ず解放します。

## `Browser.open`のオプション

生成時には、ふるまいを変えるオプションを渡せます。
既定のままでもスクリプトまで実行したページが手に入るので、これらは標準と違う動きが要るときだけ指定します。

- url：ページの番地です。`window.location` に反映され、相対 URL の解決基準になります。
- resources：外部リソースを解決するアダプタです。外部 `<script src>` や `fetch` の応答をここから供給します（11章）。
- execute_scripts：`<script>` を実行するかどうかです。`false` にすると DOM だけを組み立て、スクリプトは動かしません。
- strict：JavaScript エラーの厳格な扱いです。既定は `true` です（10章）。
- settle：生成の最後にページを落ち着かせるかどうかです。既定は `true` です（9章）。
- backend：使う JS バックエンドの選択です。既定では登録済みのバックエンド（`dommy-js-quickjs` を読み込んでいれば QuickJS）を使います。

## ページが立ち上がるまで

ページの立ち上がりは決まった順で進み、`execute_scripts` と `settle` がどこまで進めるかを決めます。
`Dommy::Browser` はまず HTML を解析して DOM を組み立てます。
次に `<script>` を文書順に実行します。
それから `DOMContentLoaded` を、最後に `load` を発火させます。
この進行に合わせて、`document.readyState` は `loading` から `interactive`、`complete` へと移ります。

既定の `settle: true` は読み込み時の処理まで走らせるので、生成を抜けた時点で `readyState` は `complete` に達しています。
スクリプトの実行順や読み込み途中の状態を観察したいときは、`execute_scripts` や `settle` を切って、立ち上がりを途中で止めます。

---

前章：[セットアップ](02-setup.md) / 次章：[DOM を調べる](04-inspecting-the-dom.md)
