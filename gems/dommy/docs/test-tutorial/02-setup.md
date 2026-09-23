# 2. セットアップ

## dommy と JS バックエンド

`Dommy::Browser`で DOM の操作を行うだけなら `dommy` 本体で足ります。
一方、ページ内の JavaScript を動かすにはJSエンジンを選択できるように、JS バックエンドを別途追加して使うようになっています。
標準の JS バックエンドは、QuickJS を組み込んだ `dommy-js-quickjs` です。
`Gemfile` には二つのgemを並べます。

```ruby
gem "dommy"
gem "dommy-js-quickjs"
```

`dommy` が DOM を受け持ち、`dommy-js-quickjs` がその DOM に対して JavaScript を実行するエンジンを受け持ちます。
データベースと同じで、本体に対してエンジンを一つ選んで足す構図です。

## `Dommy::Browser`の読み込み

指定した JS バックエンド gem は、require した時点で使えるようになります。
`dommy/js/quickjs` を require すると、QuickJS ランタイムが既定のバックエンドとして登録されます。
`Dommy::Browser` 自体には特に指定を行う必要はなく、バックエンドが使われます。
このファイルは内部で `dommy` 本体も読み込むので、必要な require はこの一行だけです。

```ruby
require "dommy/js/quickjs"
```

## RSpec の設定

ここではテスト枠組みに RSpec を使います。
`spec_helper` に、さきほどのバックエンドの require と dommy のマッチャをまとめ、マッチャをスペックから使えるようにします。

```ruby
# spec/spec_helper.rb
require "dommy/js/quickjs"
require "dommy/rspec"

RSpec.configure do |config|
  config.include Dommy::RSpec::Matchers
end
```

`Dommy::RSpec::Matchers` を include すると、`contain_dom` などのマッチャを `expect(...).to contain_dom(...)` の形で書けます。
Minitest 向けの assertion も用意されていて、その使い分けは8章で扱います。

## 最初のスペック

インラインの `<script>` が見出しのテキストを書き換えるページを用意し、その結果を `contain_dom` で確かめます。

```ruby
# spec/welcome_spec.rb
require "spec_helper"

RSpec.describe "welcome page" do
  let(:html) do
    <<~HTML
      <html><body>
        <h1 id="greeting"></h1>
        <script>
          document.getElementById("greeting").textContent = "こんにちは";
        </script>
      </body></html>
    HTML
  end

  it "runs the inline script that fills in the heading" do
    Dommy::Browser.open(html) do |browser|
      expect(browser.document).to contain_dom("h1", text: "こんにちは")
    end
  end
end
```

`Dommy::Browser.open` は HTML を解析し、その場で `<script>` を実行します。
ブロックを渡すと、ブロックの中で `browser` としてブラウザを受け取り、ブロックを抜けると後片付けまで済ませます。
空だった見出しをスクリプトが「こんにちは」で埋めたあと、`contain_dom` がその DOM を確かめます。
DOM を JavaScript の式として読み取る `Browser#evaluate` や、Ruby 側の DOM API は5章以降で扱います。

---

前章：[はじめに](01-introduction.md) / 次章：[ブラウザのライフサイクル](03-lifecycle.md)
