# HisatorNotebook 実装詳細 (1) 決済・サブスクリプション・AI クレジット

## 対象ファイル

| ファイル | 役割 |
|---|---|
| `lib/services/billing_service.dart` | アプリ側の課金抽象 |
| `lib/providers/mind_map_provider.dart` | プラン解決・クレジット・代行呼び出し |
| `worker/billing-worker.js` | Cloudflare Worker (決済の正) |
| `worker/wrangler.toml` | KV / Durable Object の結び付け |

## 大前提

- アプリは「支払われたかどうか」を**自分で判断しない**。クライアント判定にすると、
  決済ページから戻っただけで Pro になれてしまう。
- 判定の正は必ず **Stripe → Worker(KV) → アプリ** の順で流れる。
- 本物の API キー (Stripe secret / Gemini / OpenAI / Anthropic) は
  **Worker のシークレットにだけ**置く。アプリには絶対に埋めない。

---

## 【1】プラットフォームによる決済経路の分岐

```mermaid
flowchart TD
    A["アプリ起動<br/>MindMapProvider が BillingService を生成"] --> B["BillingService.configure(appUserId: Firebase UID)"]
    B --> C{"isNativeBilling?<br/>(Android / iOS / macOS)"}
    C -->|true| D["RevenueCat SDK を使う経路 (【2】)"]
    C -->|false| E["Windows / Linux<br/>SDK 非対応なので configure は即 return"]
    E --> F["Stripe Payment Link + Worker 照会 (【3】)"]
```

> ※ release ビルドで `apiKeyMobile` が `test_` で始まる場合は configure を中止する。
> RevenueCat の Test Store キーは release で使えず、SDK が「Wrong API Key」ダイアログを
> 出してアプリを落とすため。

---

## 【2】Android の購入フロー (RevenueCat SDK)

```mermaid
flowchart TD
    A["Purchases.setLogLevel(warn)<br/>PurchasesConfiguration(apiKey)..appUserID = UID"] --> B["Purchases.configure()<br/>_configured = true"]
    B --> C["addCustomerInfoUpdateListener を登録<br/>(更新・解約・期限切れを SDK が push)"]
    C --> D["起動時に getCustomerInfo() を 1 回"]
    D --> E["_planFromCustomerInfo(info)<br/>entitlements.active に max → max / pro → pro / 無し → free"]
    E --> F["onPlanChanged?.call(planName)<br/>← 文字列だけ返す (provider を import しない)"]
    F --> G["applyBillingPlanByName(name)<br/>→ enum 変換 + 保存 + notifyListeners()"]
```

### 購入ボタンを押した時

```mermaid
flowchart TD
    A["fetchPackages()"] --> B["Purchases.getOfferings()<br/>current → 'default' → 先頭 の順にフォールバック"]
    B --> C["package identifier から解釈<br/>planName: max で始まれば max、他は pro<br/>isYearly: year / annual を含むか<br/>priceString: ローカライズ済み価格"]
    C --> D["UI が一覧を並べる"]
    D --> E["purchasePackage(pkg)"]
    E --> F["_googleOldProductIdentifierFor(pkg)<br/>= 今契約中の product id を調べる"]
    F --> G{"旧 id がある?"}
    G -->|無し| H["Purchases.purchasePackage(pkg.raw)"]
    G -->|有り| I["GoogleProductChangeInfo(旧id,<br/>prorationMode: immediateWithTimeProration) 付き"]
    H --> J["戻り値は SDK 版で型が違うので使わず<br/>getCustomerInfo() で取り直す"]
    I --> J
    J --> K["_planFromCustomerInfo → onPlanChanged"]
```

> 乗り換え (Pro 月額 → Max 月額) で旧 id を渡さないと、Play が「別サブスクの新規購入」
> 扱いにして切替ダイアログに進めない。

ユーザーがキャンセルした場合は `PlatformException.code == purchaseCancelledError` を
`BillingCancelledException` に変換して投げる (UI 側は握りつぶして静かに閉じるだけでよい)。

**復元**: `restore()` → `Purchases.restorePurchases()` → `_planFromCustomerInfo` → `onPlanChanged`

