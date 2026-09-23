# 11. 外部リソース（スクリプト・fetch）

> 執筆予定。

## resources という共通の入口

- 外部 `<script src>` も `fetch` も、`resources` アダプタ一つが供給する（同じ入口）
- ブラウザ生成時の `resources:` に渡す

## アダプタの種類

- `Dommy::Resources.static("/app.js" => "…")`：文字列で解決する
- `Dommy::Resources.file_system(root:, base_url:)`：ビルド済み asset を読む
- `Dommy::Resources.chain(...)`：fixture とファイルを合成する

## 動的に挿入されるスクリプト

- 実行時に追加される `<script src>`（webpack/Vite のチャンク）も同じアダプタで解決する

## fetch のスタブ

- `fetch` の応答を同じ resources から差し込む

---

前章：[JS エラーの扱い](10-js-errors.md) / 次章：[ES module / import map](12-es-modules.md)
