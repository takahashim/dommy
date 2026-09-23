# 6. ページを操作する（Capybara 語彙）

`Dommy::Browser`は`Dommy`というRubyによるDOM実装の上に構築されています。
そのため、`Dommy::Browser` の操作メソッドは、本物の DOM イベントを発火します。
だからフォームに値を入れたりボタンを押したりすると、ページの JavaScript ハンドラ（Stimulus コントローラや手書きのリスナ）が実際に動きます。
たとえば検索欄に文字を入れれば、`input` を待つコントローラがその場で一覧を絞り込む、といった挙動の実現されます。
「操作する、ページの JS が反応する、DOM が変わる」という一連の操作を、実ブラウザなしで再現できるわけです。
メソッドの語彙は Capybara に揃えてあるので、system spec を書いたことがあれば見覚えがあるはずです。

## 要素を見つける

操作の前に、対象の要素を見つけます。
`find` は条件に合う一つを返し、`all` は合うものすべてを返します。

```ruby
browser.find("button.primary")
browser.all(".item")               # 複数
browser.find("li", text: "Ruby")   # テキストで絞る
```

`within` は、その中だけにスコープを絞ります。
同じ部品がページに複数あるとき、操作の範囲を一つの領域に限定できます。

```ruby
browser.within("#sidebar") do
  browser.click_link("Edit")
end
```

ロールで探すこともできます。
`find_by_role` と `all_by_role` は、アクセシビリティのロール（`button`、`link`、`heading` など）で要素を選びます。

```ruby
browser.find_by_role("button", name: "Save")
```

## フォームに入力する

フォーム部品への入力は、種類ごとにメソッドが分かれています。

- `fill_in(locator, with:)`：テキスト欄に値を入れる
- `choose(locator)`：ラジオボタンを選ぶ
- `check(locator)`：チェックボックスを入れる
- `select(value, from:)`：セレクトボックスから選ぶ
- `attach_file(locator, path)`：ファイルを選ぶ

```ruby
browser.fill_in("Keyword", with: "ruby")
browser.check("利用規約に同意する")
browser.select("日本語", from: "Language")
```

`locator` には、ラベルの文字列や `name`、`id` を渡せます。
これらの入力は `input` や `change` イベントを発火するので、値の変化に反応するハンドラがそのまま動きます。

## クリックする

クリックは三つあります。

- `click(selector)`：CSS セレクタで指した要素をクリックする
- `click_button(locator)`：ボタンを押す
- `click_link(locator)`：リンクをたどる

```ruby
browser.click_button("Run")
browser.click_link("Next")
```

クリックは `click` イベントを発火します。
ボタンに付いたハンドラが動いた結果、ページがどう変わるかは、次章で確かめます。

---

前章：[JavaScript を実行する](05-executing-javascript.md) / 次章：[Browser の述語で状態を確認する](07-state-checks.md)
