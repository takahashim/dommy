# 5. JavaScript を実行する

テストの大半は、ここまでの DOM の読み取りと、次章からの操作メソッドで書けます。
それでも、DOM には出てこない値を読みたいときや、操作メソッドでは表せない動かし方をしたいときがあります。
`Browser#evaluate` と `Browser#execute` は、そうした場面でページの JavaScript に直接降りるための抜け道です。

## evaluate と execute

`evaluate` は式を評価して値を返し、`execute` は副作用のために JavaScript を走らせます。
どちらもページと同じ文脈で動くので、`window` や `document`、ページのスクリプトが定義したものをそのまま参照できます。

DOM に出ていない値を読みたいときは `evaluate` です。
アプリがグローバルに置いた設定や、コントローラが内部に持つ状態など、画面の DOM だけでは取れない値を読めます。

```ruby
Dommy::Browser.open(html) do |browser|
  browser.evaluate("window.appConfig.locale")   # => "ja"
end
```

操作メソッドにない動かし方をしたいときは `execute` です。
戻り値は取らず、`nil` を返します。
カスタムイベントを発火したり、アプリの関数を直接呼んだりして、ページを動かします。

```ruby
Dommy::Browser.open(html) do |browser|
  browser.execute("window.dispatchEvent(new Event('app:refresh'))")
end
```

`evaluate` に渡すのは式です。
宣言を含む文をまとめて渡しても結果は返らないので、値が欲しいときは、返してほしいものを一つの式として書きます。

## やりとりできる値

`evaluate` で読んだ値は、JavaScript から Ruby に変換されて返ります。
基本の型はそのまま対応します。

| JavaScript | Ruby |
| --- | --- |
| 文字列 | `String` |
| 数値 | `Integer` / `Float` |
| 真偽値 | `true` / `false` |
| 配列 | `Array` |
| オブジェクト | `Hash`（キーは文字列） |
| `null` | `nil` |

一つだけ注意が要るのは `undefined` です。
`undefined` は `nil` ではなく、`Dommy::Bridge::UNDEFINED` という専用の値で返ります。
未定義の変数や存在しないプロパティを読むとこれになるので、値が `null` だった場合（`nil`）と区別されます。
ある値が「無い」ことを確かめたいだけなら、JavaScript 側で `typeof` を見るほうが簡単です。

```ruby
Dommy::Browser.open(html) do |browser|
  browser.evaluate("typeof window.App")   # => "undefined"（未定義のとき）
end
```

## 使いどころ

`evaluate` と `execute` は、ページの JavaScript の内部に手を伸ばすぶん、その作りに結びつきます。
グローバル変数や内部状態の名前が変われば、テストも一緒に直すことになります。
画面に出る挙動は DOM と操作メソッドで確かめ、これらは「そこからは届かないもの」に絞るのが安全です。

---

前章：[DOM を調べる](04-inspecting-the-dom.md) / 次章：[ページを操作する（Capybara 語彙）](06-interacting.md)
