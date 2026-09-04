# 筆談ボード (Hitsudan)

ペンタブに手書きした内容を Claude に読ませ、視覚的に指示を出すための macOS ネイティブアプリ。

- Swift + AppKit のみ。外部依存ゼロ、単一バイナリ
- **HUION Kamvas 13 Gen3 (GS1333) を IOHIDManager で直接読む** — ベンダードライバなしでも筆圧・傾き・ボタンが取れる
- AI 呼び出しは `claude` CLI 経由。**APIキー不要**（既存のログインをそのまま使う）

## ビルドと起動

```sh
./build.sh
open Hitsudan.app
```

Xcode 本体は不要（Command Line Tools のみで通る）。

初回は **システム設定 → プライバシーとセキュリティ → 入力監視** で `筆談ボード` を許可する。
許可がないと筆圧が取れず、線幅が一定になる（描画自体は動く）。

## 常駐と起動

メニューバー常駐（`LSUIElement`）。普段は Dock にもアプリスイッチャにも出ない。

- **タブレット接続 かつ HID がオープンできている**間だけ、ウィンドウを Kamvas の
  ディスプレイいっぱいに開き、`.regular` に昇格してメニューとショートカットを有効化する
- 抜くと自動でウィンドウを閉じ、排他確保とカーソル操作を解放して常駐に戻る
- メニューバーから「ログイン時に起動」（`SMAppService`）を切り替えられる
- カーソル操作は**既定でON**。設定（カーソル操作・筆圧カーブ・太さ）は `UserDefaults` に保存し、
  前面化のたびに復元する

アイコンは `Resources/icon.svg` が正本。`NSImage` が SVG をネイティブに解釈できるので、
`Tools/makeicon.swift` でラスタライズして `iconutil` に渡している。

## 使い方

| 操作 | |
|---|---|
| ペンで書く | 位置は自前マッピング、筆圧/傾きは生 HID |
| ⌘V / ドラッグ&ドロップ | スクリーンショット等を下敷きにして上から赤で指示を描く |
| ⌘Return | Claude に読ませる（指示はキャンバスに手書きする。入力欄は無い） |
| ⌘Z / ⇧⌘Z / ⇧⌘K | 元に戻す / やり直す / 全消去 |
| ⌘O / ⌘S | 画像読み込み / PNG 書き出し |

画面下のモノスペース行に生 HID の値（モード・筆圧・傾き・生座標・ボタン）が出る。
ドライバを外したときの動作確認はここを見る。

## MCP — セッションとの双方向

主役はこちら。アプリ内で Claude を呼ぶ機能は無い（読むのはセッションの仕事）。

`hitsudan-mcp` は Swift 製・依存なしの stdio MCP サーバ。登録済み:

```sh
claude mcp add --scope user hitsudan -- ~/Developer/hitsudan/hitsudan-mcp
```

| ツール | 用途 |
|---|---|
| `read_board` | 「今」の手書き内容を画像で取得。アプリに最新化させてから読むので、ユーザーが「送る」を押していなくても見える |
| `wait_for_board` | ボードを前面に出し、依頼文を表示して、ユーザーが手書きして「送る」を押すまでブロックして待つ |
| `show_on_board` | **AI が生成したものをボードへ**。`svg` / `image_path` / `text`。SVG は macOS がそのまま描画するので図やレイアウト案を渡せる |
| `clear_board` | 消去を提案する |
| `board_status` | 接続・ストローク数・下敷き・未処理の提案・seq |

### ボードから Claude を起こす

MCP では起こせない（下記）が、**ハーネスのフックからなら起こせる**。
コマンドフックの `asyncRewake` は、バックグラウンドで走って**終了コード 2 でモデルを起こす**。

`Tools/board-wake.sh` を `Stop` フックに仕掛けてある。セッションが応答を終えたあとも
バックグラウンドで `board.json` の `seq` を監視し、ユーザーが「送る」を押した瞬間に
exit 2 で叩き起こす。stderr の文面がそのままモデルに渡る。

```json
"hooks": { "Stop": [ { "hooks": [ {
  "type": "command",
  "command": "~/Developer/hitsudan/Tools/board-wake.sh",
  "asyncRewake": true,
  "timeout": 1830
} ] } ] }
```