---

## 【3】Windows / Linux の購入フロー (Stripe Payment Link)

```mermaid
flowchart TD
    A["ユーザーが「Pro 月額」等を押す"] --> B["openStripeCheckout(planName, yearly, appUserId)"]
    B --> C["stripeLinkFor(plan, yearly) で 4 本から 1 本選ぶ<br/>(ProMonthly / ProYearly / MaxMonthly / MaxYearly。env.json 由来)"]
    C --> D["URL 末尾に ?client_reference_id=Firebase UID<br/>← 「誰が買ったか」の唯一の紐付け"]
    D --> E["launchUrl(externalApplication) で既定ブラウザを開く"]
    E --> F["ここでアプリの手を離れる<br/>以降は Stripe → Worker の世界"]
    F --> G["ユーザーが決済完了"]
    G --> H["Stripe が Worker の /stripe/webhook を叩く (【4】)"]
    H --> I["アプリに戻ったら fetchPlanViaEntitlementApi(uid) で照会 (【5】)"]
```

> ※ 画面に出す金額は `BillingService` の定数
> (`proMonthlyUsd` / `proYearlyPerMonthUsd` / `maxMonthlyUsd` / `maxYearlyPerMonthUsd`)。
> **Stripe 側で価格を変えたらここも必ず直す** (画面と決済ページの数字がずれる)。
> 年額は「1 か月あたり」の額。`yearlyTotalUsd()` が 12 倍、
> `yearlyDiscountPercent()` が割引率 (四捨五入) を出す。

---

## 【4】Stripe Webhook の受け口 (Worker `/stripe/webhook`)

```mermaid
flowchart TD
    A["POST /stripe/webhook"] --> B["本文を text で読む<br/>(署名検証は生バイト列に対して行うので先に JSON にしない)"]
    B --> C["verifyStripeSignature(payload, Stripe-Signature, SECRET)"]
    C --> C1["ヘッダを t=…,v1=… に分解"]
    C1 --> C2{"now - t > 300 秒?"}
    C2 -->|はい| X["リプレイとみなし拒否"]
    C2 -->|いいえ| C3["HMAC-SHA256('t.payload', secret) を 16 進に"]
    C3 --> C4["v1 と定数時間比較<br/>(1 文字ずつ XOR して OR。タイミング攻撃対策)"]
    C4 -->|不一致| Y["400 bad signature"]
    C4 -->|一致| D["JSON.parse して event.type で分岐"]
    D --> E["checkout.session.completed"]
    D --> F["customer.subscription.created / updated"]
    D --> G["customer.subscription.deleted"]
```

### checkout.session.completed

```mermaid
flowchart TD
    A["uid = session.client_reference_id"] --> B{"metadata.kind === 'credit'?"}
    B -->|"YES (チャージ)"| C{"KV に credit_evt:session.id がある?"}
    C -->|"ある (処理済み)"| C1["何もしない (二重計上防止)"]
    C -->|無い| C2["usd = amount_total / 100"]
    C2 --> C3["addCredit(uid, usd, note, eventId) で残高に加算"]
    C3 --> C4["credit_evt:id に印 (TTL 90 日)"]
    B -->|"NO (サブスク購入)"| D["plan を上から順に決める"]
    D --> D1["1. session.metadata.plan"]
    D1 --> D2["2. planFromLink(payment_link, env.PLAN_MAP)<br/>PLAN_MAP = {'plink_xxx':'pro'}"]
    D2 --> D3["3. planFromSession()<br/>line_items → price.metadata.plan → products.metadata.plan"]
    D3 --> E["putEntitlement(uid, {plan, status:'active',<br/>subscriptionId, customerId, currentPeriodEnd:null})"]
    E --> F["サブスクにも metadata[uid] / metadata[plan] を書き戻す"]
    F --> G["KV に sub:subscriptionId = uid<br/>(更新・解約イベントで逆引きするため)"]
```

### customer.subscription.created / updated / deleted

