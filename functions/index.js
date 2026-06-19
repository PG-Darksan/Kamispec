/**
 * Kamispec / MokuMoku — Cloud Functions (2nd gen)
 * ───────────────────────────────────────────────────────────────────────
 * 役割:
 *   1) stripeWebhook        : Stripe の Webhook を受け取り、 署名を検証して
 *                             Firestore の users/{uid}.plan を「サーバーが」
 *                             更新する (= 逆コンパイルしても改ざんできない正本)。
 *   2) createCheckoutSession: アプリから呼ばれ、 Stripe Checkout セッションを
 *                             サーバー側 (シークレットキー) で作成して URL を返す。
 *                             client_reference_id / metadata に Firebase uid を
 *                             仕込むので、 Webhook 側で uid を特定できる。
 *
 * シークレット (Secret Manager に保存。 コードにもアプリにも置かない):
 *   STRIPE_SECRET_KEY      … Stripe の sk_live_... / sk_test_...
 *   STRIPE_WEBHOOK_SECRET  … Stripe ダッシュボードの Webhook 署名シークレット whsec_...
 *
 * セットアップ手順は同フォルダ末尾のコメント、 または README 参照。
 */

const {onRequest, onCall, HttpsError} = require("firebase-functions/v2/https");
const {defineSecret} = require("firebase-functions/params");
const {setGlobalOptions} = require("firebase-functions/v2");
const logger = require("firebase-functions/logger");
const admin = require("firebase-admin");
const Stripe = require("stripe");
const crypto = require("crypto");

admin.initializeApp();

// リージョンは日本に近い東京。 必要に応じて変更。
setGlobalOptions({region: "asia-northeast1", maxInstances: 10});

const STRIPE_SECRET_KEY = defineSecret("STRIPE_SECRET_KEY");
const STRIPE_WEBHOOK_SECRET = defineSecret("STRIPE_WEBHOOK_SECRET");

// RevenueCat の Webhook は HMAC 署名ではなく「Authorization ヘッダの共有秘密」
//   で検証する。 RevenueCat ダッシュボード > Integrations > Webhooks の
//   Authorization header value に設定した文字列と同じものをここに登録する。
const REVENUECAT_WEBHOOK_AUTH = defineSecret("REVENUECAT_WEBHOOK_AUTH");

// ── RevenueCat の Entitlement / Product → プラン名 の対応 ──
//   どちらか分かる方で判定 (entitlement を優先)。 自分の設定に合わせて編集。
//   ★ entitlement ID は RevenueCat の Entitlements 画面、 product ID は
//     ストアの購入ID (例: kamispec_pro_monthly)。
const RC_ENTITLEMENT_TO_PLAN = {
  // "pro": "pro",
  // "max": "max",
};
const RC_PRODUCT_TO_PLAN = {
  // "kamispec_pro_monthly": "pro",
  // "kamispec_pro_yearly":  "pro",
  // "kamispec_max_monthly": "max",
  // "kamispec_max_yearly":  "max",
};

// ── Stripe の Price ID → プラン名 の対応表 ──
//   Stripe ダッシュボードの「商品 > 価格」 にある price_xxx をここに書く。
//   月額/年額で price が分かれる場合は両方を同じ plan に向ける。
//   ★必ず自分の price ID に書き換えてください。
const PRICE_TO_PLAN = {
  // "price_xxxxxxxxxxxxProMonthly": "pro",
  // "price_xxxxxxxxxxxxProYearly":  "pro",
  // "price_xxxxxxxxxxxxMaxMonthly": "max",
  // "price_xxxxxxxxxxxxMaxYearly":  "max",
};

// 支払い完了後 / キャンセル時にブラウザを戻す先 (表示用のページ)。
const SUCCESS_URL = "https://kamispec.com/checkout/success";
const CANCEL_URL = "https://kamispec.com/checkout/cancel";