未回収の依頼（`~/.hitsudan/requests/<label>.json`）が無ければ即 exit 0 で何もしない。
待ち役はセッションごとに 1 つだけ（`<label>.wait` に pid を置くロック）なので、
停止のたびに監視プロセスが増えることはない。

これで `request_board` → 別作業 → ユーザーが書いて送信 → **セッションが自動で起きて
`collect_board`** という、イベント駆動の往復が成立する。

### MCP の sampling は使えない

Claude Code 2.1.260 のクライアントに `sampling/createMessage` は実装されていない。
申告 capabilities に無いだけでなく、実際に投げると `-32601 Method not found` が返る
（`Tools/samplingprobe.swift` で再現できる）。あるのは `roots` と `elicitation` だけ。
CLI にも実行中セッションへの注入口は無い。

調べた結論。Claude Code 2.1.260 が MCP クライアントとして申告する capabilities は

MCP クライアントの申告内容は `~/.hitsudan/mcp-client.json` に毎回記録しているので、
将来 `sampling` が生えたらそこで気づける。

`wait_for_board` はクライアント側のツールタイムアウトで落ちないよう、既定 55 秒で
**エラーではなく**「まだ」を返す。依頼文はボードに出したままなので、そのまま呼び直せば
待ち続けられる。

### 上書きは必ずユーザーが決める

`show_on_board` と `clear_board` は**即座に反映しない**。送られた内容はボードに
**半透明のプレビュー**として乗り、`適用` / `破棄` の大きなボタン（ペンで押せる大きさ）が出る。
ユーザーが押すまで確定しない。セッション側には `pending: true` が返る。

### アプリと MCP の橋渡し

ソケットではなくファイルベース。どちらが再起動しても壊れない。

```
~/.hitsudan/inbox/<id>.json    セッションからの命令
~/.hitsudan/outbox/<id>.json   アプリの返答
~/.hitsudan/board.png          公開されたシート
~/.hitsudan/board.json         { seq, savedAt, note } — 「送る」で seq が上がる
~/.hitsudan/state.json         接続とキャンバスの状態
```

`wait_for_board` は `board.json` の `seq` の増加を待つ。アプリは inbox を 0.15 秒間隔で
掃き、`BoardBridge` が返答を outbox に書く。起動時に両方を掃除するので、
前回の残骸が新しい命令に見えることはない。

## 動いている Claude セッションへ流す（MCP が使えない場合）

CLI には外部からセッションへ注入する口がないので、2経路を用意してある。

**1. クリップボード（設定不要・その場で効く）**
`セッションへ送る`（⇧⌘Return）でボードを画像としてクリップボードに置き、
`~/.hitsudan/board.png` にも保存する。Claude Code の入力欄で ⌘V。
テキストを同時に載せるとターミナルがそちらを優先するので、画像だけを載せている。

MCP サーバは**セッション開始時に接続される**ので、登録前から動いているセッションには
ツールが出てこない。その場合はクリップボード経由を使う。

## HUION Kamvas 13 Gen3 プロトコル（実測）

USB `VID 0x256C / PID 0x2008`, Product `Huion Tablet_GS1333`。HID インターフェースは3面。

| # | UsagePage/Usage | 用途 |
|---|---|---|
| 0 | `0x01`/`0x0E` | ダイヤル系（report `0x11`） |
| 1 | `0x0D`/`0x02` | 標準デジタイザ（report `0x0A`）＋ express key の keyboard report `0x03` |
| 2 | `0xFF00`/`0x01` | ベンダー面（input `0x08`, feature `0x16`） |

タブレットは2つのモードを持ち、本アプリは両方を解釈する。

### ベンダーモード — report `0x08`, 14バイト
HUION ドライバが起動時に切り替えるモード。

```
[0]  0x08
[1]  bit0 ペン先 / bit1 ボタン1 / bit2 ボタン2 / bit3 ボタン3 / bit7 近接
     0x00 = 圏外, 0x80 = ホバー, 0x81 = 接地
[2:4]  X    u16 LE   0..58760
[4:6]  Y    u16 LE   0..33040
[6:8]  筆圧 u16 LE   0..16383
[8:10] 未使用（常に 0x0000）
[10]   X傾き  int8   ±60
[11]   Y傾き  int8   ±60
[12]   ツール種別（ペン = 0x03）
[13]   未使用
```

