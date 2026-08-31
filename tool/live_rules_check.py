# -*- coding: utf-8 -*-
"""本番の Firestore 規則が、 共同編集の権限どおりに効いているかを確かめる。

  python tool/live_rules_check.py

★ 実データには触らない。 使い捨ての合言葉で published/{code} を作り、
  最後に消す。 エミュレータ (tool/rules_check.js) と同じ観点を本番で。
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


def check(name, ok, extra=''):
    global fails
    print('  %s %s%s' % ('ok  ' if ok else 'FAIL', name,
                         '' if not extra else '  (%s)' % extra))
    if not ok:
        fails += 1


def post(url, payload):
    r = urllib.request.Request(url, data=json.dumps(payload).encode(),
                               method='POST')
    r.add_header('Content-Type', 'application/json')
    return json.loads(urllib.request.urlopen(r, timeout=30).read().decode())


def req(url, token, method='GET', body=None):
    data = json.dumps(body).encode() if body else None
    r = urllib.request.Request(url, data=data, method=method)
    r.add_header('Authorization', 'Bearer ' + token)
    if data:
        r.add_header('Content-Type', 'application/json')
    try:
        with urllib.request.urlopen(r, timeout=30) as res:
            return res.status
    except urllib.error.HTTPError as e:
        return e.code


S = lambda v: {'stringValue': v}
I = lambda v: {'integerValue': str(v)}
A = lambda l: {'arrayValue': {'values': [S(x) for x in l]}}


def main():
    cfg = json.load(io.open(ENV, encoding='utf-8'))
    key = (cfg.get('FIREBASE_API_KEY_REST') or
           cfg.get('FIREBASE_API_KEY_WINDOWS'))
    base = ('https://firestore.googleapis.com/v1/projects/%s/databases/'
            '(default)/documents' % cfg['FIREBASE_PROJECT_ID'])

    print('== 3 人ぶん用意する ==')
    who = {}
    for n in ('host', 'member', 'other'):
        j = post('https://identitytoolkit.googleapis.com/v1/accounts:signUp'
                 '?key=' + key, {'returnSecureToken': True})
        who[n] = (j['idToken'], j['localId'])
        print('  %-7s %s...' % (n, j['localId'][:10]))
    (th, uh), (tm, um), (to, uo) = who['host'], who['member'], who['other']

    code = 'zzRULE%d' % (int(time.time()) % 100000)
    doc = '%s/published/%s/doc/main' % (base, code)
    peer = '%s/published/%s/peers/cid-m' % (base, code)
    print('  合言葉: %s' % code)

    def mask(*f):
        return '?' + '&'.join('updateMask.fieldPaths=' + x for x in f)

    try:
        print('\n== まとめて共有 (本文と hostUid を一度に書く) ==')
        # = ユーザー報告「まとめて共有でエラー (HTTP 403)」。
        #   土台がまだ無いページへの書き込みは「作成」 になるので、
        #   規則は hostUid が自分であることを求める。 本文だけ送ると弾かれる。
        bulk = '%s/published/zzBULK%s/doc/main' % (base, code)
        st = req(bulk + mask('n_a', 'connections', 'rev', 'title'), th,
                 'PATCH',
                 {'fields': {'n_a': S('{"id":"a"}'), 'connections': S('[]'),
                             'rev': I(1), 'title': S('マップ 2')}})
        check('hostUid を書かないと弾かれる (直す前の症状)', st == 403,
              'HTTP %d' % st)
        st = req(bulk + mask('n_a', 'connections', 'rev', 'title',
                             'hostUid', 'access', 'editors'), th, 'PATCH',
                 {'fields': {'n_a': S('{"id":"a"}'), 'connections': S('[]'),
                             'rev': I(1), 'title': S('マップ 2'),
                             'hostUid': S(uh), 'access': S('edit'),
                             'editors': A([])}})
        check('hostUid を一緒に書けば通る (直した形)', st == 200,
              'HTTP %d' % st)
        check('参加者がその中身を読める',
              req(bulk, tm) == 200)
        req(bulk, th, 'DELETE')

        print('\n== 公開者が土台を作る ==')
        st = req(doc + mask('hostUid', 'access', 'editors', 'rev'), th, 'PATCH',
                 {'fields': {'hostUid': S(uh), 'access': S('edit'),
                             'editors': A([]), 'rev': I(1)}})
        check('公開者は作れる', st == 200, 'HTTP %d' % st)

        st = req('%s/published/zzFAKE%s/doc/main' % (base, code) +
                 mask('hostUid'), to, 'PATCH',
                 {'fields': {'hostUid': S(uh)}})
        check('他人は公開者を偽れない', st == 403, 'HTTP %d' % st)

        print('\n== 「誰でも編集」 ==')
        st = req(doc + mask('n_a', 'rev'), tm, 'PATCH',
                 {'fields': {'n_a': S('{"id":"a"}'), 'rev': I(2)}})
        check('参加者は本文を書ける', st == 200, 'HTTP %d' % st)
        st = req(doc + mask('access'), tm, 'PATCH',
                 {'fields': {'access': S('view')}})
        check('参加者は権限を変えられない', st == 403, 'HTTP %d' % st)
        st = req(doc + mask('closed'), tm, 'PATCH',
                 {'fields': {'closed': {'booleanValue': True}}})
        check('参加者は公開を中止できない', st == 403, 'HTTP %d' % st)

        print('\n== 「全員閲覧のみ」 に変える ==')
        st = req(doc + mask('access'), th, 'PATCH',
                 {'fields': {'access': S('view')}})
        check('公開者は権限を変えられる', st == 200, 'HTTP %d' % st)
        st = req(doc + mask('n_b', 'rev'), tm, 'PATCH',
                 {'fields': {'n_b': S('{"id":"b"}'), 'rev': I(3)}})
        check('参加者は書けなくなる', st == 403, 'HTTP %d' % st)
        check('参加者は読める', req(doc, tm) == 200)

        print('\n== 「指定した人だけ編集」 ==')
        req(doc + mask('access', 'editors'), th, 'PATCH',
            {'fields': {'access': S('list'), 'editors': A([um])}})
        st = req(doc + mask('n_c', 'rev'), tm, 'PATCH',
                 {'fields': {'n_c': S('{"id":"c"}'), 'rev': I(4)}})
        check('選ばれた人は書ける', st == 200, 'HTTP %d' % st)
        st = req(doc + mask('n_d', 'rev'), to, 'PATCH',
                 {'fields': {'n_d': S('{"id":"d"}'), 'rev': I(5)}})
        check('選ばれていない人は書けない', st == 403, 'HTTP %d' % st)

        print('\n== 在席情報 ==')
        st = req(peer + mask('uid', 'name'), tm, 'PATCH',
                 {'fields': {'uid': S(um), 'name': S('m')}})
        check('自分の行は作れる', st == 200, 'HTTP %d' % st)
        st = req(peer + mask('lockNodeId'), to, 'PATCH',
                 {'fields': {'lockNodeId': S('steal')}})
        check('他人の札は奪えない', st == 403, 'HTTP %d' % st)

        print('\n== 公開の中止 ==')
        st = req(doc + mask('closed', 'rev'), th, 'PATCH',
                 {'fields': {'closed': {'booleanValue': True}, 'rev': I(9)}})
        check('公開者は中止できる', st == 200, 'HTTP %d' % st)
    finally:
        req(peer, th, 'DELETE')
        req(doc, th, 'DELETE')
        print('\n  後始末: %s を削除' % code)

    print('\n%s' % ('ALL PASS' if fails == 0 else '%d FAILED' % fails))
    sys.exit(0 if fails == 0 else 1)


main()