// ════════════════════════════════════════════════════════════════════════
//  1) Stripe Webhook
// ════════════════════════════════════════════════════════════════════════
exports.stripeWebhook = onRequest(
    {secrets: [STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET]},
    async (req, res) => {
      const stripe = new Stripe(STRIPE_SECRET_KEY.value());

      // ── 署名検証 ──
      // ★ req.rawBody (生のバイト列) を使うこと。 JSON.parse 済みだと検証に失敗する。
      //   Firebase Functions は rawBody を自動で用意してくれる。
      const sig = req.headers["stripe-signature"];
      let event;
      try {
        event = stripe.webhooks.constructEvent(
            req.rawBody, sig, STRIPE_WEBHOOK_SECRET.value());
      } catch (err) {
        logger.error("Webhook 署名検証に失敗", err.message);
        res.status(400).send(`Webhook Error: ${err.message}`);
        return;
      }

      try {
        switch (event.type) {
          // 支払い完了 (サブスク開始)
          case "checkout.session.completed": {
            const session = event.data.object;
            const uid = session.client_reference_id ||
              (session.metadata && session.metadata.firebaseUid);
            if (!uid) {
              logger.warn("checkout.session.completed: uid 不明", session.id);
              break;
            }
            let plan = "pro";
            let status = "active";
            let expiresAt = null;
            let customerId = session.customer || null;
            let subId = session.subscription || null;
            if (subId) {
              const sub = await stripe.subscriptions.retrieve(subId);
              plan = planFromSubscription(sub);
              status = sub.status;
              expiresAt = periodEndMs(sub);
              customerId = sub.customer || customerId;
            }
            await setUserPlan(uid, {plan, status, expiresAt, customerId,
              subId});
            break;
          }

          // サブスクの作成/更新 (プラン変更・更新・支払い遅延など)
          case "customer.subscription.created":
          case "customer.subscription.updated": {
            const sub = event.data.object;
            const uid = await uidForSubscription(sub);
            if (!uid) {
              logger.warn("subscription.updated: uid 特定できず", sub.id);
              break;
            }
            const active = ["active", "trialing", "past_due"]
                .includes(sub.status);
            await setUserPlan(uid, {
              plan: active ? planFromSubscription(sub) : "free",
              status: sub.status,
              expiresAt: periodEndMs(sub),
              customerId: sub.customer,
              subId: sub.id,
            });
            break;
          }

          // サブスク解約
          case "customer.subscription.deleted": {
            const sub = event.data.object;
            const uid = await uidForSubscription(sub);
            if (!uid) break;
            await setUserPlan(uid, {
              plan: "free",
              status: "canceled",
              expiresAt: periodEndMs(sub),
              customerId: sub.customer,
              subId: sub.id,
            });
            break;
          }

          default:
            // 必要になったら他イベントを追加 (invoice.payment_failed など)。
            logger.debug("未処理の event", event.type);
        }
        res.status(200).json({received: true});
      } catch (err) {
        logger.error("Webhook 処理中にエラー", err);
        // 5xx を返すと Stripe が自動リトライしてくれる。
        res.status(500).send("internal error");
      }
    });

// ════════════════════════════════════════════════════════════════════════
//  2) Checkout セッション作成 (アプリから呼ぶ)
// ════════════════════════════════════════════════════════════════════════
//   アプリ側 (Dart) からの呼び出し例:
//     final res = await FirebaseFunctions.instanceFor(region: 'asia-northeast1')
//         .httpsCallable('createCheckoutSession')
//         .call({'priceId': 'price_xxx'});
//     final url = res.data['url'];  // この URL を WebView / ブラウザで開く
exports.createCheckoutSession = onCall(
    {secrets: [STRIPE_SECRET_KEY]},
    async (request) => {
      if (!request.auth) {
        throw new HttpsError("unauthenticated", "サインインが必要です");
      }
      const uid = request.auth.uid;
      const priceId = request.data && request.data.priceId;
      if (!priceId) {
        throw new HttpsError("invalid-argument", "priceId が必要です");
      }
      const stripe = new Stripe(STRIPE_SECRET_KEY.value());

      // 既存の Stripe 顧客があれば再利用 (重複顧客を防ぐ)。
      let customerId = null;
      try {
        const snap = await admin.firestore()
            .collection("users").doc(uid).get();
        customerId = snap.exists ? (snap.get("stripeCustomerId") || null) : null;
      } catch (_) { /* 読めなくても続行 */ }

      const session = await stripe.checkout.sessions.create({
        mode: "subscription",
        line_items: [{price: priceId, quantity: 1}],
        // ★ uid を仕込むのが要。 Webhook 側でこれを読んで誰の購入か特定する。
        client_reference_id: uid,
        metadata: {firebaseUid: uid},
        subscription_data: {metadata: {firebaseUid: uid}},
        customer: customerId || undefined,
        success_url: SUCCESS_URL,
        cancel_url: CANCEL_URL,
        allow_promotion_codes: true,
      });
      return {url: session.url, sessionId: session.id};
    });

