# Kamispec Cloud Functions（Stripe Webhook + プラン管理）

`users/{uid}.plan` を **サーバー（Admin SDK）だけ** が更新できるようにするための
Cloud Functions です。クライアント（アプリ）からは `firestore.rules` で plan の
書き込みを禁止しているので、逆コンパイルしても自分を有料プランにできません。

## 構成
- `stripeWebhook` … Stripe Webhook を受け取り、署名検証 → `users/{uid}.plan` を更新（Windows/Web）
- `createCheckoutSession` … アプリから呼ぶ。Checkout URL を返す（uid を埋め込む）
- `revenuecatWebhook` … RevenueCat Webhook を受け取り、認証 → `users/{uid}.plan` を更新（Android/iOS）

## 前提
- Firebase **Blaze プラン**（従量・要カード）。低トラフィックなら無料枠内でほぼ $0。
- Node.js 20 / Firebase CLI（`npm i -g firebase-tools`）

## セットアップ
```bash
# 1) 依存をインストール
cd functions
npm install

# 2) プロジェクトを選択（.firebaserc は mindmap-b6115 を既定にしてあります）
firebase use mindmap-b6115

# 3) シークレットを登録（Secret Manager に保存。コードには出ません）
firebase functions:secrets:set STRIPE_SECRET_KEY        # sk_test_... / sk_live_...
firebase functions:secrets:set STRIPE_WEBHOOK_SECRET    # 手順5で取得する whsec_...

# 4) Price→plan の対応を index.js の PRICE_TO_PLAN に記入（自分の price_xxx）

# 5) デプロイ
firebase deploy --only functions
#   → stripeWebhook の URL が表示される（例:
#     https://asia-northeast1-mindmap-b6115.cloudfunctions.net/stripeWebhook）

# 6) Stripe ダッシュボード > 開発者 > Webhook で上記 URL を登録し、
#    送信イベント: checkout.session.completed,
#                  customer.subscription.created/updated/deleted
#    登録後に表示される「署名シークレット whsec_...」を手順3の
#    STRIPE_WEBHOOK_SECRET に設定し、再度 deploy。

# 7) ルールもデプロイ（plan ロック）
firebase deploy --only firestore:rules
```

## RevenueCat（Android/iOS）の設定
```bash
# 1) Webhook 認証用の共有秘密を登録（任意の長いランダム文字列）
firebase functions:secrets:set REVENUECAT_WEBHOOK_AUTH

# 2) index.js の RC_ENTITLEMENT_TO_PLAN / RC_PRODUCT_TO_PLAN を自分の設定に編集
#    （RevenueCat の entitlement ID、 またはストアの product ID → 'pro'/'max'）

# 3) デプロイ後、 RevenueCat ダッシュボード > Integrations > Webhooks で
#      URL = revenuecatWebhook の URL（deploy 時に表示）
#      Authorization header value = 手順1で登録したのと同じ文字列
#    を設定。
firebase deploy --only functions
```

**★最重要（uid の紐付け）**：RevenueCat の `app_user_id` を Firebase の uid に
合わせること。アプリで購入の前に `Purchases.logIn(firebaseUid)` を呼ぶ（または
RevenueCat 初期化時に appUserID に Firebase uid を渡す）。これをしないと
`$RCAnonymousID:...` の匿名IDになり、Webhook 側で誰の購入か特定できません
（その場合 plan は更新されず、ログに「uid 特定できず」が出ます）。

対応イベント：INITIAL_PURCHASE / RENEWAL / UNCANCELLATION / NON_RENEWING_PURCHASE /
PRODUCT_CHANGE / SUBSCRIPTION_EXTENDED / TEMPORARY_ENTITLEMENT_GRANT（→有効化）、
CANCELLATION / BILLING_ISSUE / SUBSCRIPTION_PAUSED（→期限まで維持、超過で free）、
EXPIRATION（→free）、TRANSFER（移動先を有効化・移動元を free）、TEST（疎通のみ）。

> 注: 同一ユーザーが Stripe と RevenueCat の両方で課金するケースは稀ですが、
> その場合は「後に届いた Webhook が plan を上書き」します（`planSource` で
> 由来を記録）。実運用で問題になるなら、両ソースを突き合わせる処理を足してください。

## テスト（ローカル）
```bash
# Stripe CLI で Webhook をローカル関数へ転送
stripe listen --forward-to localhost:5001/mindmap-b6115/asia-northeast1/stripeWebhook
firebase emulators:start --only functions,firestore
stripe trigger checkout.session.completed
```

## アプリ側（Dart）からの呼び出し例
```dart
// pubspec に cloud_functions を追加した場合:
final res = await FirebaseFunctions.instanceFor(region: 'asia-northeast1')
    .httpsCallable('createCheckoutSession')
    .call({'priceId': 'price_xxx'});
final url = res.data['url'];
// この url を WebView / 外部ブラウザで開いて決済 → Webhook が plan を更新
// アプリは users/{uid} を購読して plan を読むだけ（書かない）。
```

> ⚠️ このアプリは現在 cloud_functions プラグインを使っていません。callable を使う
> なら `cloud_functions` を pubspec に追加してください。プラグインを増やしたくない
> 場合は `createCheckoutSession` を `onRequest`（HTTP）に変えて、Firebase 匿名認証の
> IDトークンを Authorization ヘッダで送って検証する方式でも実装できます。

## 移行の注意
- ルールを deploy すると、アプリから `users/{uid}.plan` への書き込みは拒否されます。
  現在の端末内プラン判定（`currentPlan`＝prefs基準）には影響しませんが、グループ表示用
  の `users.plan` ミラーは今後この関数が正本として更新します。
- RevenueCat（Android/iOS）も同様に「RevenueCat Webhook → 関数 → users.plan」に
  寄せると一元化できます（このファイルに `revenueCatWebhook` を足す形）。
