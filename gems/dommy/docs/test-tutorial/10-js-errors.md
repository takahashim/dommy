# 10. JS エラーの扱い

ページの JavaScript が壊れている場合、テストは適切に検出できなければなりません。
`Dommy::Browser` は、ページで起きた JS エラーを握りつぶしません。
既定の strict モードでは、捕まえられなかったエラーがあると、その時点でテストを失敗させます。
おかげで、JS の壊れにテストで気づけます。

## strict モードとチェックポイント

strict モードは既定で有効です。
ページのスクリプトが投げた例外や、捕まえられなかった promise の rejection は、`js_errors` に集められます。
そして区切り（チェックポイント）でそれを見つけると、`Dommy::JsError` を投げてテストを失敗させます。

ここで集まるのは、ページが自分で処理しなかったエラーだけです。
ブラウザでは、捕まえられなかった例外がまず `error` イベントとして `window` に飛びます。
ページがそれを `preventDefault` すれば、開発者コンソールには何も出ません。
`Dommy::Browser` も同じ順序で動きます。
そのため、エラー収集ツールを積んだページや、`window.onerror` で握りつぶすページは、ブラウザと同じようにテストも失敗しません。

チェックポイントは、ページが動く区切りです。
ブラウザの生成（スクリプトの起動）、`settle` や `advance_time`、操作メソッド、そしてブロックの終わり（`dispose`）です。
たとえば起動時のスクリプトが例外を投げれば、`Dommy::Browser.open` がそのまま失敗します。

## エラーとログを確かめる

何が起きたかは、`js_errors` と `console` で確かめられます。
`js_errors` は集まったエラー、`console` はページの `console.log` などの出力です。

エラーを失敗にせず中身だけ見たいときは、strict モードを切ります。
`strict: false` で生成すると、エラーは集めるだけで、テストは止まりません。

```ruby
Dommy::Browser.open(html, strict: false) do |browser|
  browser.js_errors   # 集まった JS エラー
  browser.console     # console の出力
end
```

## 意図したエラーを許す

エラーが出るのを承知のうえで操作したいときは、`allow_js_errors` で囲みます。
ブロックの中で起きた JS エラーは、テストの失敗になりません。
エラーは `js_errors` に残るので、出たこと自体を確かめることもできます。

```ruby
Dommy::Browser.open(html) do |browser|
  browser.allow_js_errors do
    browser.click_button("送信")
    browser.settle
  end
  expect(browser.js_errors).not_to be_empty
end
```

エラーを黙らせる方法は、これで二つになりました。
テスト側から囲む `allow_js_errors` と、ページ自身が `window.onerror` で処理する方法です。
テスト対象のページがもともとエラーを握るように書かれているなら、後者が先に働きます。

---

前章：[非同期を扱う](09-async.md) / 次章：[外部リソース（スクリプト・fetch）](11-external-resources.md)
