// HisatorNotebook 課金 Worker
//
// 役割:
//   1. Stripe の Webhook を受け取り、 署名を検証して購入・解約を反映する
//   2. アプリ (デスクトップ) からの問い合わせに、 そのユーザーのプランを返す
//
// なぜ必要か:
//   決済は外部ブラウザの Stripe Checkout で行うため、 アプリは「本当に
//   支払われたか」 を自分では判断できない。 クライアント側で「決済ページから
//   戻ってきたら Pro」 と判定すると、 支払わずに戻っただけで Pro になって
//   しまう。 そこで Stripe → この Worker → アプリ、 という経路で確定させる。
//
// 保存先: Workers KV (ENTITLEMENTS)。 キーは Firebase の匿名 UID。
//   値: {"plan":"pro","status":"active","subscriptionId":"sub_...",
//        "currentPeriodEnd":1234567890,"updatedAt":"..."}

const JSON_HEADERS = {
  'content-type': 'application/json; charset=utf-8',
  'access-control-allow-origin': '*',
};

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === 'OPTIONS') {
      return new Response(null, {
        headers: {
          'access-control-allow-origin': '*',
          'access-control-allow-methods': 'GET,POST,OPTIONS',
          'access-control-allow-headers': 'content-type,stripe-signature,authorization',
        },
      });
    }

    if (url.pathname === '/stripe/webhook' && request.method === 'POST') {
      return handleWebhook(request, env);
    }

    if (url.pathname === '/entitlement' && request.method === 'GET') {
      return handleEntitlement(url, env);
    }

    // ── AI 代行実行 (= アプリ側のキーで実行して使用量を計上する) ──
    if (url.pathname === '/ai/generate' && request.method === 'POST') {
      return handleAiGenerate(request, env);
    }
    if (url.pathname === '/ai/image' && request.method === 'POST') {
      return handleAiImage(request, env);
    }
    if (url.pathname === '/ai/usage' && request.method === 'GET') {
      return handleAiUsage(url, env, request);
    }

    // ── 前払いクレジット (= 最初に 10 ドル、 足りなくなったら都度チャージ) ──
    if (url.pathname === '/ai/models' && request.method === 'GET') {
      // 各社に問い合わせた「今使えるモデル」 に、 既知の単価を当てる。
      const found = await discoverModels(env);
      const prices = await livePrices(env);
      const seen = new Set();
      const out = [];
      const push = (id) => {
        if (!id || seen.has(id)) return;
        // ★ 実価格が確認できた物だけを出す (= ユーザー要望)。
        const live = findLivePrice(prices, id);
        if (!live) return;
        if (!providerKey(env, live.provider)) return;
        seen.add(id);
        out.push({
          id,
          provider: live.provider,
          inputPerMTok: round6(live.input),
          outputPerMTok: round6(live.output),
          billedInputPerMTok: round6(live.input * (1 + MARKUP)),
          billedOutputPerMTok: round6(live.output * (1 + MARKUP)),
          estimated: false,
          available: true,
        });
      };
      // 会社ごとに、 単価が確定している物を先に全部、 その後で
      // 新しく見つかった物を新しい順に足す (合計 10 件まで)。
      for (const prov of ['gemini', 'openai', 'anthropic']) {
        // 単価が確定している物は手で選んだ現行モデルなので無条件で載せる。
        for (const id of Object.keys(AI_MODELS)) {
          const p = priceFor(id);
          if (p && p.provider === prov) push(id);
        }
        const list = (found[prov] || [])
          .filter((id) => isCurrentModel(id, prov))
          .sort((a, b) => modelGeneration(b) - modelGeneration(a));
        let added = 0;
        for (const id of list) {
          if (added >= 3) break;
          const before = seen.size;
          push(id);
          if (seen.size > before) added++;
        }
      }
      return json({ markup: MARKUP, models: out });
    }
    if (url.pathname === '/credits/balance' && request.method === 'GET') {
      return handleCreditsBalance(url, env, request);
    }
    if (url.pathname === '/credits/checkout' && request.method === 'POST') {
      return handleCreditsCheckout(request, env);
    }

    // ── Dev プラン (= 決済を通さずに AI を使える枠。 発行できるのは
    //    ADMIN_UIDS に登録した本人だけ) ──
    if (url.pathname === '/dev/issue' && request.method === 'POST') {
      return handleDevIssue(request, env);
    }
    if (url.pathname === '/dev/codes' && request.method === 'GET') {
      return handleDevCodes(request, env);
    }
    if (url.pathname === '/dev/revoke' && request.method === 'POST') {
      return handleDevRevoke(request, env);
    }
    if (url.pathname === '/dev/redeem' && request.method === 'POST') {
      return handleDevRedeem(request, env);
    }

    // ── 公式サイトの訪問者数 (= ユーザー要望: HP の訪問者数が出ない) ──
    //   以前使っていた無料の外部カウンター (counterapi.dev v1) が廃止され
    //   410 Gone を返すようになったため、 自前の KV で数える。
    //     GET  /site/visits        → 今の数を返すだけ
    //     POST /site/visits        → 1 つ増やして返す (1 セッション 1 回)
    if (url.pathname === '/site/visits') {
      if (request.method === 'GET') return handleSiteVisits(env, false);
      if (request.method === 'POST') return handleSiteVisits(env, true);
    }

    if (url.pathname === '/health') {
      return new Response(JSON.stringify({ ok: true }), { headers: JSON_HEADERS });
    }

    return new Response('Not found', { status: 404 });
  },
};

// ─── 公式サイトの訪問者数 ───────────────────────────────────────────────
// 合計と「今日の分」 を KV に持つ。 KV は読んで書く間に割り込まれ得るので
// 厳密ではないが、 訪問者カウンターは 1 件ずれても実害が無いのでこれで足りる。
//
// 旧カウンター (counterapi.dev) の実績値は取り出せなくなったため、
// SITE_VISITS_BASE を置いてそこから足せるようにしてある (未設定なら 0)。
const SITE_VISITS_KEY = 'site:visits:total';

async function handleSiteVisits(env, increment) {
  try {
    const base = parseInt(env.SITE_VISITS_BASE || '0', 10) || 0;
    const today = new Date().toISOString().slice(0, 10);
    const dayKey = `site:visits:${today}`;
    let total = parseInt((await env.ENTITLEMENTS.get(SITE_VISITS_KEY)) || '0', 10) || 0;
    let day = parseInt((await env.ENTITLEMENTS.get(dayKey)) || '0', 10) || 0;
    if (increment) {
      total += 1;
      day += 1;
      await env.ENTITLEMENTS.put(SITE_VISITS_KEY, String(total));
      // 日別は 400 日で自然に消す (ずっと貯め続けない)。
      await env.ENTITLEMENTS.put(dayKey, String(day), {
        expirationTtl: 60 * 60 * 24 * 400,
      });
    }
    return new Response(
      JSON.stringify({ count: total + base, today: day, date: today }),
      { headers: JSON_HEADERS },
    );
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), {
      status: 500,
      headers: JSON_HEADERS,
    });
  }
}

// ─── アプリからの権利照会 ───────────────────────────────────────────────
async function handleEntitlement(url, env) {
  const uid = (url.searchParams.get('uid') || '').trim();
  if (!uid) {
    return new Response(JSON.stringify({ plan: 'free', reason: 'no uid' }), {
      headers: JSON_HEADERS,
    });
  }
  const raw = await env.ENTITLEMENTS.get(uid);
  if (!raw) {
    return new Response(JSON.stringify({ plan: 'free' }), { headers: JSON_HEADERS });
  }
  let data;
  try {
    data = JSON.parse(raw);
  } catch (_) {
    return new Response(JSON.stringify({ plan: 'free' }), { headers: JSON_HEADERS });
  }
  // 期限切れは free に落とす (解約後の猶予は Stripe 側の期間終了で判断)。
  const now = Math.floor(Date.now() / 1000);
  if (data.currentPeriodEnd && now > Number(data.currentPeriodEnd) + 3 * 86400) {
    data.plan = 'free';
    data.status = 'expired';
  }
  // Dev 枠は期限が来たら free に戻す (期限なしの Dev はそのまま)。
  if (data.plan === 'dev' && !isDevEntitlement(data)) {
    data.plan = 'free';
    data.status = 'expired';
  }
  return new Response(JSON.stringify(data), { headers: JSON_HEADERS });
}

// ─── 本人確認 (Firebase ID トークン) ───────────────────────────────────
//
// これまでは本文の uid をそのまま信じていたため、 uid を知る者なら誰でも
// そのユーザーの残高を使えてしまった。 アプリは Firebase の匿名認証で
// ID トークン (Google が署名した JWT) を持っているので、 それを検証し、
// **本文ではなくトークンの中の uid** を使う。
//
// 署名鍵は Google が公開している JWKS を使う。 毎回取りに行くと遅いので
// 1 時間ほど記憶する。
let _jwksCache = null;
let _jwksAt = 0;

