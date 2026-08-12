# AI クレジット（前払い）— デプロイ手順

## これは何か

ユーザーが先に $10 を預け、AI を使うたびに「実費 + 20%」が残高から引かれる仕組みです。
残高が尽きたら AI は止まり、都度チャージしてもらいます。

**なぜ前払いか**: 後払いだと、使われてから回収できないリスク（カード拒否・チャージバック）を
こちら側が負います。先に預かっておけば取りっぱぐれがありません。

**なぜ OpenRouter を使わないか**: OpenRouter は経由するだけで 5% 抜かれます。
上乗せが 20% なので、その 4 分の 1 が持っていかれる計算になります。
Gemini / OpenAI / Anthropic の 3 社と直接やり取りすれば、10% がそのまま残ります。

## エンドポイント

| パス | メソッド | 用途 |
|---|---|---|
| `/credits/balance?uid=` | GET | 残高・累計・直近明細 |
| `/credits/checkout` | POST | チャージ用 Stripe Checkout の URL を作る |
| `/ai/models` | GET | 使えるモデルと上乗せ後の単価 |
| `/ai/generate` | POST | 代行実行（残高確認 → 実行 → 差し引き） |
| `/ai/usage?uid=` | GET | 月別の使用量 |
| `/entitlement?uid=` | GET | プラン（従来の月額サブスク用） |
| `/stripe/webhook` | POST | 決済の反映 |
| `/dev/issue` | POST | Dev コードを発行（**ADMIN_UIDS の uid だけ**） |
| `/dev/codes` | GET | 発行済み Dev コード一覧（ADMIN_UIDS のみ） |
| `/dev/revoke` | POST | Dev コードを失効（ADMIN_UIDS のみ） |
| `/dev/redeem` | POST | Dev コードを引き換える（誰でも / 正しいコードのみ） |

## Dev プラン（決済を通さずに AI を使える枠）

引き換えコードを入れた uid の権利情報を `plan: "dev"` にします。`/ai/generate` と
`/ai/image` は Dev の uid では**残高を引きません**（使用量の記録だけ行います）。

**なぜサーバーに要るか**: AI を実際に呼ぶのはこの Worker で、支払いもここで起きます。
アプリ側だけで「自分は Dev だ」と決めても、Worker が知らなければ残高不足で断られるだけです。

**発行できるのは誰か**: シークレット `ADMIN_UIDS` に載せた uid だけ。
アプリの開発者モード（パスワード）は画面の入口に過ぎず、本当の防壁はこの uid 照合です。
そのため、Dev プランの利用者がアプリを改造しても新しいコードは発行できません。

```bash
# 自分の uid を登録する（「,」区切りで複数可）
# uid はアプリの 開発者モード → クーポン管理 の画面に表示されます（押すとコピー）
wrangler secret put ADMIN_UIDS
```

暴走対策として、Dev でも月上限は残してあります（`DEV_MONTHLY_CAP_USD` = 200 ドル）。

## 画像の入力（カメラで撮った写真を AI に渡す）

`/ai/generate` の本文に `images: [{ "mime": "image/jpeg", "data": "<base64>" }]` を
足せます。Gemini / OpenAI / Anthropic それぞれの形式に変換して渡します。
合計 6MB・4 枚までで、超えると 413 を返します。入力トークンとして課金されるので、
残高の事前確保では 1 枚あたり 1600 トークンを見積もっています。

## 必要なシークレット / 環境変数

```bash
# AI 各社のキー（Worker のみが持つ。アプリには絶対に入れない）
wrangler secret put GEMINI_API_KEY
wrangler secret put OPENAI_API_KEY
wrangler secret put ANTHROPIC_API_KEY

# Stripe
wrangler secret put STRIPE_SECRET_KEY
wrangler secret put STRIPE_WEBHOOK_SECRET

# 決済後の戻り先（任意。未設定なら https://hisator-notebook.com/thanks）
# wrangler.toml の [vars] に書く
CREDIT_RETURN_URL = "https://hisator-notebook.com/thanks"
```

KV バインディング名は `ENTITLEMENTS`（既存のものをそのまま使います）。

## Stripe 側の設定

1. **Webhook を登録**: エンドポイント `https://api.hisator-notebook.com/stripe/webhook`、
   イベントは最低限 `checkout.session.completed`。署名シークレットを
   `STRIPE_WEBHOOK_SECRET` に入れます。
2. 商品や価格の事前登録は**不要**です。チャージは `price_data` でその場で金額を作るので、
   $10 / $20 / … と個数を変えても Stripe 側の設定変更は要りません。

## 調整できる値（`billing-worker.js` の先頭付近）

| 定数 | 既定 | 意味 |
|---|---|---|
| `MARKUP` | `0.20` | 上乗せ率。0.1 にすれば 1 割 |
| `CREDIT_PACK_USD` | `10` | 1 回のチャージ額（＝最低額） |
| `CREDIT_LOW_USD` | `1.0` | これを下回るとアプリが「そろそろチャージ」と案内 |
| `MONTHLY_HARD_CAP_USD` | `50` | 月あたりの上限。残高があってもここで止まる |
| `DEV_MONTHLY_CAP_USD` | `200` | Dev 枠の月上限（引き落とさない分、広めだが必ず置く） |
| `MAX_INPUT_IMAGE_BYTES` | `6MB` | 1 回に渡せる画像の合計サイズ |
| `AI_MODELS` | — | モデルと原価。**各社が値上げしたら手で直す必要があります** |

アプリ側の `kUsageMarkupRate`（`mind_map_provider.dart`）も同じ値に合わせてください。
表示用なので実際の請求はサーバー側の `MARKUP` が正です。

## 残っている注意点

- **同時実行での二重引き落とし**: Durable Object `CreditAccount` に移行済みです。
  `/reserve` で先に最大額を確保してから上流を呼ぶので、同時に何本来ても
  残高を超えて使われることはありません。
- **返金**: 使用済みのトークン代は戻らないので、残高の払い戻しには応じない旨を
  利用規約に書いてください。
- **各社の値上げ**: `AI_MODELS` の単価は直書きです。値上げされたら直すまで逆ざやになります。

## デプロイ

```bash
cd worker
wrangler deploy billing-worker.js
```

`wrangler.toml` は用意済みです（`workers_dev = false` と
`[[routes]] custom_domain = true` の両方が必要。詳細はファイル内のコメント参照）。
