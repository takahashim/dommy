# 4. DOM を調べる

## 起点になる document

`Dommy::Browser.open` を抜けたときには、HTML の解析もスクリプトの実行も済んでいます。
その結果できあがった DOM を手渡すのが `Browser#document` です。
これは `Dommy::Document` のオブジェクトで、ページのスクリプトが書き換えたあとの、生きた DOM ツリーそのものです。
ページの状態を確かめるテストは、ここを起点にします。

```ruby
Dommy::Browser.open(html) do |browser|
  heading = browser.document.query_selector("h1")
  heading.text_content   # スクリプト実行後の見出しテキスト
end
```

元の HTML 文字列そのままのDOMではなく、スクリプトを実行した後の DOM を見ている点がポイントです。

DOM 全体を一目で確かめたいときは `Browser#html` を使います。
これは今の DOM を HTML 文字列に戻すので、テストが落ちたときに「ページが実際にどうなったか」を見るのに向いています。

なお、`Browser#window` はページのグローバルオブジェクト（`location` やグローバル変数の置き場）です。後の章で使いますが、DOM を調べるあいだは `Browser#document` を直接たどれば足ります。

## Ruby から読むか、JavaScript から読むか

DOM を読む経路は二つあります。

一つは Ruby 側で読む経路です。`Browser#document` に `query_selector` や `text_content` といった DOM のメソッドを呼び、結果を Ruby のオブジェクトとして受け取ります。
もう一つは JavaScript 側で読む経路です。こちらは `Browser#evaluate` にページの中で評価する式を渡し、その値を受け取ります。

```ruby
Dommy::Browser.open(html) do |browser|
  # Ruby 側：DOM メソッドを呼び、Ruby オブジェクトを得る
  browser.document.query_selector("h1").text_content

  # JavaScript 側：ページの中で式を評価し、その値を得る
  browser.evaluate('document.querySelector("h1").textContent')
end
```

メソッド名はそれぞれ異なります。Ruby側はスネークケース、JavaScript側はキャメルケースです。これは前者が Rubyの慣習、後者がJavaScriptの慣習に従っているためです。

どちらを使うかは、何を確かめたいかで決まります。
DOM の構造やテキスト、属性を確かめるなら Ruby 側が素直です。2章のマッチャもこの Ruby の DOM の上に乗っています。
一方、スクリプトが設定したグローバル変数や、JavaScript でしか得られない計算結果を読みたいときは `Browser#evaluate` を使います。
`evaluate` の詳しい使い方は5章で扱います。

要素をたどって値を読み出せれば、ページの状態を確かめる土台はそろいます。
ここから先は、その状態をどう操作し、どう確かめるかに進みます。
ページの操作は6章、状態の確認は7章で扱います。

---

前章：[ブラウザのライフサイクル](03-lifecycle.md) / 次章：[JavaScript を実行する](05-executing-javascript.md)