async function firebaseJwks() {
  const now = Date.now();
  if (_jwksCache && now - _jwksAt < 60 * 60 * 1000) return _jwksCache;
  const res = await fetch(
    'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com'
  );
  if (!res.ok) throw new Error('jwks fetch failed');
  const j = await res.json();
  _jwksCache = j.keys || [];
  _jwksAt = now;
  return _jwksCache;
}

function b64urlToBytes(s) {
  const b64 = s.replace(/-/g, '+').replace(/_/g, '/');
  const pad = b64.length % 4 ? '='.repeat(4 - (b64.length % 4)) : '';
  const bin = atob(b64 + pad);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/// 検証に通れば uid (sub) を返す。 だめなら null。
async function verifyFirebaseIdToken(token, env) {
  try {
    if (!token) return null;
    const projectId = env.FIREBASE_PROJECT_ID;
    if (!projectId) return null;
    const parts = token.split('.');
    if (parts.length !== 3) return null;
    const header = JSON.parse(new TextDecoder().decode(b64urlToBytes(parts[0])));
    const payload = JSON.parse(new TextDecoder().decode(b64urlToBytes(parts[1])));
    if (header.alg !== 'RS256' || !header.kid) return null;

    // 中身の妥当性 (発行元・宛先・期限)。
    const now = Math.floor(Date.now() / 1000);
    if (payload.aud !== projectId) return null;
    if (payload.iss !== `https://securetoken.google.com/${projectId}`) return null;
    if (!payload.sub) return null;
    if (typeof payload.exp !== 'number' || payload.exp < now - 60) return null;

    // 署名の検証。
    const keys = await firebaseJwks();
    const jwk = keys.find((k) => k.kid === header.kid);
    if (!jwk) return null;
    const key = await crypto.subtle.importKey(
      'jwk',
      { kty: jwk.n ? 'RSA' : jwk.kty, n: jwk.n, e: jwk.e, alg: 'RS256', ext: true },
      { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
      false,
      ['verify']
    );
    const ok = await crypto.subtle.verify(
      'RSASSA-PKCS1-v1_5',
      key,
      b64urlToBytes(parts[2]),
      new TextEncoder().encode(`${parts[0]}.${parts[1]}`)
    );
    return ok ? String(payload.sub) : null;
  } catch (e) {
    console.log('verifyFirebaseIdToken failed', String(e));
    return null;
  }
}

/// リクエストから本人の uid を取り出す。 検証できなければ null。
async function authUid(request, env) {
  const h = request.headers.get('authorization') || '';
  if (!h.toLowerCase().startsWith('bearer ')) return null;
  return verifyFirebaseIdToken(h.slice(7).trim(), env);
}

function unauthorized() {
  return json(
    {
      error: 'unauthorized',
      detail: 'A valid Firebase ID token is required (Authorization: Bearer ...)',
    },
    401
  );
}

// ─── Stripe Webhook ────────────────────────────────────────────────────
async function handleWebhook(request, env) {
  const payload = await request.text();
  const sig = request.headers.get('stripe-signature') || '';
  const ok = await verifyStripeSignature(payload, sig, env.STRIPE_WEBHOOK_SECRET);
  if (!ok) return new Response('bad signature', { status: 400 });

  let event;
  try {
    event = JSON.parse(payload);
  } catch (_) {
    return new Response('bad json', { status: 400 });
  }

  try {
    switch (event.type) {
      case 'checkout.session.completed': {
        const s = event.data.object;
        const uid = s.client_reference_id;
        // ── クレジットのチャージ (= 前払い) ──
        //   metadata.kind === 'credit' のセッションは残高を増やすだけ。
        //   同じセッションを二重計上しないよう、 処理済み id を残す。
        if (uid && s.metadata && s.metadata.kind === 'credit') {
          const seen = await env.ENTITLEMENTS.get(`credit_evt:${s.id}`);
          if (!seen) {
            // amount_total は最小通貨単位 (セント)。
            const usd = Number(s.amount_total || 0) / 100;
            if (usd > 0) {
              await addCredit(env, uid, usd, `charge:${s.id}`, s.id);
              await env.ENTITLEMENTS.put(`credit_evt:${s.id}`, '1', {
                expirationTtl: 60 * 60 * 24 * 90,
              });
            }
          }
          break;
        }
        // plan の決め方 (上から順に採用):
        //   1. セッションの metadata
        //   2. 決済リンク ID → plan の対応表 (env.PLAN_MAP)
        //   3. line_items から price/product の metadata を引く
        const plan =
          (s.metadata && s.metadata.plan) ||
          planFromLink(s.payment_link, env) ||
          (await planFromSession(s, env));
        if (uid && plan) {
          await putEntitlement(env, uid, {
            plan,
            status: 'active',
            subscriptionId: s.subscription || null,
            customerId: s.customer || null,
            currentPeriodEnd: null,
          });
          // サブスク側にも uid を記録しておく (更新・解約イベントで引ける)
          if (s.subscription) {
            await stripeApi(env, `subscriptions/${s.subscription}`, {
              'metadata[uid]': uid,
              'metadata[plan]': plan,
            });
            await env.ENTITLEMENTS.put(`sub:${s.subscription}`, uid);
          }
        }
        break;
      }
      case 'customer.subscription.updated':
      case 'customer.subscription.created': {
        const sub = event.data.object;
        const uid = (sub.metadata && sub.metadata.uid) ||
          (await env.ENTITLEMENTS.get(`sub:${sub.id}`));
        if (uid) {
          const active = ['active', 'trialing', 'past_due'].includes(sub.status);
          await putEntitlement(env, uid, {
            plan: active ? ((sub.metadata && sub.metadata.plan) || 'pro') : 'free',
            status: sub.status,
            subscriptionId: sub.id,
            customerId: sub.customer || null,
            currentPeriodEnd: subPeriodEnd(sub),
          });
        }
        break;
      }
      case 'customer.subscription.deleted': {
        const sub = event.data.object;
        const uid = (sub.metadata && sub.metadata.uid) ||
          (await env.ENTITLEMENTS.get(`sub:${sub.id}`));
        if (uid) {
          await putEntitlement(env, uid, {
            plan: 'free',
            status: 'canceled',
            subscriptionId: sub.id,
            customerId: sub.customer || null,
            currentPeriodEnd: subPeriodEnd(sub),
          });
        }
        break;
      }
      default:
        break;
    }
  } catch (e) {
    // 失敗しても 200 を返さないと Stripe が再送し続けるため、内容だけ記録。
    console.log('webhook handling error', String(e));
  }

  return new Response(JSON.stringify({ received: true }), { headers: JSON_HEADERS });
}

async function putEntitlement(env, uid, data) {
  const value = JSON.stringify({ ...data, updatedAt: new Date().toISOString() });
  await env.ENTITLEMENTS.put(uid, value);
}

/// 契約期間の終わり (UNIX 秒) を取り出す。
///
/// Stripe は API を新しくした際に、 この項目をサブスク直下から
/// 「明細 (items)」 の下へ移した。 どちらの形で届くかは webhook が使う
/// API バージョン次第なので、 両方を見る。 取れないと期限切れ判定
/// (handleEntitlement) が働かず、 支払いが止まっても権利が残り続ける。
function subPeriodEnd(sub) {
  if (!sub) return null;
  if (sub.current_period_end) return sub.current_period_end;
  const items = (sub.items && sub.items.data) || [];
  for (const it of items) {
    if (it && it.current_period_end) return it.current_period_end;
  }
  return null;
}

/// 決済リンク ID から plan を引く (env.PLAN_MAP は {"plink_x":"pro"} の JSON)。
function planFromLink(linkId, env) {
  if (!linkId || !env.PLAN_MAP) return null;
  try {
    const map = JSON.parse(env.PLAN_MAP);
    return map[linkId] || null;
  } catch (_) {
    return null;
  }
}

/// Checkout Session の行から plan を割り出す (metadata が無い場合の保険)。
async function planFromSession(session, env) {
  try {
    const res = await stripeApiGet(env, `checkout/sessions/${session.id}/line_items`);
    const price = res && res.data && res.data[0] && res.data[0].price;
    if (price && price.metadata && price.metadata.plan) return price.metadata.plan;
    if (price && price.product) {
      const prod = await stripeApiGet(env, `products/${price.product}`);
      if (prod && prod.metadata && prod.metadata.plan) return prod.metadata.plan;
    }
  } catch (_) {}
  return null;
}

// ─── Dev プラン (= 決済を通さずに AI を呼べる枠) ────────────────────────
//
// なぜサーバーに要るか:
//   AI を実際に呼ぶのはこの Worker で、 支払いはここで残高から引かれる。
//   アプリ側だけで「自分は Dev だ」 と決めても、 ここが知らなければ
//   「残高不足」 で断られるだけになる。 そこで権利情報 (ENTITLEMENTS) の
//   plan を 'dev' にし、 引き落としだけを飛ばす (使用量は普通に記録する)。
//
// 誰が発行できるか:
//   ADMIN_UIDS (シークレット) に書いた uid だけ。 アプリ側の開発者モードの
//   パスワードは「画面の入口」 に過ぎず、 本当の防壁はこの uid 照合。
//   パスワードを知らない Dev 利用者がアプリを弄っても、 ここで弾かれる。
//
// 保存先: KV
//   devcode:<CODE> = { code, note, maxUses, currentUses, expiresAt(秒),
//                      months, createdAt, createdBy, revoked }
//   devredeem:<CODE>:<uid> = '1'  (同じ人が二重に使用回数を消費しない印)

/// 発行を許す uid かどうか。 ADMIN_UIDS は「,」 か空白区切り。
function isAdminUid(env, uid) {
  const raw = String(env.ADMIN_UIDS || '').trim();
  if (!raw || !uid) return false;
  return raw
    .split(/[\s,]+/)
    .filter(Boolean)
    .includes(uid);
}

/// 紛らわしい文字 (O/0/I/1) を除いた 8 文字コード。 アプリ側と同じ字種。
function makeDevCode() {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  const buf = new Uint8Array(8);
  crypto.getRandomValues(buf);
  let s = '';
  for (const b of buf) s += chars[b % chars.length];
  return s;
}

function devCodeKey(code) {
  return `devcode:${code}`;
}

async function readDevCode(env, code) {
  const raw = await env.ENTITLEMENTS.get(devCodeKey(code));
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

/// 権利情報が「今 Dev として有効か」。 期限切れは false。
function isDevEntitlement(ent) {
  if (!ent || ent.plan !== 'dev') return false;
  const until = Number(ent.devExpiresAt || 0);
  if (until && Math.floor(Date.now() / 1000) > until) return false;
  return true;
}

async function handleDevIssue(request, env) {
  const uid = await authUid(request, env);
  if (!uid) return unauthorized();
  if (!isAdminUid(env, uid)) {
    return json({ error: 'forbidden', detail: 'not an admin uid' }, 403);
  }
  let body;
  try {
    body = await request.json();
  } catch {
    body = {};
  }
  const maxUses = Math.max(0, Math.round(Number(body.maxUses || 0)));
  // 引き換えた人が Dev でいられる月数 (0 = 無期限)。
  const months = Math.max(0, Math.min(120, Math.round(Number(body.months || 0))));
  // コード自体が使えなくなる日 (秒)。 0 = 無期限。
  const expiresAt = Math.max(0, Math.round(Number(body.expiresAt || 0)));
  const note = String(body.note || '').slice(0, 200);
  const code = makeDevCode();
  const rec = {
    code,
    note,
    maxUses,
    months,
    expiresAt,
    currentUses: 0,
    createdAt: Math.floor(Date.now() / 1000),
    createdBy: uid,
    revoked: false,
  };
  await env.ENTITLEMENTS.put(devCodeKey(code), JSON.stringify(rec));
  return json({ ok: true, code, dev: rec });
}

async function handleDevCodes(request, env) {
  const uid = await authUid(request, env);
  if (!uid) return unauthorized();
  if (!isAdminUid(env, uid)) return json({ error: 'forbidden' }, 403);
  const list = await env.ENTITLEMENTS.list({ prefix: 'devcode:', limit: 200 });
  const out = [];
  for (const k of list.keys) {
    const rec = await readDevCode(env, k.name.slice('devcode:'.length));
    if (rec) out.push(rec);
  }
  out.sort((a, b) => Number(b.createdAt || 0) - Number(a.createdAt || 0));
  return json({ codes: out });
}

async function handleDevRevoke(request, env) {
  const uid = await authUid(request, env);
  if (!uid) return unauthorized();
  if (!isAdminUid(env, uid)) return json({ error: 'forbidden' }, 403);
  let body;
  try {
    body = await request.json();
  } catch {
    body = {};
  }
  const code = String(body.code || '').trim().toUpperCase();
  if (!code) return json({ error: 'code is required' }, 400);
  await env.ENTITLEMENTS.delete(devCodeKey(code));
  return json({ ok: true });
}

/// コードを引き換えて、 その uid を Dev にする。 発行と違い、 これは
/// 誰でも呼べる (正しいコードを持っている人だけが通る)。
async function handleDevRedeem(request, env) {
  const uid = await authUid(request, env);
  if (!uid) return unauthorized();
  let body;
  try {
    body = await request.json();
  } catch {
    body = {};
  }
  const code = String(body.code || '').trim().toUpperCase();
  if (!code) return json({ error: 'code is required' }, 400);
  const rec = await readDevCode(env, code);
  if (!rec || rec.revoked) return json({ error: 'invalid code' }, 404);
  const now = Math.floor(Date.now() / 1000);
  if (rec.expiresAt && now > Number(rec.expiresAt)) {
    return json({ error: 'expired code' }, 410);
  }
  // 同じ人が何度押しても使用回数は 1 回だけ数える。
  const seenKey = `devredeem:${code}:${uid}`;
  const seen = await env.ENTITLEMENTS.get(seenKey);
  if (!seen) {
    if (rec.maxUses > 0 && Number(rec.currentUses || 0) >= rec.maxUses) {
      return json({ error: 'code used up' }, 409);
    }
    rec.currentUses = Number(rec.currentUses || 0) + 1;
    await env.ENTITLEMENTS.put(devCodeKey(code), JSON.stringify(rec));
    await env.ENTITLEMENTS.put(seenKey, '1');
  }
  const devExpiresAt = rec.months > 0 ? now + rec.months * 30 * 86400 : 0;
  const prev = (await readEntitlement(env, uid)) || {};
  await putEntitlement(env, uid, {
    ...prev,
    plan: 'dev',
    status: 'active',
    devCode: code,
    devExpiresAt,
    // Stripe 由来の期限判定 (readEntitlement) に巻き込まれないよう外す。
    currentPeriodEnd: null,
  });
  return json({ ok: true, plan: 'dev', devExpiresAt });
}


// ─── 残高の金庫 (Durable Object) ───────────────────────────────────────
//
// KV には「読んで・書く」 の間に割り込まれない仕組みが無いため、 同時に
// リクエストが来ると引き落としが上書きで消えてしまう。 Durable Object は
// uid ごとに 1 つだけ作られ、 中の処理が順番に実行されるので、 ここで
// 残高を扱えば取りこぼしが起きない。
//
// 既存ユーザーの残高は、 初回アクセス時に KV から引き継ぐ。 書き込みは
// KV にも複製しておく (管理画面や障害時に中身を読めるように)。
export class CreditAccount {
  constructor(state, env) {
    this.state = state;
    this.env = env;
  }

  async load(uid) {
    let c = await this.state.storage.get('credit');
    if (!c) {
      let from = null;
      try {
        const raw = await this.env.ENTITLEMENTS.get(`credit:${uid}`);
        if (raw) from = JSON.parse(raw);
      } catch (_) {}
      c = {
        balanceUsd: Number((from && from.balanceUsd) || 0),
        totalChargedUsd: Number((from && from.totalChargedUsd) || 0),
        totalSpentUsd: Number((from && from.totalSpentUsd) || 0),
        ledger: Array.isArray(from && from.ledger) ? from.ledger : [],
      };
      await this.state.storage.put('credit', c);
    }
    return c;
  }

  async save(uid, c) {
    c.ledger = c.ledger.slice(-200);
    await this.state.storage.put('credit', c);
    try {
      await this.env.ENTITLEMENTS.put(
        `credit:${uid}`,
        JSON.stringify({ ...c, updatedAt: new Date().toISOString() })
      );
    } catch (_) {}
  }

  async fetch(request) {
    const url = new URL(request.url);
    const uid = url.searchParams.get('uid') || '';
    const op = url.pathname;
    const body = await request.json().catch(() => ({}));
    const c = await this.load(uid);

    if (op === '/read') {
      return Response.json({ ok: true, credit: c });
    }

    if (op === '/add') {
      const usd = Number(body.usd || 0);
      // 同じ決済を二重に足さない。
      if (body.eventId) {
        const seen = await this.state.storage.get(`evt:${body.eventId}`);
        if (seen) return Response.json({ ok: true, credit: c, duplicated: true });
        await this.state.storage.put(`evt:${body.eventId}`, 1);
      }
      if (usd > 0) {
        c.balanceUsd = round6(c.balanceUsd + usd);
        c.totalChargedUsd = round6(c.totalChargedUsd + usd);
        c.ledger.push({ t: Date.now(), kind: 'charge', usd: round6(usd), note: body.note });
        await this.save(uid, c);
      }
      return Response.json({ ok: true, credit: c });
    }

    // 予約: 上流を呼ぶ前に「最大でかかる額」 を先に引いておく。
    if (op === '/reserve') {
      const usd = Number(body.usd || 0);
      if (c.balanceUsd < usd) return Response.json({ ok: false, credit: c });
      c.balanceUsd = round6(c.balanceUsd - usd);
      await this.save(uid, c);
      return Response.json({ ok: true, credit: c });
    }

    // 精算: 予約した額を戻し、 実際にかかった額を引く。
    if (op === '/settle') {
      const hold = Number(body.hold || 0);
      const actual = Number(body.actual || 0);
      c.balanceUsd = round6(c.balanceUsd + hold - actual);
      if (actual > 0) {
        c.totalSpentUsd = round6(c.totalSpentUsd + actual);
        c.ledger.push({ t: Date.now(), kind: 'spend', usd: round6(actual), note: body.note });
      }
      await this.save(uid, c);
      return Response.json({ ok: true, credit: c });
    }

    return new Response('bad op', { status: 400 });
  }
}

/// Durable Object を呼ぶ。 binding が無い環境では null を返し、
/// 呼び出し側が従来の KV 方式に落ちる (取りこぼし対策は効かないが動く)。
async function creditOp(env, uid, op, body) {
  if (!env.CREDITS) return null;
  try {
    const stub = env.CREDITS.get(env.CREDITS.idFromName(uid));
    const res = await stub.fetch(
      `https://credits.internal${op}?uid=${encodeURIComponent(uid)}`,
      {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body || {}),
      }
    );
    return await res.json();
  } catch (e) {
    console.log('creditOp failed', op, String(e));
    return null;
  }
}

// ─── 前払いクレジット ─────────────────────────────────────────────────
//
// 仕組み:
//   ・ユーザーは最低 10 ドルを先に払う (Stripe Checkout)。
//   ・AI を使うたびに「原価 × 1.1」 を残高から引く。
//   ・残高が足りなくなったらアプリが再チャージを促す。
//
// なぜ前払いか:
//   後払いだと、 使われてから回収できないリスク (カード拒否・チャージバック)
//   をこちらが負う。 先に預かっておけば取りっぱぐれない。
//
// 保存先: KV の `credit:<uid>`
//   { balanceUsd, totalChargedUsd, totalSpentUsd, updatedAt, ledger: [...] }

/// 1 回のチャージ額 (ドル)。 最低額でもあり、 追加チャージの単位でもある。
const CREDIT_PACK_USD = 10;

/// 残高がこれを下回ったらアプリ側で「そろそろチャージ」 と案内する。
const CREDIT_LOW_USD = 1.0;

function creditKey(uid) {
  return `credit:${uid}`;
}

async function readCredit(env, uid) {
  // 金庫 (Durable Object) が使えるならそちらが正。
  const viaDo = await creditOp(env, uid, '/read', {});
  if (viaDo && viaDo.credit) return viaDo.credit;
  const raw = await env.ENTITLEMENTS.get(creditKey(uid));
  if (!raw) {
    return {
      balanceUsd: 0,
      totalChargedUsd: 0,
      totalSpentUsd: 0,
      ledger: [],
    };
  }
  try {
    const c = JSON.parse(raw);
    return {
      balanceUsd: Number(c.balanceUsd || 0),
      totalChargedUsd: Number(c.totalChargedUsd || 0),
      totalSpentUsd: Number(c.totalSpentUsd || 0),
      ledger: Array.isArray(c.ledger) ? c.ledger : [],
    };
  } catch {
    return { balanceUsd: 0, totalChargedUsd: 0, totalSpentUsd: 0, ledger: [] };
  }
}

async function writeCredit(env, uid, c) {
  // 明細は直近 200 件だけ残す (KV の値サイズを抑える)。
  const ledger = c.ledger.slice(-200);
  await env.ENTITLEMENTS.put(
    creditKey(uid),
    JSON.stringify({ ...c, ledger, updatedAt: new Date().toISOString() })
  );
}

/// 残高を増やす (チャージ)。
async function addCredit(env, uid, usd, note, eventId) {
  const viaDo = await creditOp(env, uid, '/add', { usd, note, eventId });
  if (viaDo && viaDo.credit) return viaDo.credit;
  const c = await readCredit(env, uid);
  c.balanceUsd = round6(c.balanceUsd + usd);
  c.totalChargedUsd = round6(c.totalChargedUsd + usd);
  c.ledger.push({ t: Date.now(), kind: 'charge', usd: round6(usd), note });
  await writeCredit(env, uid, c);
  return c;
}

/// 残高から引く (利用)。 足りなければ何もせず false。
async function spendCredit(env, uid, usd, note) {
  const viaDo = await creditOp(env, uid, '/settle', { hold: 0, actual: usd, note });
  if (viaDo && viaDo.credit) {
    return { ok: true, credit: viaDo.credit };
  }
  const c = await readCredit(env, uid);
  if (c.balanceUsd < usd) return { ok: false, credit: c };
  c.balanceUsd = round6(c.balanceUsd - usd);
  c.totalSpentUsd = round6(c.totalSpentUsd + usd);
  c.ledger.push({ t: Date.now(), kind: 'spend', usd: round6(usd), note });
  await writeCredit(env, uid, c);
  return { ok: true, credit: c };
}

function round6(n) {
  return Math.round(n * 1e6) / 1e6;
}

/// 未決済のチャージセッションを Stripe に照合し、 支払済みなら入金する。
/// webhook が届かない環境 (テスト・webhook 未設定) の保険。 webhook と
/// 二重に走っても `credit_evt:<id>` で二重計上は防がれる。
async function settlePendingCheckout(env, uid) {
  try {
    const sid = await env.ENTITLEMENTS.get(`credit_pending:${uid}`);
    if (!sid) return;
    const s = await stripeApiGet(env, `checkout/sessions/${sid}`);
    if (!s || !s.id) return;
    if (s.payment_status === 'paid') {
      const seen = await env.ENTITLEMENTS.get(`credit_evt:${s.id}`);
      if (!seen) {
        const usd = Number(s.amount_total || 0) / 100;
        if (usd > 0) {
          await addCredit(env, uid, usd, `charge:${s.id}`, s.id);
          await env.ENTITLEMENTS.put(`credit_evt:${s.id}`, '1', {
            expirationTtl: 60 * 60 * 24 * 90,
          });
        }
      }
      await env.ENTITLEMENTS.delete(`credit_pending:${uid}`);
    } else if (s.status === 'expired') {
      await env.ENTITLEMENTS.delete(`credit_pending:${uid}`);
    }
  } catch (_) {}
}

async function handleCreditsBalance(url, env, request) {
  const uid = await authUid(request, env);
  if (!uid) return unauthorized();
  // 未決済のチャージがあれば Stripe に照合して先に入金する
  // (= webhook 未設定・テスト環境の保険)。
  await settlePendingCheckout(env, uid);
  const c = await readCredit(env, uid);
  return json({
    balanceUsd: c.balanceUsd,
    totalChargedUsd: c.totalChargedUsd,
    totalSpentUsd: c.totalSpentUsd,
    packUsd: CREDIT_PACK_USD,
    lowThresholdUsd: CREDIT_LOW_USD,
    markup: MARKUP,
    low: c.balanceUsd < CREDIT_LOW_USD,
    // 直近の明細 (アプリで履歴を出す用)。
    recent: c.ledger.slice(-20).reverse(),
  });
}

/// チャージ用の Stripe Checkout セッションを作って URL を返す。
async function handleCreditsCheckout(request, env) {
  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: 'invalid json' }, 400);
  }
  const uid = await authUid(request, env);
  if (!uid) return unauthorized();
  if (!env.STRIPE_SECRET_KEY) return json({ error: 'stripe not configured' }, 503);

  // 何パック買うか (1 パック = 10 ドル)。 1〜20 に制限。
  let packs = Number(body.packs || 1);
  if (!Number.isFinite(packs)) packs = 1;
  packs = Math.min(20, Math.max(1, Math.round(packs)));
  const amountUsd = CREDIT_PACK_USD * packs;

  const returnUrl = env.CREDIT_RETURN_URL || 'https://hisator-notebook.com/thanks';
  try {
    const session = await stripeApi(env, 'checkout/sessions', {
      mode: 'payment',
      client_reference_id: uid,
      'metadata[kind]': 'credit',
      'metadata[uid]': uid,
      'line_items[0][quantity]': '1',
      'line_items[0][price_data][currency]': 'usd',
      'line_items[0][price_data][unit_amount]': String(amountUsd * 100),
      'line_items[0][price_data][product_data][name]':
        `HisatorNotebook AI クレジット $${amountUsd}`,
      'line_items[0][price_data][product_data][description]':
        'AI の利用に使える前払いクレジットです。使った分だけ残高から引かれます。',
      success_url: `${returnUrl}?credit=ok`,
      cancel_url: `${returnUrl}?credit=cancel`,
    });
    if (!session || !session.url) {
      return json({ error: 'could not create checkout session', detail: session }, 502);
    }
    // ── webhook が未設定でも残高に反映できるよう、 未決済セッションを控える ──
    //   (= ユーザー要望: テスト環境でも決済→AI 呼び出しを試せるように)。
    //   残高照会 (アプリの「更新」 ボタン) の度に Stripe へ照合して、
    //   支払済みなら入金する。 webhook と二重に走っても credit_evt で
    //   二重計上は防がれる。
    try {
      await env.ENTITLEMENTS.put(`credit_pending:${uid}`, session.id, {
        expirationTtl: 60 * 60 * 24,
      });
    } catch (_) {}
    return json({ url: session.url, amountUsd, packs });
  } catch (e) {
    return json({ error: String(e) }, 502);
  }
}

