# -*- coding: utf-8 -*-
"""共同編集 (リアルタイム) の動作を、 アプリを触らずに確かめる道具。

アプリと同じ手順で Firestore REST を直接叩き、 参加者を 2 人ぶん
演じて「片方の編集がもう片方に届くか」 を見る。

  python tool/live_collab_check.py

★ 実アプリのページには一切触らない。 使い捨ての合言葉で
  published/{code}/doc/main を作り、 最後に消す。

対象コード: lib/providers/mind_map_provider.dart
  _livePush (76xxx) / _livePull (76653) / startLiveSession
"""
import io
import json
import os
import sys
import time
import urllib.error
import urllib.request

ENV = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   'env.json')

fails = 0
notes = []


def check(name, ok, extra=''):
    global fails
    mark = 'ok  ' if ok else 'FAIL'
    line = '  %s %s' % (mark, name)
    if extra:
        line += '  (%s)' % extra
    print(line)
    if not ok:
        fails += 1


def post(url, payload, headers=None):
    data = json.dumps(payload).encode('utf-8')
    req = urllib.request.Request(url, data=data, method='POST')
    req.add_header('Content-Type', 'application/json')
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode('utf-8'))


def req(url, token, method='GET', payload=None):
    data = json.dumps(payload).encode('utf-8') if payload is not None else None
    r = urllib.request.Request(url, data=data, method=method)
    r.add_header('Authorization', 'Bearer ' + token)
    if data:
        r.add_header('Content-Type', 'application/json')
    try:
        with urllib.request.urlopen(r, timeout=30) as res:
            body = res.read().decode('utf-8')
            return res.status, (json.loads(body) if body else {})
    except urllib.error.HTTPError as e:
        body = e.read().decode('utf-8')
        try:
            return e.code, json.loads(body)
        except Exception:
            return e.code, {'raw': body}


def field_for(node_id):
    """アプリの _liveFieldForNode と同じ規則。"""
    out = []
    for ch in node_id:
        out.append(ch if (ch.isalnum() and ord(ch) < 128) or ch == '_' else '_')
    return 'n_' + ''.join(out)


