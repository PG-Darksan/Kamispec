/**
 * Firestore の規則を、 本番に触れずに確かめる。
 *
 *   npx firebase emulators:exec --only firestore "node tool/rules_check.js"
 *
 * 共同編集 (published) の権限が、 アプリの作りと合っているかを見る。
 *   公開した人  … いつでも書ける / 権限を変えられる / 中止できる
 *   参加者      … 「誰でも編集」 なら書ける。 権限そのものは触れない
 *   選ばれた人  … 「指定した人だけ」 の名簿に居れば書ける
 *   それ以外    … 読めるだけ
 */
const PROJECT = 'rules-check';
const HOST = process.env.FIRESTORE_EMULATOR_HOST || '127.0.0.1:8080';
const BASE = `http://${HOST}/v1/projects/${PROJECT}/databases/(default)/documents`;

let fails = 0;
function check(name, ok, extra = '') {
  console.log(`  ${ok ? 'ok  ' : 'FAIL'} ${name}${extra ? `  (${extra})` : ''}`);
  if (!ok) fails++;
}

/** エミュレータは Bearer owner で規則を素通りできる。 利用者は自作トークン。 */
function tokenFor(uid) {
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const header = b64({ alg: 'none', typ: 'JWT' });
  const now = Math.floor(Date.now() / 1000);
  const payload = b64({
    iss: `https://securetoken.google.com/${PROJECT}`,
    aud: PROJECT,
    auth_time: now, user_id: uid, sub: uid, iat: now, exp: now + 3600,
    firebase: { identities: {}, sign_in_provider: 'anonymous' },
  });
  return `${header}.${payload}.`;
}

async function req(path, { uid, method = 'GET', body, mask } = {}) {
  let url = BASE + path;
  if (mask) url += (url.includes('?') ? '&' : '?') +
    mask.map((m) => `updateMask.fieldPaths=${m}`).join('&');
  const res = await fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${uid === 'owner' ? 'owner' : tokenFor(uid)}`,
      'Content-Type': 'application/json',
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  return res.status;
}

const S = (v) => ({ stringValue: v });
const I = (v) => ({ integerValue: String(v) });
const A = (list) => ({ arrayValue: { values: list.map(S) } });

async function main() {
  const HOST_UID = 'host-1', MEMBER = 'member-1', OTHER = 'other-1';
  const code = 'CODE1234';
  const doc = `/published/${code}/doc/main`;

  console.log('== 公開した人が土台を作る ==');
  check('公開者は hostUid 付きで作れる',
    (await req(doc, {
      uid: HOST_UID, method: 'PATCH',
      mask: ['hostUid', 'access', 'editors', 'rev'],
      body: { fields: { hostUid: S(HOST_UID), access: S('edit'), editors: A([]), rev: I(1) } },
    })) === 200);

  check('他人は自分を公開者と偽って作れない',
    (await req(`/published/OTHERCODE/doc/main`, {
      uid: OTHER, method: 'PATCH', mask: ['hostUid'],
      body: { fields: { hostUid: S(HOST_UID) } },
    })) === 403);

  console.log('\n== 「誰でも編集」 のとき ==');
  check('参加者は本文を書ける',
    (await req(doc, {
      uid: MEMBER, method: 'PATCH', mask: ['n_a', 'rev'],
      body: { fields: { n_a: S('{"id":"a"}'), rev: I(2) } },
    })) === 200);
  check('参加者は権限を書き換えられない',
    (await req(doc, {
      uid: MEMBER, method: 'PATCH', mask: ['access'],
      body: { fields: { access: S('view') } },
    })) === 403);
  check('参加者は公開を中止できない',
    (await req(doc, {
      uid: MEMBER, method: 'PATCH', mask: ['closed'],
      body: { fields: { closed: { booleanValue: true } } },
    })) === 403);
  check('参加者は公開者を乗っ取れない',
    (await req(doc, {
      uid: MEMBER, method: 'PATCH', mask: ['hostUid'],
      body: { fields: { hostUid: S(MEMBER) } },
    })) === 403);

  console.log('\n== 「全員閲覧のみ」 に変えたとき ==');
  check('公開者は権限を変えられる',
    (await req(doc, {
      uid: HOST_UID, method: 'PATCH', mask: ['access'],
      body: { fields: { access: S('view') } },
    })) === 200);
  check('参加者は書けなくなる',
    (await req(doc, {
      uid: MEMBER, method: 'PATCH', mask: ['n_b', 'rev'],
      body: { fields: { n_b: S('{"id":"b"}'), rev: I(3) } },
    })) === 403);
  check('参加者は読める', (await req(doc, { uid: MEMBER })) === 200);
  check('公開者は書ける',
    (await req(doc, {
      uid: HOST_UID, method: 'PATCH', mask: ['n_c', 'rev'],
      body: { fields: { n_c: S('{"id":"c"}'), rev: I(4) } },
    })) === 200);

  console.log('\n== 「指定した人だけ編集」 のとき ==');
  await req(doc, {
    uid: HOST_UID, method: 'PATCH', mask: ['access', 'editors'],
    body: { fields: { access: S('list'), editors: A([MEMBER]) } },
  });
  check('選ばれた人は書ける',
    (await req(doc, {
      uid: MEMBER, method: 'PATCH', mask: ['n_d', 'rev'],
      body: { fields: { n_d: S('{"id":"d"}'), rev: I(5) } },
    })) === 200);
  check('選ばれていない人は書けない',
    (await req(doc, {
      uid: OTHER, method: 'PATCH', mask: ['n_e', 'rev'],
      body: { fields: { n_e: S('{"id":"e"}'), rev: I(6) } },
    })) === 403);

  console.log('\n== 公開の中止 ==');
  check('公開者は中止の印を書ける',
    (await req(doc, {
      uid: HOST_UID, method: 'PATCH', mask: ['closed', 'rev'],
      body: { fields: { closed: { booleanValue: true }, rev: I(7) } },
    })) === 200);

  console.log('\n== 参加者の在席情報 ==');
  const peer = `/published/${code}/peers/cid-member`;
  check('自分の行は作れる',
    (await req(peer, {
      uid: MEMBER, method: 'PATCH', mask: ['uid', 'name'],
      body: { fields: { uid: S(MEMBER), name: S('member') } },
    })) === 200);
  check('他人になりすませない',
    (await req(`/published/${code}/peers/cid-fake`, {
      uid: OTHER, method: 'PATCH', mask: ['uid', 'name'],
      body: { fields: { uid: S(MEMBER), name: S('fake') } },
    })) === 403);
  check('他人の行は書き換えられない',
    (await req(peer, {
      uid: OTHER, method: 'PATCH', mask: ['lockNodeId'],
      body: { fields: { lockNodeId: S('steal') } },
    })) === 403);
  check('離席した人の行は掃除できる',
    (await req(peer, { uid: OTHER, method: 'DELETE' })) === 200);

  console.log('\n== ほかの所が壊れていないか ==');
  check('他人の users は読めない',
    (await req(`/users/${HOST_UID}`, { uid: OTHER })) === 403);
  check('自分の users は書ける',
    (await req(`/users/${OTHER}`, {
      uid: OTHER, method: 'PATCH', mask: ['displayName'],
      body: { fields: { displayName: S('me') } },
    })) === 200);
  check('users の一覧は取れない',
    (await req('/users?pageSize=1', { uid: OTHER })) === 403);

  console.log(`\n${fails === 0 ? 'ALL PASS' : `${fails} FAILED`}`);
  process.exit(fails === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