// ─── AI 代行実行 ───────────────────────────────────────────────────────
//
// なぜ Worker でやるのか:
//   ・アプリに本物の API キーを埋めると誰でも抜き出せる。 キーはここだけに置く。
//   ・トークン使用量を「こちら側で」 数えないと請求根拠にならない。
//     クライアントの自己申告は改ざんできるので、 AI からの返答に含まれる
//     usage を Worker が読んで KV に積む。
//
// 料金 (USD / 100万トークン)。 原価。 請求はこれに MARKUP を掛けた額。
//
// 料金 (USD / 100万トークン)。 原価。 請求はこれに MARKUP を掛けた額。
// provider は 'gemini' | 'openai' | 'anthropic'。
// OpenRouter は経由するだけで 5% 抜かれるので使わず、 各社と直接やり取りする。
const AI_MODELS = {
  // ── Google Gemini ──
  //   `-latest` は Google 側が随時最新へ差し替えるので、 既定はこれ。
  'gemini-flash-latest': { provider: 'gemini', input: 0.30, output: 2.50 },
  'gemini-pro-latest': { provider: 'gemini', input: 1.25, output: 10.0 },
  'gemini-3.6-flash': { provider: 'gemini', input: 0.30, output: 2.50 },
  'gemini-3.5-flash': { provider: 'gemini', input: 0.30, output: 2.50 },
  // ── OpenAI (ChatGPT) ──
  //   gpt-4 系は世代が古いので載せない (= ユーザー要望)。 現行の gpt-5 系は
  //   単価が確定していないため、 安全側の推定 (FALLBACK_PRICE) を使う。
  // ── Anthropic (Claude) ──
  //   Claude 5 世代が最新。 4.5 世代は Haiku のみ現行。
  'claude-opus-5': { provider: 'anthropic', input: 5.00, output: 25.0 },
  'claude-sonnet-5': { provider: 'anthropic', input: 3.00, output: 15.0 },
  'claude-haiku-4-5-20251001': {
    provider: 'anthropic',
    input: 1.00,
    output: 5.00,
  },
};