// ════════════════════════════════════════════════════════════════════════
//  3) RevenueCat Webhook (Android / iOS のサブスクを plan に反映)
// ════════════════════════════════════════════════════════════════════════
//   RevenueCat ダッシュボード > Integrations > Webhooks で
//     URL  = この関数の URL
//     Authorization header value = 任意の長い秘密文字列
//   を設定し、 同じ値を シークレット REVENUECAT_WEBHOOK_AUTH に登録する。
//
//   ★ 前提: app_user_id が Firebase uid であること。 アプリ側で購入前に
//     `Purchases.logIn(firebaseUid)` を呼ぶか、 RevenueCat 設定時に
//     appUserID を Firebase uid にする。 そうしないと匿名IDになり uid を
//     特定できない (その場合はここで弾いてログだけ残す)。
exports.revenuecatWebhook = onRequest(
    {secrets: [REVENUECAT_WEBHOOK_AUTH]},
    async (req, res) => {
      // ── 認証 (Authorization ヘッダの共有秘密) ──
      const expected = REVENUECAT_WEBHOOK_AUTH.value();
      const got = req.headers["authorization"] || "";
      if (!expected || !safeEqual(got, expected)) {
        logger.warn("RevenueCat webhook: 認証失敗");
        res.status(401).send("unauthorized");
        return;
      }
      const event = req.body && req.body.event;
      if (!event || !event.type) {
        res.status(400).send("bad payload");
        return;
      }
      try {
        // TEST イベントは疎通確認用。 200 を返すだけ。
        if (event.type === "TEST") {
          logger.info("RevenueCat TEST event 受信");
          res.status(200).json({received: true});
          return;
        }

        const now = Date.now();
        const expiresAt = typeof event.expiration_at_ms === "number" ?
          event.expiration_at_ms : null;
        const store = event.store || "unknown";

        // TRANSFER: 別の app_user_id へサブスクが移動した。
        //   移動先を有効化し、 移動元を free にする。
        if (event.type === "TRANSFER") {
          const plan = planFromRcEvent(event);
          for (const to of (event.transferred_to || [])) {
            if (isRealUid(to)) {
              await setUserPlanRC(to, {plan, status: "active", expiresAt,
                store, appUserId: to});
            }
          }
          for (const from of (event.transferred_from || [])) {
            if (isRealUid(from)) {
              await setUserPlanRC(from, {plan: "free", status: "transferred",
                expiresAt: null, store, appUserId: from});
            }
          }
          res.status(200).json({received: true});
          return;
        }

        const uid = uidFromRcEvent(event);
        if (!uid) {
          logger.warn("RevenueCat webhook: uid 特定できず (匿名IDの可能性)",
              event.app_user_id);
          // 200 を返さないと RevenueCat がリトライし続けるので 200 で受ける。
          res.status(200).json({received: true, skipped: "no-uid"});
          return;
        }

        let plan;
        let status;
        switch (event.type) {
          // 有効化/継続するイベント
          case "INITIAL_PURCHASE":
          case "RENEWAL":
          case "UNCANCELLATION":
          case "NON_RENEWING_PURCHASE":
          case "PRODUCT_CHANGE":
          case "SUBSCRIPTION_EXTENDED":
          case "TEMPORARY_ENTITLEMENT_GRANT":
            plan = planFromRcEvent(event);
            status = "active";
            break;

          // 解約予約 / 支払い問題 / 一時停止: 期限までは有効。
          //   期限切れなら free、 未来なら現プランを維持。
          case "CANCELLATION":
          case "BILLING_ISSUE":
          case "SUBSCRIPTION_PAUSED":
            if (expiresAt != null && expiresAt > now) {
              plan = planFromRcEvent(event);
              status = event.type === "CANCELLATION" ? "canceled" :
                event.type === "BILLING_ISSUE" ? "billing_issue" : "paused";
            } else {
              plan = "free";
              status = "expired";
            }
            break;

          // 失効
          case "EXPIRATION":
            plan = "free";
            status = "expired";
            break;

          default:
            logger.debug("RevenueCat 未処理 event", event.type);
            res.status(200).json({received: true, skipped: event.type});
            return;
        }

        await setUserPlanRC(uid, {plan, status, expiresAt, store,
          appUserId: event.app_user_id || uid});
        res.status(200).json({received: true});
      } catch (err) {
        logger.error("RevenueCat webhook 処理エラー", err);
        res.status(500).send("internal error");
      }
    });

