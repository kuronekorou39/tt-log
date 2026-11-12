# 端末間の通信プロトコル（v1）

スコアボード端末（iPad）とカメラ端末（iPhone、将来は Android）のあいだのやりとり。
実装：`Packages/TTLogCore/Sources/TTLogCore/PeerProtocol.swift`。ここを変えたら両方の実装を直す。

## 接続

- スコアボード端末が **WebSocket サーバー**、カメラ端末がクライアント。
- 待ち受けポートは **52740** 固定。
- スコアボードは Bonjour で `_ttlog._tcp` を公開する。カメラはそれを探してつなぐ。見つからないときは、スコアボードの画面に出る IP アドレスを手入力してつなぐ。
- インターネットは不要。同じ Wi-Fi（テザリングでもよい）にいればつながる。

## メッセージ

WebSocket のテキストメッセージ1つに JSON を1つ入れる。`type` で種類を見分ける。
時刻はすべて **1970年からのミリ秒（数値）**で、送った端末の時計で表す。

### hello（両方向・接続直後）

```json
{"type":"hello","hello":{"role":"camera","deviceName":"iPhone","protocolVersion":1}}
```

`role` は `scoreboard` か `camera`。

### state（スコアボード → カメラ）

状態が変わるたびに、**今の状態を丸ごと**送る。つなぎ直した直後にも1回送る。
カメラは最新の1通だけ見ればよい（途中が抜けても次の1通で追いつく）。

```json
{"type":"state","state":{
  "sessionId":"6F1C…","sessionStartedAt":1762200000000,
  "playerNames":["A","B"],
  "gameIndex":2,"phase":"playing","scores":[5,3],
  "left":1,"server":0,
  "gameStartedAt":1762200900000,"gameEndedAt":null,
  "points":[{"winner":0,"at":1762200915000,"scores":[1,0]}],
  "sentAt":1762201000000
}}
```

| 項目 | 意味 |
|---|---|
| sessionId | 記録の ID。試合をしていないときは null |
| phase | `idle`（試合なし）／`playing`／`gameOver`（次のゲーム待ち）／`matchOver` |
| gameIndex | いまのゲームの番号（0 始まり） |
| scores | いまのゲームの得点（選手の番号順） |
| left | 画面の左側にいる選手の番号 |
| server | いまのサーバー。ゲーム中でなければ null |
| points | いまのゲームの得点の経過（古い順）。`scores` はその点が入った後の得点 |

カメラは **`sessionId` があって `phase` が `playing` のあいだ録画する**（ゲームが終わったら数秒おいて止める）。

### cameraStatus（カメラ → スコアボード）

カメラの録画の状態。2秒ごとに送る。スコアボードはこれを見て「録画中」「録画していません」を出す。

```json
{"type":"cameraStatus","cameraStatus":{"recording":true,"clipSeconds":83.2,"problem":null,"battery":85,"thermal":0,"sentAt":1762201000000}}
```

| 項目 | 意味 |
|---|---|
| recording | ファイルへの書き込みが進んでいるか（録画を頼んだだけでは true にしない） |
| clipSeconds | いまの録画の長さ（秒）。録画していなければ null |
| problem | 録画できていない理由など。なければ null |
| battery | 電池の残り（%）。分からなければ null |
| thermal | 温度の段階。0 正常 / 1 やや高い / 2 高い / 3 危険 |

スコアボードは、8秒届かなければ「カメラの様子が分からない」とみなす。

### ping / pong（時計のずれの測定）

カメラが ping を送り、スコアボードがすぐ pong を返す。

```json
{"type":"ping","sentAt":1762201000000}
{"type":"pong","pingSentAt":1762201000000,"receivedAt":1762201000512}
```

カメラは「ずれ = receivedAt − (送った時刻 + pong を受け取った時刻) / 2」を計算する。
往復が短い測定ほど正確なので、直近の測定のうち往復が最短のものを使う。
スコアボードの時刻（得点の時刻など）は、このずれを引いてカメラの時計に直してから映像と突き合わせる。