/// 各社モデルの「実際の単価」 を取り込む。
///
/// 各社の API は価格を返してくれないが、 OpenRouter が公開している一覧に
/// 100 万トークンあたりの単価が載っている。 これを 12 時間ごとに取り込み、
/// **価格が確認できたモデルだけ**を利用者に出す (= ユーザー要望: 推定では
/// なく正確な単価にする。 取れない物は出さない)。
async function livePrices(env) {
  const KEY = 'model_prices_v1';
  try {
    const c = await env.ENTITLEMENTS.get(KEY, 'json');
    if (c && Date.now() - c.at < 12 * 60 * 60 * 1000) return c.map;
  } catch (_) {}

  const map = {};
  try {
    const r = await fetch('https://openrouter.ai/api/v1/models');
    const j = await r.json();
    for (const m of j.data || []) {
      const id = String(m.id || '');
      // バッチ版などの派生は使わない。
      if (id.includes(':')) continue;
      const slash = id.indexOf('/');
      if (slash < 0) continue;
      const vendor = id.slice(0, slash);
      const name = id.slice(slash + 1);
      const p = m.pricing || {};
      const input = Number(p.prompt) * 1e6;
      const output = Number(p.completion) * 1e6;
      if (!Number.isFinite(input) || !Number.isFinite(output)) continue;
      if (input <= 0 && output <= 0) continue;
      let provider = null;
      if (vendor === 'openai') provider = 'openai';
      else if (vendor === 'anthropic') provider = 'anthropic';
      else if (vendor === 'google') provider = 'gemini';
      if (!provider) continue;
      map[name] = { provider, input, output };
      // Anthropic は各社 API 側が日付付き id を使う (claude-haiku-4.5 →
      //   claude-haiku-4-5-20251001)。 ドットを ハイフンに直した形も引ける
      //   ようにしておく。
      const dashed = name.replace(/\./g, '-');
      if (!map[dashed]) map[dashed] = { provider, input, output };
    }
  } catch (e) {
    console.log('price fetch failed', String(e));
  }
  try {
    await env.ENTITLEMENTS.put(
      KEY,
      JSON.stringify({ at: Date.now(), map }),
      { expirationTtl: 60 * 60 * 24 }
    );
  } catch (_) {}
  return map;
}