| イベント | 処理 |
|---|---|
| created / updated | `uid = sub.metadata.uid` (無ければ KV の `sub:<id>`) → status が `active`/`trialing`/`past_due` なら有効 → `putEntitlement(uid, {plan: 有効なら metadata.plan (既定 pro) / 無効なら 'free', status, subscriptionId, customerId, currentPeriodEnd: subPeriodEnd(sub)})` |
| deleted | 同じく uid を引き、`plan:'free'` / `status:'canceled'` を書く |

> - 例外が出ても catch してログするだけ。**必ず 200 `{received:true}` を返す**
>   (200 を返さないと Stripe が延々と再送してくる)。
> - `subPeriodEnd(sub)` は `current_period_end` を ① sub 直下 → ② `items.data[].current_period_end`
>   の順に探す (Stripe が API 更新で items の下へ移したため両対応)。
>   ここが取れないと期限切れ判定が働かず、支払いが止まっても権利が残る。

---

## 【5】アプリがプランを知る (Worker `/entitlement`)

```mermaid
flowchart TD
    A["fetchPlanViaEntitlementApi(appUserId)"] --> B["GET /entitlement?uid=uid (timeout 12 秒)"]
    B --> C["Worker: KV から uid のレコードを読む"]
    C --> C1["無い / 壊れている → {plan:'free'}"]
    C --> C2["currentPeriodEnd + 3 日 < 今 → plan 'free' / status 'expired'<br/>(3 日の猶予は決済の遅延・再試行を吸収)"]
    C --> C3["plan が 'dev' で devExpiresAt 超過 → 'free'"]
    C1 --> D{"アプリ: HTTP 200?"}
    C2 --> D
    C3 --> D
    D -->|"200 以外"| E["null を返す<br/>★ null は「判定できなかった」であって free ではない"]
    D -->|200| F["'dev'/'max'/'pro' 以外は 'free' に正規化"]
    F --> G["applyBillingPlanByName() → currentPlan 更新"]
    E --> H["呼び出し側は今の状態を一切変えない"]
```

> ★ 圏外やサーバー障害を free と解釈すると、通信に失敗しただけで有料ユーザーが
> 解約扱いになる。だから `null` と `free` を厳密に区別する。

> ※ 旧経路として RevenueCat REST `/v1/subscribers/{id}` を読む `fetchPlanViaRest()` も残る
> (public key で読める)。`entitlements[key].expires_date` を今と比べて有効判定し、max > pro の順。
> `pollPlanAfterWebPurchase()` は 5 秒間隔で最大 6 回叩き、決済 → 反映のタイムラグを吸収する。

---

## 【6】アプリの中で契約を見る・解約する

```mermaid
flowchart TD
    A["「サブスク解約」を開く"] --> B["GET /billing/subscription<br/>Authorization: Bearer Firebase ID トークン"]
    B --> C{"authUid で本人確認 (【8】)"}
    C -->|失敗| C1["401"]
    C -->|成功| D["readEntitlement(uid)"]
    D --> E{"ent.store === 'play'?"}
    E -->|はい| F["{store:'play', subscription:null}<br/>→ アプリは「ストアの管理画面へ」と案内<br/>openManagementPage() が RevenueCat の managementURL<br/>(無ければ Play の定期購入一覧) を開く"]
    E -->|"いいえ (Stripe)"| G["findSubscription(env, ent)"]
    G --> G1["① ent.subscriptionId があれば subscriptions/id を直接取得"]
    G --> G2["② 無ければ customerId から subscriptions?status=all&limit=10<br/>active/trialing/past_due/unpaid を優先、無ければ最新 1 件"]
    G1 --> H["normalizeSubscription() で整形<br/>{id, status, cancelAtPeriodEnd, currentPeriodEnd, canceledAt,<br/>amount, currency, interval, intervalCount, planName}"]
    G2 --> H
    H --> I["アプリが契約内容 (金額・周期・次回更新日) を表示"]
```

### 解約ボタン

