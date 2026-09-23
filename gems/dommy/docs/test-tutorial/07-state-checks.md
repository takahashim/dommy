# 7. Browser の述語で状態を確認する

ブラウザを操作した後で、ページが期待どおりの状態になったかを確かめます。
`Dommy::Browser` は、「その要素があるか」「そのテキストが出ているか」を yes/no で答える述語メソッドを持っています。
操作で動いた結果の DOM に対して、これらのメソッドを使って状態を確認します。

## 状態を尋ねる述語メソッド

述語は、いまの状態について真偽を返します。

- `has_css?`：セレクタに合う要素があるか
- `has_text?`：そのテキストが出ているか
- `has_link?` / `has_button?` / `has_field?`：リンク・ボタン・入力欄があるか
- `has_role?`：そのロールの要素があるか

```ruby
browser.has_text?("保存しました")   # => true / false
```

否定形もあります。
あるのは `has_no_css?` / `has_no_text?` / `has_no_role?` の三つで、Dommy は同期に動くので、これらは素直な否定です。
link・button・field に否定形はないので、それらを否定したいときは結果を反転させます。

## 操作してから確かめる方法

テストの基本の形は、操作してから結果の状態を確認する、という流れになります。
6章の操作メソッドでページを動かし、述語で結果を確認します。

```ruby
require "spec_helper"

RSpec.describe "save button" do
  let(:html) do
    <<~HTML
      <html><body>
        <button type="button">保存</button>
        <p id="msg"></p>
        <script>
          document.querySelector("button").addEventListener("click", () => {
            document.getElementById("msg").textContent = "保存しました";
          });
        </script>
      </body></html>
    HTML
  end

  it "shows a message after the button is clicked" do
    Dommy::Browser.open(html) do |browser|
      browser.click_button("保存")
      expect(browser).to have_text("保存しました")
    end
  end
end
```

`expect(browser).to have_text(...)` は、`has_text?` 述語を RSpec のマッチャの形で書いたものです（`has_X?` が `have_X` になります）。
否定は `expect(browser).not_to have_text(...)` と書きます。
マッチャの全体像と、DOM ノードに直接かけるマッチャとの使い分けは続く8章で扱います。

---

前章：[ページを操作する（Capybara 語彙）](06-interacting.md) / 次章：[テストフレームワークの matcher / assertion](08-matchers.md)