/// 取り込んだ価格表から、 このアプリのモデル id に合う単価を探す。
/// 日付付き (claude-haiku-4-5-20251001) は日付を落として照合する。
function findLivePrice(prices, id) {
  if (prices[id]) return prices[id];
  const noDate = id.replace(/-\d{8}$/, '');
  if (prices[noDate]) return prices[noDate];
  const dotted = noDate.replace(/-(\d+)-(\d+)$/, '-$1.$2');
  if (prices[dotted]) return prices[dotted];
  return null;
}

/// 単価が分からない (= 新しく出た) モデルに使う安全側の見積り。
/// 実際より高めに請求されるが、 こちらが持ち出しになることは無い。
const FALLBACK_PRICE = {
  gemini: { input: 2.0, output: 12.0 },
  openai: { input: 3.0, output: 12.0 },
  anthropic: { input: 5.0, output: 25.0 },
};

/// 各社に「今使えるモデル」 を聞く。 12 時間だけ記憶する
/// (= ユーザー要望: 定期的に最新のモデルへ入れ替わるように)。
async function discoverModels(env) {
  const CACHE_KEY = 'models_discovered_v1';
  try {
    const cached = await env.ENTITLEMENTS.get(CACHE_KEY, 'json');
    if (cached && Date.now() - cached.at < 12 * 60 * 60 * 1000) {
      return cached.ids;
    }
  } catch (_) {}

  const ids = { gemini: [], openai: [], anthropic: [] };

  // Gemini
  if (env.GEMINI_API_KEY) {
    try {
      const r = await fetch(
        `https://generativelanguage.googleapis.com/v1beta/models?key=${env.GEMINI_API_KEY}&pageSize=200`
      );
      const j = await r.json();
      for (const m of j.models || []) {
        const name = String(m.name || '').replace(/^models\//, '');
        const methods = m.supportedGenerationMethods || [];
        if (!methods.includes('generateContent')) continue;
        if (/embedding|aqa|imagen|veo|tts|image/i.test(name)) continue;
        ids.gemini.push(name);
      }
    } catch (e) {
      console.log('gemini models failed', String(e));
    }
  }

  // OpenAI
  if (env.OPENAI_API_KEY) {
    try {
      const r = await fetch('https://api.openai.com/v1/models', {
        headers: { Authorization: `Bearer ${env.OPENAI_API_KEY}` },
      });
      const j = await r.json();
      for (const m of j.data || []) {
        const id = String(m.id || '');
        // 会話に使えるものだけ (埋め込み・音声・画像などは除く)。
        if (!/^(gpt-|o[1-9])/.test(id)) continue;
        if (/embedding|audio|realtime|tts|whisper|image|dall|moderation|transcribe|search|instruct/i.test(id)) continue;
        ids.openai.push(id);
      }
    } catch (e) {
      console.log('openai models failed', String(e));
    }
  }

  // Anthropic
  if (env.ANTHROPIC_API_KEY) {
    try {
      const r = await fetch('https://api.anthropic.com/v1/models?limit=100', {
        headers: {
          'x-api-key': env.ANTHROPIC_API_KEY,
          'anthropic-version': '2023-06-01',
        },
      });
      const j = await r.json();
      for (const m of j.data || []) {
        const id = String(m.id || '');
        if (id) ids.anthropic.push(id);
      }
    } catch (e) {
      console.log('anthropic models failed', String(e));
    }
  }

  try {
    await env.ENTITLEMENTS.put(
      CACHE_KEY,
      JSON.stringify({ at: Date.now(), ids }),
      { expirationTtl: 60 * 60 * 24 }
    );
  } catch (_) {}
  return ids;
}

/// 今どきのモデルだけに絞る (= ユーザー要望: gpt-4 のような古い物は出さない)。
///   ・日付入りのスナップショット (…-2025-08-07) は別名があるので除く
///   ・コード特化 (codex) はこのアプリの用途では出さない
///   ・世代が古い系列 (gpt-4 以前 / claude-3 / gemini-2 以前) は除く
function isCurrentModel(id, provider) {
  if (/\d{4}-\d{2}-\d{2}$/.test(id)) return false;
  if (/codex|customtools/i.test(id)) return false;
  // 試験版と日付入りスナップショットは出さない (= ユーザー要望: 数を絞る)。
  //   ただし単価が確定している物 (AI_MODELS) は別途必ず載せる。
  if (/preview|exp/i.test(id)) return false;
  if (/-\d{8}$/.test(id)) return false;
  if (provider === 'openai') return /^gpt-[5-9]/.test(id);
  if (provider === 'anthropic') {
    return /^claude-(opus|sonnet|haiku|fable)-([5-9]|4-[5-9])/.test(id);
  }
  if (provider === 'gemini') {
    return /-latest$/.test(id) || /^gemini-[3-9]/.test(id);
  }
  return false;
}

/// 並べ替え用の世代番号 (大きいほど新しい)。
///   gpt-5.6-luna → 5.6 / claude-haiku-4-5 → 4.5 / gemini-3.6-flash → 3.6
///   末尾の日付 (20251001 等) は世代ではないので無視する。
function modelGeneration(id) {
  const nums = (id.match(/\d+/g) || [])
    .map(Number)
    .filter((n) => n < 1000); // 日付らしき大きい数は除く
  if (nums.length === 0) return 0;
  return nums[0] + (nums.length > 1 ? nums[1] / 10 : 0);
}

/// モデル id から単価を引く。 表に無ければ安全側の推定を返す。
function priceFor(id) {
  const known = AI_MODELS[id];
  if (known) return { ...known, estimated: false };
  let provider = 'gemini';
  if (/^(gpt-|o[1-9])/.test(id)) provider = 'openai';
  else if (/^claude/.test(id)) provider = 'anthropic';
  else if (/^gemini/.test(id)) provider = 'gemini';
  else return null;
  return { provider, ...FALLBACK_PRICE[provider], estimated: true };
}

const DEFAULT_MODEL = 'gemini-flash-latest';

/// 各社のキーは Worker のシークレットにだけ置く (アプリには絶対に入れない)。
function providerKey(env, provider) {
  switch (provider) {
    case 'openai':
      return env.OPENAI_API_KEY;
    case 'anthropic':
      return env.ANTHROPIC_API_KEY;
    default:
      return env.GEMINI_API_KEY;
  }
}

// ─── 入力画像 (= カメラで撮った写真など) ──────────────────────────────
//
// 受け取る形: [{ mime: 'image/jpeg', data: '<base64>' }, ...]
// 1 リクエストの合計サイズを制限する。 Workers の CPU / メモリと、
// 各社の上限 (だいたい 20MB 前後) の両方に配慮した控えめな値。
const MAX_INPUT_IMAGES = 4;
const MAX_INPUT_IMAGE_BYTES = 6 * 1024 * 1024; // base64 前の目安 (合計)
const IMAGE_INPUT_TOKENS_EST = 1600; // 見積り用 (1 枚あたり)

const ALLOWED_IMAGE_MIME = new Set([
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/gif',
  'image/heic',
  'image/heif',
]);

/// 妥当な画像だけを取り出す。 大き過ぎる時は null (= 呼び出し側で 413)。
function sanitizeInputImages(raw) {
  if (!Array.isArray(raw) || raw.length === 0) return [];
  const out = [];
  let bytes = 0;
  for (const e of raw.slice(0, MAX_INPUT_IMAGES)) {
    if (!e || typeof e !== 'object') continue;
    const data = String(e.data || '').replace(/\s+/g, '');
    if (!data) continue;
    let mime = String(e.mime || e.mimeType || 'image/jpeg').toLowerCase();
    if (!ALLOWED_IMAGE_MIME.has(mime)) mime = 'image/jpeg';
    bytes += Math.floor((data.length * 3) / 4);
    if (bytes > MAX_INPUT_IMAGE_BYTES) return null;
    out.push({ mime, data });
  }
  return out;
}

/// 各社の API を叩いて、 本文とトークン数を同じ形にして返す。
/// [images] があれば画像も一緒に渡す (対応していない会社では無視される)。
/// 戻り: { ok, status, text, inTok, outTok, detail }
async function callProvider(env, model, prompt, maxTokens, images) {
  const imgs = Array.isArray(images) ? images : [];
  // 提供元は実価格表から引く。 推定表にしか無い / どちらにも無いモデルでも
  //   落ちないようにする (以前は priceFor が null を返すと例外だった)。
  const spec =
    findLivePrice(await livePrices(env), model) || priceFor(model);
  if (!spec) return { ok: false, status: 400, detail: `unknown model: ${model}` };
  const key = providerKey(env, spec.provider);
  if (!key) {
    return { ok: false, status: 503, detail: `${spec.provider} key not set` };
  }

  if (spec.provider === 'gemini') {
    const r = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${key}`,
      {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          contents: [
            {
              parts: [
                // 画像を先に置くと、 後ろの指示文がその画像に掛かる。
                ...imgs.map((im) => ({
                  inline_data: { mime_type: im.mime, data: im.data },
                })),
                { text: prompt },
              ],
            },
          ],
        }),
      }
    );
    const d = await r.json();
    if (!r.ok) return { ok: false, status: 502, detail: d };
    const um = d?.usageMetadata ?? {};
    return {
      ok: true,
      text:
        d?.candidates?.[0]?.content?.parts?.map((p) => p.text || '').join('') ??
        '',
      inTok: Number(um.promptTokenCount || 0),
      outTok: Number(um.candidatesTokenCount || 0),
    };
  }

  if (spec.provider === 'openai') {
    // 上限トークンの指定名がモデル世代で違う。 新しい世代 (gpt-5 系など) は
    //   max_tokens を拒否し max_completion_tokens を要求する。 逆に古い世代は
    //   max_completion_tokens を知らない。 まず新しい方で投げ、 「その引数は
    //   使えない」 と言われた時だけ古い方でやり直す
    //   (= ChatGPT のモデルだけ upstream error になっていた原因)。
    // max_completion_tokens は「考えている分 (推論トークン)」 も含めて数える。
    //   4096 のままだと、 考えるだけで使い切って本文が空で返ってくる
    //   (= 返事が空の吹き出しになる原因)。 余裕を持たせ、 考え込み過ぎない
    //   ように指定もする。 上限を上げても課金は実際に使った分だけ。
    const roomy = Math.min(32000, Math.max(maxTokens, maxTokens * 4));
    // 画像がある時は content を断片の配列にする (data URL で渡す)。
    const userContent =
      imgs.length === 0
        ? prompt
        : [
            ...imgs.map((im) => ({
              type: 'image_url',
              image_url: { url: `data:${im.mime};base64,${im.data}` },
            })),
            { type: 'text', text: prompt },
          ];
    const ask = (field, extra) =>
      fetch('https://api.openai.com/v1/chat/completions', {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          Authorization: `Bearer ${key}`,
        },
        body: JSON.stringify({
          model,
          messages: [{ role: 'user', content: userContent }],
          [field]: field === 'max_completion_tokens' ? roomy : maxTokens,
          ...(extra || {}),
        }),
      });
    const errText = (d) => JSON.stringify(d?.error ?? d ?? '');
    // ① 新しい世代 + 推論ひかえめ
    let r = await ask('max_completion_tokens', { reasoning_effort: 'low' });
    let d = await r.json();
    // ② 推論の指定を受け付けないモデルなら、 それを外して
    if (!r.ok && errText(d).includes('reasoning_effort')) {
      r = await ask('max_completion_tokens');
      d = await r.json();
    }
    // ③ 古い世代なら max_tokens で
    if (!r.ok && errText(d).includes('max_completion_tokens')) {
      r = await ask('max_tokens');
      d = await r.json();
    }
    if (!r.ok) return { ok: false, status: 502, detail: d };
    let u = d?.usage ?? {};
    let choice = d?.choices?.[0];

    // 本文の取り出し。 content は文字列のこともあれば断片の配列のことも
    //   あり、 断られた時は refusal に入る。 どれも拾う。
    const pick = (c) => {
      const msg = c?.message ?? {};
      if (typeof msg.content === 'string' && msg.content.trim()) {
        return msg.content;
      }
      if (Array.isArray(msg.content)) {
        const joined = msg.content
          .map((part) => (typeof part === 'string' ? part : part?.text ?? ''))
          .join('');
        if (joined.trim()) return joined;
      }
      if (typeof msg.refusal === 'string' && msg.refusal.trim()) {
        return msg.refusal;
      }
      return '';
    };

    let text = pick(choice);

    // 中身だけ空 (finish_reason: stop) で返してくることがある。 予算切れでは
    //   ないので、 一度だけ「返事を書いて」 と念押しして取り直す。
    if (!text.trim() && choice?.finish_reason === 'stop') {
      const r2 = await fetch('https://api.openai.com/v1/chat/completions', {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          Authorization: `Bearer ${key}`,
        },
        body: JSON.stringify({
          model,
          messages: [
            { role: 'user', content: userContent },
            { role: 'assistant', content: '' },
            {
              role: 'user',
              content:
                'Your previous reply was empty. Reply now: either the next ' +
                'tool JSON, or the final short explanation. Do not reply ' +
                'with an empty message.',
            },
          ],
          max_completion_tokens: roomy,
        }),
      });
      const d2 = await r2.json();
      if (r2.ok) {
        const c2 = d2?.choices?.[0];
        const t2 = pick(c2);
        if (t2.trim()) {
          text = t2;
          choice = c2;
          // 課金は 2 回分を合算する (実際に 2 回呼んでいるので)。
          const u2 = d2?.usage ?? {};
          u = {
            prompt_tokens:
              Number(u.prompt_tokens || 0) + Number(u2.prompt_tokens || 0),
            completion_tokens:
              Number(u.completion_tokens || 0) +
              Number(u2.completion_tokens || 0),
          };
        }
      }
    }

    // それでも空なら、 黙って空の吹き出しを出さずに理由を返す。
    if (!text.trim()) {
      return {
        ok: false,
        status: 502,
        detail: {
          error: {
            message:
              `empty reply from ${model} ` +
              `(finish_reason: ${choice?.finish_reason ?? 'unknown'}, ` +
              `reasoning tokens: ` +
              `${u?.completion_tokens_details?.reasoning_tokens ?? '?'})`,
          },
        },
      };
    }
    return {
      ok: true,
      text,
      inTok: Number(u.prompt_tokens || 0),
      outTok: Number(u.completion_tokens || 0),
    };
  }

  // anthropic
  const r = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-api-key': key,
      'anthropic-version': '2023-06-01',
    },
    body: JSON.stringify({
      model,
      max_tokens: maxTokens,
      messages: [
        {
          role: 'user',
          content:
            imgs.length === 0
              ? prompt
              : [
                  ...imgs.map((im) => ({
                    type: 'image',
                    source: {
                      type: 'base64',
                      media_type: im.mime,
                      data: im.data,
                    },
                  })),
                  { type: 'text', text: prompt },
                ],
        },
      ],
    }),
  });
  const d = await r.json();
  if (!r.ok) return { ok: false, status: 502, detail: d };
  const u = d?.usage ?? {};
  return {
    ok: true,
    text: (d?.content ?? []).map((c) => c.text || '').join(''),
    inTok: Number(u.input_tokens || 0),
    outTok: Number(u.output_tokens || 0),
  };
}

// 上乗せ率 (= 1 割増し)。 アプリ側 kUsageMarkupRate と揃えること。
const MARKUP = 0.20;

// 使い過ぎの保険。 1 か月あたりの請求上限 (USD)。 超えたら断る。
const MONTHLY_HARD_CAP_USD = 50;

// Dev 枠 (= 決済を通さない枠) の月上限。 引き落としが無いぶん、 暴走すると
// そのままこちらの持ち出しになるので、 広めでも上限は必ず置く。
const DEV_MONTHLY_CAP_USD = 200;

// KV の権利情報 (プラン / Stripe 顧客 ID) を読む。 期限切れは free 扱い。
async function readEntitlement(env, uid) {
  const raw = await env.ENTITLEMENTS.get(uid);
  if (!raw) return null;
  let data;
  try {
    data = JSON.parse(raw);
  } catch {
    return null;
  }
  const now = Math.floor(Date.now() / 1000);
  if (data.currentPeriodEnd && now > Number(data.currentPeriodEnd) + 3 * 86400) {
    data.plan = 'free';
    data.status = 'expired';
  }
  return data;
}

function usageKey(uid, ym) {
  return `usage:${uid}:${ym}`;
}

function currentYm() {
  const d = new Date();
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}`;
}

async function readUsage(env, uid, ym) {
  const raw = await env.ENTITLEMENTS.get(usageKey(uid, ym));
  if (!raw) {
    return { inputTokens: 0, outputTokens: 0, costUsd: 0, billedUsd: 0 };
  }
  try {
    return JSON.parse(raw);
  } catch {
    return { inputTokens: 0, outputTokens: 0, costUsd: 0, billedUsd: 0 };
  }
}

async function handleAiGenerate(request, env) {
  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: 'invalid json' }, 400);
  }
  // ★ 本文の uid は信用しない。 トークンから取り出す。
  const uid = await authUid(request, env);
  if (!uid) return unauthorized();
  const prompt = String(body.prompt || '');
  const model = body.model && priceFor(body.model) ? body.model : DEFAULT_MODEL;
  let maxTokens = Number(body.maxTokens || 4096);
  if (!Number.isFinite(maxTokens)) maxTokens = 4096;
  maxTokens = Math.min(32000, Math.max(256, Math.round(maxTokens)));
  // ── 画像を一緒に渡せるようにする (= ユーザー要望: カメラで撮った写真を
  //    そのまま AI に見せたい)。 [{mime, data(base64)}] の配列。 ──
  const images = sanitizeInputImages(body.images);
  if (images === null) return json({ error: 'images too large' }, 413);
  if (!uid || (!prompt && images.length === 0)) {
    return json({ error: 'uid and prompt are required' }, 400);
  }

  const prices = await livePrices(env);
  const spec = findLivePrice(prices, model) || priceFor(model);
  if (!spec || !providerKey(env, spec.provider)) {
    return json({ error: 'relay not configured' }, 503);
  }

  // ── Dev 枠は残高を引かない (= 決済を通さずに AI を使える枠) ──
  //   使用量は普通に記録するので、 誰がどれだけ使ったかは後から分かる。
  const devEnt = isDevEntitlement(await readEntitlement(env, uid));

  // ── 残高の確認 (= 前払いクレジット) ──
  //   1 回の応答がどれだけ長くなるかは事前に分からないので、
  //   「最大出力まで使った場合の見積り」 を持っているかで判定する。
  //   これで残高を超える請求は発生しない。
  //   画像は文字数に出ないので、 1 枚あたりの目安トークンで足しておく
  //   (Gemini の 1 枚 ≒ 258〜1500 トークン。 多めに見積もって取りこぼさない)。
  const imageTokens = images.length * IMAGE_INPUT_TOKENS_EST;
  const worstCase = Math.max(
    (((prompt.length / 3.5 + imageTokens) / 1e6) * spec.input +
      (maxTokens / 1e6) * spec.output) *
      (1 + MARKUP),
    0.001
  );
  // ★ 先に「最大でかかる額」 を確保してから上流を呼ぶ。
  //   金庫 (Durable Object) の中で順番に処理されるので、 同時に何本来ても
  //   残高以上には使えない (= 以前は全部が素通りして持ち出しになり得た)。
  const held = devEnt
    ? null
    : await creditOp(env, uid, '/reserve', { usd: round6(worstCase) });
  if (held && held.ok === false) {
    return json(
      {
        error: 'insufficient credit',
        balanceUsd: held.credit.balanceUsd,
        neededUsd: round6(worstCase),
        packUsd: CREDIT_PACK_USD,
      },
      402
    );
  }
  const reserved = held && held.ok ? round6(worstCase) : 0;
  if (!held && !devEnt) {
    // 金庫が使えない環境 (binding 無し) では従来通りの事前確認。
    const credit = await readCredit(env, uid);
    if (credit.balanceUsd < worstCase) {
      return json(
        {
          error: 'insufficient credit',
          balanceUsd: credit.balanceUsd,
          neededUsd: round6(worstCase),
          packUsd: CREDIT_PACK_USD,
        },
        402
      );
    }
  }

  // 使い過ぎの保険 (月あたり)。 残高があっても、 ここで一旦止める。
  // Dev 枠は残高を引かない分、 暴走すると全額こちらの持ち出しになるので
  //   上限は残すが枠を広げる。
  const ym = currentYm();
  const used = await readUsage(env, uid, ym);
  const cap = devEnt ? DEV_MONTHLY_CAP_USD : MONTHLY_HARD_CAP_USD;
  if (used.billedUsd >= cap) {
    return json({ error: 'monthly cap reached', usage: used }, 429);
  }

  const res = await callProvider(env, model, prompt, maxTokens, images);
  if (!res.ok) {
    // 失敗したら確保した分をそのまま返す。
    if (reserved > 0) {
      await creditOp(env, uid, '/settle', { hold: reserved, actual: 0 });
    }
    return json({ error: 'upstream error', detail: res.detail }, res.status || 502);
  }

  const inTok = res.inTok;
  const outTok = res.outTok;
  const cost = (inTok / 1e6) * spec.input + (outTok / 1e6) * spec.output;
  const billed = round6(cost * (1 + MARKUP));

  // ── 確保した分を戻し、 実費だけを引く (精算) ──
  let spent;
  if (devEnt) {
    // Dev 枠: 引き落とさない。 残高はそのまま返す (画面表示のため)。
    spent = { ok: true, credit: await readCredit(env, uid) };
  } else if (reserved > 0) {
    const st = await creditOp(env, uid, '/settle', {
      hold: reserved,
      actual: billed,
      note: `${model}:${inTok}/${outTok}`,
    });
    spent = { ok: true, credit: st ? st.credit : await readCredit(env, uid) };
  } else {
    spent = await spendCredit(env, uid, billed, `${model}:${inTok}/${outTok}`);
    if (!spent.ok) {
      return json(
        {
          error: 'insufficient credit',
          balanceUsd: spent.credit.balanceUsd,
          neededUsd: billed,
          packUsd: CREDIT_PACK_USD,
        },
        402
      );
    }
  }

  const next = {
    inputTokens: used.inputTokens + inTok,
    outputTokens: used.outputTokens + outTok,
    costUsd: round6(used.costUsd + cost),
    billedUsd: round6(used.billedUsd + billed),
    updatedAt: new Date().toISOString(),
  };
  await env.ENTITLEMENTS.put(usageKey(uid, ym), JSON.stringify(next));

  return json({
    text: res.text,
    model,
    provider: spec.provider,
    usage: {
      inputTokens: inTok,
      outputTokens: outTok,
      costUsd: round6(cost),
      billedUsd: billed,
    },
    credit: {
      balanceUsd: spent.credit.balanceUsd,
      low: spent.credit.balanceUsd < CREDIT_LOW_USD,
      packUsd: CREDIT_PACK_USD,
    },
    monthly: next,
  });
}