```mermaid
flowchart TD
    A["POST /billing/cancel (Bearer)"] --> B["authUid → readEntitlement"]
    B --> C{"store === 'play'?"}
    C -->|はい| C1["409 managed by store"]
    C -->|いいえ| D["findSubscription で対象を特定"]
    D -->|無し| D1["404"]
    D --> E["Stripe: subscriptions/id に<br/>cancel_at_period_end=true を PATCH"]
    E --> F["KV の権利情報にも status / currentPeriodEnd /<br/>cancelAtPeriodEnd を書き戻す"]
    F --> G["整形した subscription を返す<br/>→ アプリが「◯月◯日まで利用できます」と表示"]
```

> ★ **即時解約にはしない**。支払い済みの期間は使えた方が親切で、返金の問い合わせも減る。
> ※ `/billing/resume` は同じ関数を `cancel=false` で呼び、解約予約を取り消す。

---

## 【7】前払い AI クレジット (チャージ)

**なぜ前払いか**: 後払いだとカード拒否・チャージバックの回収リスクをこちらが負う。
先に預かれば取りっぱぐれない。

```mermaid
flowchart TD
    A["アプリ「チャージ」ボタン (packs = 10 ドル単位)"] --> B["createCreditCheckoutUrl(packs)"]
    B --> C["POST /credits/checkout (Bearer + {uid, packs})"]
    C --> D["Worker: authUid → packs を 1〜20 に丸める<br/>amountUsd = 10 × packs"]
    D --> E["Stripe: checkout/sessions を作成<br/>mode=payment (都度払い)<br/>client_reference_id = uid<br/>metadata[kind] = 'credit' ← webhook が残高加算に回す<br/>unit_amount = amountUsd × 100"]
    E --> F["KV に credit_pending:uid = session.id (TTL 24h)<br/>← webhook 不達でも回収できる保険"]
    F --> G["session.url をアプリへ返す"]
    G --> H["外部ブラウザでその URL を開く<br/>(アプリ内に決済画面は出さない)"]
    H --> I["決済完了 → webhook が kind=credit を受けて加算 (【4】)"]
```

### webhook が来なかった場合の保険

```mermaid
flowchart TD
    A["アプリが残高を読む: GET /credits/balance"] --> B["settlePendingCheckout(uid) を先に走らせる"]
    B --> C["KV の credit_pending:uid を読む"]
    C --> D["Stripe に checkout/sessions/id を照会"]
    D --> E{"payment_status === 'paid'<br/>かつ credit_evt:id 未処理?"}
    E -->|はい| F["addCredit"]
    E -->|"status === 'expired'"| G["credit_pending を消す"]
    F --> H["readCredit(uid)<br/>残高・累計チャージ・累計使用・直近 20 件の明細"]
    G --> H
    H --> I["provider._creditBalanceUsd 等に反映 → notifyListeners()"]
```

---

## 【8】本人確認 (Firebase ID トークンの検証)

以前は本文の uid をそのまま信じていたため、**uid を知る者なら誰でも他人の残高を使えた**。
今は必ずトークンから uid を取り出す。

```mermaid
flowchart TD
    A["provider._ensureFreshToken() で ID トークンを更新"] --> B["Authorization: Bearer JWT を付ける (_relayHeaders)"]
    B --> C["Worker authUid(request) → verifyFirebaseIdToken(token)"]
    C --> D["① JWT を . で 3 分割<br/>header.alg === 'RS256' かつ kid がある事を確認"]
    D --> E["② payload を検査<br/>aud === FIREBASE_PROJECT_ID<br/>iss === https://securetoken.google.com/projectId<br/>sub が存在<br/>exp が (今 - 60 秒) より後"]
    E --> F["③ Google の JWKS を取得<br/>(1 時間メモリキャッシュ _jwksCache / _jwksAt)"]
    F --> G["④ header.kid に一致する鍵を crypto.subtle.importKey"]
    G --> H["⑤ crypto.subtle.verify(RSASSA-PKCS1-v1_5, header.payload, signature)"]
    H -->|通る| I["payload.sub を uid として返す"]
    H -->|だめ| J["null → 401 unauthorized"]
```

> ★ これにより、アプリを改造して他人の uid を送っても通らない。

---

## 【9】AI 代行実行と課金 (Worker `/ai/generate`)