// ════════════════════════════════════════════════════════════════════════
//  ヘルパー
// ════════════════════════════════════════════════════════════════════════

function planFromSubscription(sub) {
  const item = sub.items && sub.items.data && sub.items.data[0];
  const priceId = item && item.price && item.price.id;
  return PRICE_TO_PLAN[priceId] || "pro";
}

function periodEndMs(sub) {
  return sub.current_period_end ? sub.current_period_end * 1000 : null;
}

// サブスクイベントから Firebase uid を特定する。
//   1) metadata.firebaseUid (createCheckoutSession で仕込んだもの)
//   2) stripeCustomerId で users を逆引き
async function uidForSubscription(sub) {
  if (sub.metadata && sub.metadata.firebaseUid) {
    return sub.metadata.firebaseUid;
  }
  const customerId = sub.customer;
  if (!customerId) return null;
  const snap = await admin.firestore()
      .collection("users")
      .where("stripeCustomerId", "==", customerId)
      .limit(1)
      .get();
  return snap.empty ? null : snap.docs[0].id;
}

// ★ ここが「サーバーだけが plan を書く」 核心部分 (Stripe)。
//   Admin SDK の書き込みはセキュリティルールをバイパスする。
async function setUserPlan(uid, {plan, status, expiresAt, customerId, subId}) {
  await admin.firestore().collection("users").doc(uid).set({
    plan: plan,
    subscriptionStatus: status,
    planExpiresAt: expiresAt,
    stripeCustomerId: customerId || null,
    stripeSubscriptionId: subId || null,
    planSource: "stripe",
    planUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, {merge: true});
  logger.info(`plan 更新(stripe): uid=${uid} plan=${plan} status=${status}`);
}

// ── RevenueCat 用ヘルパー ──

// $RCAnonymousID: で始まる匿名IDは Firebase uid ではないので除外する。
function isRealUid(id) {
  return typeof id === "string" &&
    id.length > 0 &&
    !id.startsWith("$RCAnonymousID:");
}

// イベントから Firebase uid を特定 (app_user_id を最優先、 次に aliases)。
function uidFromRcEvent(event) {
  if (isRealUid(event.app_user_id)) return event.app_user_id;
  const aliases = event.aliases || [];
  const real = aliases.find((id) => isRealUid(id));
  if (real) return real;
  if (isRealUid(event.original_app_user_id)) {
    return event.original_app_user_id;
  }
  return null;
}

// entitlement / product からプラン名を決定 (entitlement 優先)。
function planFromRcEvent(event) {
  const ents = event.entitlement_ids ||
    (event.entitlement_id ? [event.entitlement_id] : []);
  for (const e of ents) {
    if (RC_ENTITLEMENT_TO_PLAN[e]) return RC_ENTITLEMENT_TO_PLAN[e];
  }
  const pid = event.new_product_id || event.product_id;
  if (pid && RC_PRODUCT_TO_PLAN[pid]) return RC_PRODUCT_TO_PLAN[pid];
  return "pro"; // 不明時は pro 扱い (要 マップ整備)
}

// RevenueCat 由来の plan を書き込む。 Stripe 用フィールドは触らない (merge)。
async function setUserPlanRC(uid, {plan, status, expiresAt, store, appUserId}) {
  await admin.firestore().collection("users").doc(uid).set({
    plan: plan,
    subscriptionStatus: status,
    planExpiresAt: expiresAt,
    planSource: "revenuecat",
    rcStore: store || null,
    rcAppUserId: appUserId || null,
    planUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, {merge: true});
  logger.info(`plan 更新(revenuecat): uid=${uid} plan=${plan} ` +
    `status=${status} store=${store}`);
}

// タイミング安全な文字列比較 (長さ差でも例外を出さない)。
function safeEqual(a, b) {
  const ba = Buffer.from(String(a));
  const bb = Buffer.from(String(b));
  if (ba.length !== bb.length) return false;
  return crypto.timingSafeEqual(ba, bb);
}