// ─── 画像生成の代行 ────────────────────────────────────────────────────
//
// テキストと違いトークンではなく「1 枚いくら」 の課金なので、 枚数で数える。
// 原価は Google の画像モデルの公表値 (2026-08 時点)。 請求は +MARKUP。
const IMAGE_MODELS = {
  'gemini-2.5-flash-image': 0.039,
  'gemini-2.5-flash-image-preview': 0.039,
  'gemini-2.0-flash-preview-image-generation': 0.039,
};
const DEFAULT_IMAGE_MODEL = 'gemini-2.5-flash-image';

async function handleAiImage(request, env) {
  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: 'invalid json' }, 400);
  }
  const uid = await authUid(request, env);
  if (!uid) return unauthorized();
  const prompt = String(body.prompt || '');
  if (!prompt) return json({ error: 'prompt is required' }, 400);
  if (!env.GEMINI_API_KEY) return json({ error: 'relay not configured' }, 503);

  const wanted = IMAGE_MODELS[body.model] ? body.model : DEFAULT_IMAGE_MODEL;
  const cost = IMAGE_MODELS[wanted];
  const billed = round6(cost * (1 + MARKUP));

  // Dev 枠は残高を引かない (テキストと同じ扱い)。
  const devEnt = isDevEntitlement(await readEntitlement(env, uid));

  // 1 枚分を先に確保する (テキストと同じ理由)。
  const held = devEnt ? null : await creditOp(env, uid, '/reserve', { usd: billed });
  if (held && held.ok === false) {
    return json(
      {
        error: 'insufficient credit',
        balanceUsd: held.credit.balanceUsd,
        neededUsd: billed,
        packUsd: CREDIT_PACK_USD,
      },
      402
    );
  }
  const reserved = held && held.ok ? billed : 0;
  if (!held && !devEnt) {
    const credit = await readCredit(env, uid);
    if (credit.balanceUsd < billed) {
      return json(
        {
          error: 'insufficient credit',
          balanceUsd: credit.balanceUsd,
          neededUsd: billed,
          packUsd: CREDIT_PACK_USD,
        },
        402
      );
    }
  }

  const ym = currentYm();
  const used = await readUsage(env, uid, ym);
  if (used.billedUsd >= (devEnt ? DEV_MONTHLY_CAP_USD : MONTHLY_HARD_CAP_USD)) {
    return json({ error: 'monthly cap reached', usage: used }, 429);
  }

  // 使えるモデルを順に試す (提供状況がキー / リージョンで変わるため)。
  const order = [wanted, ...Object.keys(IMAGE_MODELS).filter((m) => m !== wanted)];
  let lastDetail = null;
  for (const model of order) {
    let r;
    try {
      r = await fetch(
        `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${env.GEMINI_API_KEY}`,
        {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({
            contents: [{ parts: [{ text: prompt }] }],
            generationConfig: { responseModalities: ['IMAGE', 'TEXT'] },
          }),
        }
      );
    } catch (e) {
      lastDetail = String(e);
      continue;
    }
    const j = await r.json().catch(() => null);
    if (!r.ok || !j) {
      lastDetail = (j && j.error && j.error.message) || `HTTP ${r.status}`;
      continue;
    }
    // 応答から画像パートを取り出す。
    let data = null;
    let mime = 'image/png';
    const parts =
      (j.candidates && j.candidates[0] && j.candidates[0].content &&
        j.candidates[0].content.parts) || [];
    for (const p of parts) {
      const inline = p.inlineData || p.inline_data;
      if (inline && inline.data) {
        data = inline.data;
        mime = inline.mimeType || inline.mime_type || mime;
        break;
      }
    }
    if (!data) {
      lastDetail = 'no image in response';
      continue;
    }

    // ── 成功したので精算する ──
    let spent;
    if (devEnt) {
      spent = { ok: true, credit: await readCredit(env, uid) };
    } else if (reserved > 0) {
      const st = await creditOp(env, uid, '/settle', {
        hold: reserved,
        actual: billed,
        note: `image:${model}`,
      });
      spent = { ok: true, credit: st ? st.credit : await readCredit(env, uid) };
    } else {
      spent = await spendCredit(env, uid, billed, `image:${model}`);
      if (!spent.ok) {
        return json(
          {
            error: 'insufficient credit',
            balanceUsd: spent.credit.balanceUsd,
            neededUsd: billed,
            packUsd: CREDIT_PACK_USD,
          },
          402
        );
      }
    }
    const next = {
      inputTokens: used.inputTokens,
      outputTokens: used.outputTokens,
      costUsd: round6(used.costUsd + cost),
      billedUsd: round6(used.billedUsd + billed),
      images: Number(used.images || 0) + 1,
      updatedAt: new Date().toISOString(),
    };
    await env.ENTITLEMENTS.put(usageKey(uid, ym), JSON.stringify(next));

    return json({
      imageBase64: data,
      mimeType: mime,
      model,
      usage: { images: 1, costUsd: round6(cost), billedUsd: billed },
      credit: {
        balanceUsd: spent.credit.balanceUsd,
        low: spent.credit.balanceUsd < CREDIT_LOW_USD,
        packUsd: CREDIT_PACK_USD,
      },
      monthly: next,
    });
  }
  // どのモデルでも作れなかった → 確保した分を返す。
  if (reserved > 0) {
    await creditOp(env, uid, '/settle', { hold: reserved, actual: 0 });
  }
  return json({ error: 'image generation failed', detail: lastDetail }, 502);
}