```mermaid
flowchart TD
    A["provider.askAi(prompt)"] --> B{"canUseAiRelay?<br/>relayApiBase 設定済 && _relayAvailable &&<br/>(残高 > 0 || Dev プラン)"}
    B -->|満たさない| B1["t('relay.notConfigured') /<br/>t('credit.insufficient') を投げる"]
    B -->|満たす| C["POST /ai/generate (Bearer)<br/>body: {uid, prompt: languageInstructionForAi() + prompt,<br/>model, maxTokens?, images?}"]
    C --> D["Worker: authUid (【8】) → 401 なら終わり"]
    D --> E["model を検証 (無ければ DEFAULT_MODEL='gemini-flash-latest')<br/>maxTokens を 256〜32000 に丸める"]
    E --> F["sanitizeInputImages(body.images)<br/>最大 4 枚 / 許可 MIME 以外は jpeg 扱い<br/>合計 6MB 超は null → 413"]
    F --> G["livePrices(env) で単価表<br/>KV の model_prices_v1 が 12h 以内ならそれ<br/>古ければ OpenRouter /api/v1/models から作り直し (KV に 24h)"]
    G --> H["findLivePrice → 無ければ priceFor(model)"]
    H --> I{"providerKey(env, provider) がある?"}
    I -->|無い| I1["503"]
    I -->|ある| J["isDevEntitlement(readEntitlement(uid))"]
    J --> K["worstCase を計算<br/>imageTokens = 枚数 × 1600<br/>((promptLen/3.5 + imageTokens)/1e6 × 入力単価<br/>+ maxTokens/1e6 × 出力単価) × (1 + MARKUP)<br/>MARKUP = 0.20 (原価 + 2 割)"]
    K --> L{"Dev 枠?"}
    L -->|いいえ| M["CreditAccount(Durable Object) に /reserve で worstCase を確保"]
    M -->|残高不足| M1["402 {error:'insufficient credit',<br/>balanceUsd, neededUsd, packUsd}"]
    M -->|確保成功| N["reserved = worstCase"]
    L -->|はい| N2["確保しない"]
    N --> O{"月上限<br/>usage:uid:YYYY-MM の billedUsd<br/>通常 50 USD / Dev 200 USD"}
    N2 --> O
    O -->|超過| O1["429"]
    O -->|以内| P["callProvider(env, model, prompt, maxTokens, images) (【10】)"]
    P -->|失敗| Q["/settle {hold: reserved, actual: 0} で全額返す<br/>→ 502 (or 上流のステータス)"]
    P -->|成功| R["cost = inTok/1e6×入力 + outTok/1e6×出力<br/>billed = cost × (1 + MARKUP)"]
    R --> S{"Dev 枠?"}
    S -->|はい| S1["引き落とさない (使用量の記録だけ)"]
    S -->|いいえ| S2["/settle {hold: reserved, actual: billed}<br/>(確保分を戻して実費だけ引く = 精算)"]
    S1 --> T["usage:uid:ym に inputTokens / outputTokens /<br/>costUsd / billedUsd を加算"]
    S2 --> T
    T --> U["{text, model, provider, usage,<br/>credit:{balanceUsd, low, packUsd}, monthly} を返す"]
```

> ★ **先に確保するのが肝**。同時に何本来ても Durable Object の中で順番に処理されるので、
> 残高以上には絶対に使えない (以前は事前チェックのみで、同時リクエストが全部素通りし得た)。
> ★ 返答言語の指定を prompt の先頭に付ける。代行経路だけこれが抜けていたため、
> 日本語設定でも英語で返ってきていた (既定経路なのでほぼ全員が該当)。

### アプリ側のエラー処理

| ステータス | 処理 |
|---|---|
| 402 | 残高を反映して `t('credit.insufficient')` を投げる (画面がチャージを促す) |
| 429 | `t('relay.capReached')` |
| 413 | `t('ai.imageTooLarge')` |
| 404 | `_relayAvailable = false` にして以後この経路を使わない |
| 200 | credit / monthly / usage を取り込み、`recordAppKeyUsage` でローカルの累計トークン表示にも足す |
