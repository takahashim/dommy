# 8. テストフレームワークの matcher / assertion

7章では `expect(browser).to have_text("…")` という形でアサーションを書きました。
`expect(対象).to マッチャ` は、「対象がマッチャの条件を満たすか」を調べる RSpec の書き方です。
アサーションが満たさなければ、その場でテストが失敗します。

ここで注目するべきポイントはその「対象」です。
7章は `browser` を対象にして、ページ全体を見ていました。
この章では、`browser.document` や個々の要素を対象にして、もっと狭いところを確かめるマッチャを見ます。

## DOM に対するマッチャ

要素やその中身を確かめるマッチャが `Dommy::RSpec::Matchers` にあります。これは2章で include したmoduleで、そのためテスト内で自由に使えるようになっています。
対象としては、`browser.document` か、`find` で取り出した要素を使います。

いちばんよく使うのは `contain_dom` です。
「対象の中に、このセレクタに合う要素があるか」を調べます。

```ruby
expect(browser.document).to contain_dom("h1", text: "Welcome")
```

これは「document の中に、テキストが Welcome の h1 があるか」を確かめています。
個数を指定したり、要素の属性やクラスを確かめたりもできます。

- `contain_dom(selector, text:, count:)`：その中に条件に合う要素があるか
- `contain_dom_text(text)`：その中にそのテキストがあるか
- `have_dom_attribute(name, value)`：その要素が属性を持つか
- `have_dom_class(class_name)`：その要素がクラスを持つか

```ruby
expect(browser.document).to contain_dom("li", count: 3)

button = browser.find("button")
expect(button).to have_dom_attribute("type", "button")
```

これらの対象は DOM ノードです。
`browser` をそのまま渡すことはできません。

## 述語とマッチャの使い分け

このように、状態を確かめる道具としては二つあります。
どちらを使うべきか迷う場合、何を対象にしたいかで選びます。

- ページ全体に「あるか」を聞く → `expect(browser).to have_text("…")`（7章の述語）
- 特定の要素やその中身を確かめる → `expect(browser.document).to contain_dom("…")`（この章のマッチャ）

たいていのテストは、この二つを使い分けて書くことになります。

## Capybara 風のマッチャ（任意）

Capybara を使ったことがあれば、`have_selector` や `have_link` といった名前に見覚えがあるはずです。
Dommy::Browserでも同じ名前のマッチャが用意されています。そのため、Capybara に良く似たテストを書くこともできます。

```ruby
expect(browser.document).to have_selector("button.primary")
expect(browser.document).to have_link("Sign up", href: "/signup")
```

Capybara風のマッチャを使う場合は明示的に指定する必要があります。
その場合、 `Dommy::RSpec::CapyStyleMatchers` を include します。
特に使わないのであれば include しなくても構いません。

ただし、名前が重なる点に注意が要ります。
`have_text` のような名前は、7章の `expect(browser).to have_text(...)` でも使う名前です。
`CapyStyleMatchers` を include すると `have_text` は DOM ノードを対象にするマッチャに変わるので、`expect(browser).to have_text(...)` は動かなくなります（`expect(browser.document).to have_text(...)` と書きます）。
Capybara 本体とも名前が衝突するので、Capybara を併用する spec には include しない方が混乱を避けられます。

## Minitest の assertion

RSpec ではなく Minitest を使う場合、同様のことを assertion で書けます。
`require "dommy/minitest"` して `Dommy::Minitest::Assertions` を include すると使えます。
対象は第一引数で指定します。

```ruby
assert_dom_contains(browser.document, "h1", text: "Welcome")
```

- `assert_dom_contains(scope, selector, text:, count:)`
- `assert_dom_contains_text(scope, text)`
- `assert_dom_has_role(scope, role, name:, …)`

---

前章：[Browser の述語で状態を確認する](07-state-checks.md) / 次章：[非同期を扱う](09-async.md)