X 0..58760 / Y 0..33040 は実測。有効エリア 293.76 × 165.24 mm に対し **5080 LPI**（200 units/mm）で計算が合う。
筆圧 16384 段階は公称値と一致。`0x82` / `0x84` / `0x88` は筆圧ゼロのまま出るので、接地ではなくボタン3系統。

### 標準デジタイザモード — report `0x0A`, 10バイト
ベンダードライバがない状態での既定モード。HID Report Descriptor から読める。

```
[0]  0x0A
[1]  bit0 ペン先 / bit1 サイドボタン / bit2 消しゴム / bit3 反転 / bit6 近接
     実測値は 0xC0 = ホバー, 0xC1 = 接地（bit7 は Descriptor 上パディングだが常に立つ）
[2:4]  X    u16 LE   0..32767
[4:6]  Y    u16 LE   0..32767
[6:8]  筆圧 u16 LE   0..16383
[8]    X傾き int8
[9]    Y傾き int8
```

**これが重要な結論**: 標準モードでも筆圧 16384 段階と傾きが出る（実測で 1781→16330 まで確認）。
つまりベンダードライバを外しても、筆圧・傾きは失われない。

ただし失われるものが2つある。

1. **NSEvent の筆圧** — ベンダードライバは筆圧付きの tablet イベントを合成していた。
   外すと `event.pressure` が 0 で来るので、NSEvent 頼みの実装は線が消える。
   本アプリは生 HID を読むのでこれに依存しないが、HID が受け取れないときの
   フォールバックでは「筆圧情報なし」とみなして一定幅で描く。
2. **筆圧カーブ** — 生センサ値は軽いタッチ側が極端に非線形。ドライバが当てていた
   カーブは `CanvasView.pressureCurve`（ガンマ）として自前で持つ。既定 0.65。

### 入力監視の許可と署名

アドホック署名だとビルドのたびに cdhash が変わり、TCC の許可が毎回無効になる
（`IOHIDCheckAccess` が「拒否」になり、許可ダイアログも出なくなる）。
そこで**安定した自己署名鍵**で署名している。

```
designated => identifier "local.hitsudan.board" and certificate leaf = H"6a2771bc…"
```

要件に cdhash が入らないので、再ビルドしても許可が生き続ける。

鍵は login キーチェーンの `Hitsudan Local Signing`。控えは `~/.hitsudan/signing/`。

**署名鍵の再作成**（キーチェーンから消えた場合）:

```sh
cd ~/.hitsudan/signing
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config cert.cnf -keyout key.pem -out cert.pem
openssl pkcs12 -export -out id.p12 -inkey key.pem -in cert.pem -passout pass:hitsudan \
  -name "Hitsudan Local Signing" -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
security import id.p12 -k ~/Library/Keychains/login.keychain-db -P hitsudan -A
```

macOS の `security import` は OpenSSL 3 の既定の PKCS#12 を読めないので、
`-certpbe/-keypbe/-macalg` の指定は必須。証明書を作り直すと要件が変わるので、
入力監視の許可は取り直しになる。

**許可が「拒否」で固まったら**: 一度拒否になると `IOHIDRequestAccess` はダイアログを出さない。
システム設定 → プライバシーとセキュリティ → 入力監視 から `筆談ボード` の項目を
**「−」で削除**してからアプリを再起動する。

### 状態の確認先

アプリは2秒ごとに `~/.hitsudan/hid-status.log` に自分の状態を書く。

```
入力監視 許可 / open 成功  デバイス=検出  最終サンプル=0.1秒前  モード=HID digitizer 0x0A
割当=Kamvas 13  画面=Kamvas 13|…
```

画面下のテレメトリ行にも同じ内容が出る。

## ペンの割り当て先ディスプレイ

ベンダードライバが無いと、macOS は汎用デジタイザを**カーソルがいるディスプレイ**に
割り当てる。マウスを別の画面に動かすとペンの反映先も動いてしまう。

対策として、生 HID の絶対座標を指定ディスプレイに自前でマッピングしている。
画面下の `ペン割当` で選ぶ:

- **自動** — 名前に kamvas / huion / gs1333 を含むディスプレイを探して使う
- **各ディスプレイ名** — 手動指定
- **カーソル追従** — 旧来の OS 任せ（生 HID が無いときの動作）

絶対座標モードのときはマウスからの描画を無視する（二重ストロークを防ぐため）。
生 HID が 2.5 秒途切れたら自動でマウスに戻すので、描けなくなることはない。

