# R6 並列スケーリング + fork 安全性の実測（2026-07-15）

adoption-research.md の R6。
「メモリが小さいと並列度を上げられるか」を推論でなく実測で確かめ、
`parallelize`（fork）で dommy ブラウザが安全に動くかを検証する。

## 環境

8 コア / 16GB（M 系 Mac）。対象は todo-app の system spec（8 examples）。

## 方法

### A. 同時実行スケーリング

`TOTAL_JOBS=8` 本の独立した rspec suite 実行を、同時実行数 C の worker pool で回す。
C を 1/2/4/8 と変え、driver（dommy / headless Chrome）別に計測する。

- **DB 分離が前提**：素の同時 rspec は同一 SQLite（`storage/test.sqlite3`）を共有して
  "database is locked" で全滅する。各ジョブに別 DB ファイル（`DATABASE_URL`）を割り当てて
  分離した。これは並列テスト一般の要件（Rails の `parallelize` は per-worker DB を自動生成する）
- 計測：全 8 ジョブ完了までの壁時計（→ throughput = 8/wall）、
  プロセスツリー全体の peak RSS（Chrome の子プロセス込み）、失敗数

### B. fork 安全性

Rails の minitest `parallelize`（fork）を模す：親が VM を 1 つ作って dispose し
（before(:suite) warmup と同じ）、その後 N 個 fork、各子が**新しい VM でブラウザを作り
DOM を構築**して 0/1 で exit する。

## 結果 A：スケーリング

| driver | C | 壁時計 | throughput (suites/s) | peak RSS | fails |
|---|---:|---:|---:|---:|---:|
| dommy | 1 | 16.94s | 0.47 | 153MB | 0 |
| dommy | 2 | 9.38s | 0.85 | 310MB | 0 |
| dommy | 4 | 7.41s | 1.08 | 586MB | 0 |
| dommy | 8 | 6.06s | 1.32 | 1153MB | 0 |
| chrome | 1 | 44.72s | 0.18 | 983MB | 0 |
| chrome | 2 | 48.76s | 0.16 | 1744MB | 0 |
| chrome | 4 | 31.73s | 0.25 | 3356MB | 0 |
| chrome | 8 | 51.48s | 0.16 | 6079MB | 0 |

### 読み取り

- **メモリはどちらも同時実行数に比例**。dommy は約 144MB/worker（8 並列で 1.15GB）、
  Chrome は約 760MB〜1GB/worker（8 並列で 6.08GB）。16GB でも Chrome 8 並列は
  ブラウザだけで 6GB を使い、app/DB/OS を足すと余裕が薄い。dommy は 8 並列でも 1.15GB
- **throughput のスケールは正反対**。dommy は同時実行数を上げると改善する
  （0.47→1.32、C=8 で 2.8x）。Chrome は**ほぼ横ばい**（0.16〜0.25）で、C=8 は C=1 と同速。
  Chrome は 1 worker が chromedriver + chrome + renderer の複数プロセスを持つため、
  C=8 では 8 コアに対しプロセス数が大幅に超過し、CPU 競合で throughput が伸びない
- **C=8（コア数一致）での比較**：dommy 6.06s / 1153MB / 1.32 t/s に対し
  Chrome 51.48s / 6079MB / 0.16 t/s。**dommy は壁時計 8.5x 速く、メモリ 5.3x 少なく、
  throughput 8.3x**

### 正直な限界

- dommy の throughput が C=8 で 8x でなく 2.8x なのは、各ジョブの **Rails boot
  （約 1.5s 固定・CPU 重）が 8 並列で競合する**ため。dommy 固有でなく両ドライバ共通で、
  並列の旨味は boot が償却される**長い suite ほど大きい**。この 8 examples の tiny suite は
  boot 支配的で、並列スケールを過小評価する条件
- Chrome の壁時計は非単調（C=2 が C=1 より遅い、C=8 ≒ C=1）で分散が大きい。
  マルチプロセスのオーバーサブスクリプションによる変動。「Chrome は同時実行で速くならない」
  という定性が要点で、個々の数値は幅を持つ
- 8 コア / 16GB という 1 環境の結果。より高コア・低メモリの箱では Chrome のメモリ律速が
  もっと早く効き、逆に潤沢メモリ・低コアでは差が縮む

## 結果 B：fork 安全性

```
parent: warmed + disposed a VM
children exit statuses: [0, 0, 0, 0]
FORK-SAFE: all 4 children built DOM in a fresh VM
```

親が VM を作って dispose した後に fork した 4 子すべてが、**新しい VM で 50 ノードの
DOM 構築に成功**した。QuickJS VM は fork 安全であり、Rails minitest の
`parallelize`（fork）経路で dommy ブラウザは安全に動く（G21 の VM 相続懸念は否定）。
warmup が VM を dispose するため fork 時に生きた VM が残らない設計も裏付けられた。

## R6 が答えた問い（と残る宿題）

- **メモリ→並列度**：メモリは同時実行数に線形で、dommy の低フットプリント（144MB/worker）は
  実測で確認。ただし**この 8 コア箱では CPU（Chrome はプロセス競合）が先に律速**し、
  メモリ優位が「より多い worker」に直結するのは高コア・低メモリ環境で顕著、という
  以前の保留どおりの結論。事実として記録し、過大主張はしない
- **fork 安全性**：確認済み（G21 の VM 相続は問題なし）
- **DB 分離**：並列テストの前提（per-worker DB）を実証。dommy 特有ではないが移行ガイドに要記載
- **残る宿題**：(a) 長い suite（boot 償却後）での throughput、(b) 実際の Rails
  `parallelize(workers:)` end-to-end（本 R6 は fork 安全性を直接プローブ + 同時実行を
  DB 分離で近似した。Rails の worker-DB 自動生成経路そのものは未計測）、
  (c) G21 の tmp/dommy/failures worker 衝突（未検証、worker 番号付与で解消見込み）

## 再現

```sh
# A: スケーリング（各ジョブに独立 DB を割り当て）
cd ~/git/dommy-examples/todo-app
RAILS_ENV=test bundle exec rails db:test:prepare
for i in $(seq 0 7); do cp storage/test.sqlite3 storage/test_$i.sqlite3; done
TOTAL_JOBS=8 CONC=1,2,4,8 ruby /private/tmp/r6_scaling.rb
rm storage/test_*.sqlite3

# B: fork 安全性
cd ~/git/dommy-js-quickjs && bundle exec ruby /private/tmp/r6_fork.rb
```

harness は一時ファイル（`/private/tmp/r6_scaling.rb`, `/private/tmp/r6_fork.rb`）。
恒久化するなら dommy-examples の bench ディレクトリへ。

## 関連文書

- `r2-corpus-benchmark.md`：単一プロセスの速度・メモリ（本 R6 の per-worker 値の裏付け）
- `functional-gaps.md`：G21（parallelize の粗さ）、G22（cable のスレッド跨ぎ）
- `adoption-research.md`：R6 の位置づけ