def main():
    cfg = json.load(io.open(ENV, encoding='utf-8'))
    project = cfg['FIREBASE_PROJECT_ID']
    api_key = (cfg.get('FIREBASE_API_KEY_REST') or
               cfg.get('FIREBASE_API_KEY_WINDOWS') or
               cfg.get('FIREBASE_API_KEY_ANDROID'))
    base = ('https://firestore.googleapis.com/v1/projects/%s/databases/'
            '(default)/documents' % project)

    print('== 参加者を 2 人ぶん用意する (匿名ログイン) ==')
    tokens = []
    for who in ('A', 'B'):
        j = post('https://identitytoolkit.googleapis.com/v1/accounts:signUp'
                 '?key=' + api_key, {'returnSecureToken': True})
        tokens.append(j['idToken'])
        print('  %s uid=%s' % (who, j['localId'][:10] + '...'))
    ta, tb = tokens

    # 使い捨ての合言葉 (実在のページとぶつからない印を付ける)。
    code = 'zzTEST%d' % (int(time.time()) % 100000)
    doc = '%s/published/%s/doc/main' % (base, code)
    print('  合言葉: %s' % code)
    node_id = 'test-node-0001'
    f = field_for(node_id)
    check('フィールド名の規則が一致', f == 'n_test_node_0001', f)

    try:
        # ── A が土台を作る ──
        print('\n== A が最初の内容を送る ==')
        rev1 = int(time.time() * 1000)
        st, _ = req(doc + '?updateMask.fieldPaths=%s'
                    '&updateMask.fieldPaths=rev'
                    '&updateMask.fieldPaths=lastActiveAt'
                    '&updateMask.fieldPaths=title' % f, ta, 'PATCH', {
                        'fields': {
                            f: {'stringValue': json.dumps(
                                {'id': node_id, 'title': 'A が作った',
                                 'x': 100.0, 'y': 200.0})},
                            'rev': {'integerValue': str(rev1)},
                            'lastActiveAt': {
                                'integerValue': str(int(time.time() * 1000))},
                            'title': {'stringValue': '検証用ページ'},
                        }})
        check('A の書き込みが通る', st == 200, 'HTTP %d' % st)

        # ── B が版だけを見に行く (アプリと同じ mask 読み) ──
        print('\n== B が版を見に行く (1.2 秒ごとの軽い読み取り) ==')
        st, j = req(doc + '?mask.fieldPaths=rev&mask.fieldPaths=lastActiveAt',
                    tb, 'GET')
        remote_rev = int(j.get('fields', {}).get('rev', {})
                         .get('integerValue', -1))
        check('版だけの読み取りが効く', st == 200 and remote_rev == rev1,
              'rev=%s' % remote_rev)
        got_active = 'lastActiveAt' in j.get('fields', {})
        check('最終活動時刻も取れる', got_active)
        # mask を付けた読みで中身が来ていない = 通信量の節約が効いている
        check('中身は含まれない (軽い読み)', f not in j.get('fields', {}))

        # ── B が中身を取る ──
        print('\n== B が中身を取り込む ==')
        st, j = req(doc, tb, 'GET')
        raw = j.get('fields', {}).get(f, {}).get('stringValue')
        node = json.loads(raw) if raw else {}
        check('A の作ったノードが B に届く',
              node.get('title') == 'A が作った', node.get('title'))

        # ── B が直して送り返す ──
        print('\n== B が直して送り返す ==')
        rev2 = int(time.time() * 1000)
        st, _ = req(doc + '?updateMask.fieldPaths=%s'
                    '&updateMask.fieldPaths=rev' % f, tb, 'PATCH', {
                        'fields': {
                            f: {'stringValue': json.dumps(
                                {'id': node_id, 'title': 'B が直した',
                                 'x': 300.0, 'y': 400.0})},
                            'rev': {'integerValue': str(rev2)},
                        }})
        check('B の書き込みが通る', st == 200, 'HTTP %d' % st)
        st, j = req(doc, ta, 'GET')
        raw = j.get('fields', {}).get(f, {}).get('stringValue')
        node = json.loads(raw) if raw else {}
        check('B の直しが A に届く',
              node.get('title') == 'B が直した', node.get('title'))
        check('位置も伝わる', node.get('x') == 300.0, node.get('x'))

        # ── 版が上がったことを A が気付けるか ──
        st, j = req(doc + '?mask.fieldPaths=rev', ta, 'GET')
        rev_now = int(j.get('fields', {}).get('rev', {})
                      .get('integerValue', -1))
        check('版が上がっている (A は再取得すると判断できる)',
              rev_now == rev2 and rev2 != rev1, '%s -> %s' % (rev1, rev_now))

        # ── 時計が遅れている端末の書き込みが埋もれないか ──
        # アプリは rev = max(now, 知っている版 + 1) にしている。
        print('\n== 時計が遅れている参加者の書き込み ==')
        behind = rev1 - 60 * 60 * 1000  # 1 時間遅れた時計
        app_rev = behind if behind > rev_now else rev_now + 1
        st, _ = req(doc + '?updateMask.fieldPaths=%s'
                    '&updateMask.fieldPaths=rev' % f, tb, 'PATCH', {
                        'fields': {
                            f: {'stringValue': json.dumps(
                                {'id': node_id, 'title': '時計が遅れた人',
                                 'x': 1.0, 'y': 2.0})},
                            'rev': {'integerValue': str(app_rev)},
                        }})
        check('遅れた時計でも版が前に進む', app_rev > rev_now,
              '%s -> %s' % (rev_now, app_rev))
        st, j = req(doc, ta, 'GET')
        raw = j.get('fields', {}).get(f, {}).get('stringValue')
        check('遅れた時計の書き込みも届く',
              json.loads(raw).get('title') == '時計が遅れた人')

        # ── ノードの削除 (フィールドを値なしで updateMask) ──
        print('\n== ノードを消す ==')
        rev3 = int(time.time() * 1000) + 1
        st, _ = req(doc + '?updateMask.fieldPaths=%s'
                    '&updateMask.fieldPaths=rev' % f, ta, 'PATCH',
                    {'fields': {'rev': {'integerValue': str(rev3)}}})
        check('削除の書き込みが通る', st == 200, 'HTTP %d' % st)
        st, j = req(doc, tb, 'GET')
        check('B 側からもノードが消える', f not in j.get('fields', {}))

        # ── 権限: 第三者が読み書きできてしまわないか ──
        print('\n== 規則の確認 (合言葉を知らない第三者) ==')
        j = post('https://identitytoolkit.googleapis.com/v1/accounts:signUp'
                 '?key=' + api_key, {'returnSecureToken': True})
        tc = j['idToken']
        st, _ = req(doc, tc, 'GET')
        third_read = (st == 200)
        st2, _ = req(doc + '?updateMask.fieldPaths=title', tc, 'PATCH',
                     {'fields': {'title': {'stringValue': '第三者が書いた'}}})
        third_write = (200 <= st2 < 300)
        if third_read or third_write:
            notes.append(
                '第三者 (合言葉を知らない別アカウント) が '
                '%s%s%s。 Firestore の規則が未設定のため、 合言葉が漏れると '
                '誰でも触れる。' % (
                    '読める' if third_read else '',
                    ' / ' if third_read and third_write else '',
                    '書ける' if third_write else ''))
        check('第三者の読み書きは規則で塞がれている',
              not third_read and not third_write,
              'read=%d write=%d' % (st, st2))

    finally:
        # 後始末 (実データではないが、 残さない)。
        req(doc, ta, 'DELETE')
        print('\n  後始末: %s を削除' % code)

    print('')
    for n in notes:
        print('  [注意] ' + n)
    print('\n%s' % ('ALL PASS' if fails == 0 else '%d FAILED' % fails))
    sys.exit(0 if fails == 0 else 1)


main()