デジタイザの原点は上辺基準。`CGDisplayBounds` も左上原点・y下向きなので、変換は不要。

## カーソルとクリックの自前実装

`カーソル操作` を入れると `PenPointer` がシステム全体のポインタを持つ。

**デバイスの排他確保** — `IOHIDManagerOpen` に `kIOHIDOptionsTypeSeizeDevice` を渡す。
root は不要で、入力監視の許可だけで通る。これをしないと macOS 自身が同じレポートから
カーソルを動かし続け、自前のイベントと二重になって「押しっぱなし」「ストロークが消える」
が起きる。

**クリックの発火はペン先スイッチ** — デバイスは筆圧 1781/16383（約11%）でスイッチを立てる。
macOS の汎用処理はそれよりずっと重い閾値を使うため「強く押さないと反応しない」になる。
tip ビットをそのまま使うのが最も軽い。

**カーソルの記憶はデバイスごと** — ペンを離してもカーソルはペンが置いた場所に残る。
**実際にマウスを動かした瞬間**に、マウス自身が最後にいた位置へ戻す
（`NSEvent` のグローバル／ローカルモニタで検出。自分が生成したイベントは近接中と
直後 0.2 秒を除外して弾く）。

**イベントにタブレット属性を載せる** — `mouseEventSubtype` をタブレットにし、筆圧・傾き・
ボタンを `tabletEvent*` フィールドに入れる。他のお絵かきアプリでも筆圧が効く。

**ランループのモード** — HID デバイスは `commonModes` にスケジュールすること。
`defaultMode` だと、AppKit がボタン押下やメニュー表示でイベント追跡ループに入っている間だけ
ペンのレポートが止まり、離しても `mouseUp` が生成されない。

サイドボタン1は右クリックに割り当ててある。

## 図形補正

描いたあとペンを離さずに 0.55 秒静止すると、直線・円・四角・三角に整形される。
整形後もペンを離すまで伸縮できる（三角は角の取り方が一意でないので固定）。

判定は $1 Unistroke Recognizer（Wobbrock, Wilson & Li, UIST 2007 / New BSD）の移植。
`Sources/DollarRecognizer.swift`。**何を描いたか**は認識器が決め、**どこにどの大きさで**
置くかは `CanvasView` 側が実際の点に当てて決める。

移植にあたっての変更点:

- 閉じた図形は開始位置に敏感なので、4つの開始点 × 2方向でテンプレートを登録している
- 外接矩形を正方形に引き伸ばす正規化は、高さがほぼゼロの直線でノイズを縦に極端に
  増幅する。縦横比が 0.3 未満のストロークは等方スケールにした（論文が1次元ジェスチャに
  ついて述べている注意点）。これでスコアが 0.77 → 0.99 になった

しきい値 0.88 は実測で決めた。`Tools/rectest.swift` が合成ストロークで検証する:

```
直線     → line       0.99
円       → circle     0.96–0.98
四角     → rectangle  0.94–0.97
三角     → triangle   0.93–0.97
不定形   → (誤判定)    0.81–0.84
なぐり書き → (誤判定)    0.43–0.79
波線     → (誤判定)    0.62–0.65
```

## 配色

スウォッチとアクセントは [Open Color](https://github.com/yeun/open-color)（MIT）。
5つめは色ではなくレーザーポインタで、インクを残さず赤い光点が尾を引いてペンに追従する。
発火条件は描画と同じでペン先の接地。離すと尾が 0.45 秒で消える。

## 調査用ツール

```sh
swiftc -O Tools/hidprobe.swift -o /tmp/hidprobe && /tmp/hidprobe   # 全インターフェースと Report Descriptor
swiftc -O Tools/hiddump.swift  -o /tmp/hiddump  && /tmp/hiddump    # 生レポートを流し見
swiftc -O Tools/hidcap.swift   -o /tmp/hidcap   && /tmp/hidcap 40 range  # レンジとフラグの集計
```

## ドライバを外す方向での残課題

1. `/Applications/HuionTablet.app` を終了した状態で report `0x0A` が流れることの確認
2. カーソル位置のマッピング（現状は OS 任せ。液タブなので通常はこれで正しい）
3. express key（keyboard report `0x03`）の割り当て
4. ベンダーモードへの切り替えを自作する場合は interface #2 の feature report `0x16`（7バイト）が入口