async function handleAiUsage(url, env, request) {
  const uid = await authUid(request, env);
  if (!uid) return unauthorized();
  const ym = url.searchParams.get('ym') || currentYm();
  const used = await readUsage(env, uid, ym);
  return json({ ym, markup: MARKUP, capUsd: MONTHLY_HARD_CAP_USD, ...used });
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: JSON_HEADERS });
}

async function stripeApiGet(env, path) {
  const r = await fetch(`https://api.stripe.com/v1/${path}`, {
    headers: { Authorization: `Bearer ${env.STRIPE_SECRET_KEY}` },
  });
  return r.json();
}

async function stripeApi(env, path, form) {
  const body = new URLSearchParams(form).toString();
  const r = await fetch(`https://api.stripe.com/v1/${path}`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${env.STRIPE_SECRET_KEY}`,
      'content-type': 'application/x-www-form-urlencoded',
    },
    body,
  });
  return r.json();
}

// ─── Stripe 署名検証 (HMAC-SHA256) ─────────────────────────────────────
// Stripe-Signature: t=1234567890,v1=abcdef...
async function verifyStripeSignature(payload, header, secret) {
  if (!secret || !header) return false;
  const parts = Object.fromEntries(
    header.split(',').map((kv) => {
      const i = kv.indexOf('=');
      return [kv.slice(0, i).trim(), kv.slice(i + 1).trim()];
    })
  );
  const t = parts.t;
  const v1 = parts.v1;
  if (!t || !v1) return false;

  // 5 分以上ずれた署名は拒否 (リプレイ対策)
  const age = Math.abs(Math.floor(Date.now() / 1000) - Number(t));
  if (!Number.isFinite(age) || age > 300) return false;

  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw',
    enc.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  const mac = await crypto.subtle.sign('HMAC', key, enc.encode(`${t}.${payload}`));
  const hex = [...new Uint8Array(mac)]
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');

  // タイミング攻撃を避けるため定数時間で比較
  if (hex.length !== v1.length) return false;
  let diff = 0;
  for (let i = 0; i < hex.length; i++) diff |= hex.charCodeAt(i) ^ v1.charCodeAt(i);
  return diff === 0;
}
