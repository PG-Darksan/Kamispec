# -*- coding: utf-8 -*-
"""本文 (published/{code}/body/main) の同時書き込みを、 条件付き書き込みで
防げるかを本物の Firestore で確かめる道具。

  python tool/live_body_race_check.py

★ 実アプリのページには一切触らない。 使い捨ての合言葉で作り、 最後に消す。

確かめること:
  1. updateTime を付けずに書くと、 相手の書き込みを黙って上書きできてしまう
     (= 今の実装。 両方が描くと片方の線が消える原因)。
  2. currentDocument.updateTime を付けると、 古い版を持つ側の書き込みが
     弾かれる (= その時に取り込んでから書き直せる)。 その時の HTTP の番号。
"""
import io
import json
import os
import sys
import time
import urllib.error
import urllib.request

sys.stdout.reconfigure(encoding='utf-8')
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
            raw = res.read().decode()
            return res.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {'raw': raw}


def main():
    cfg = json.load(io.open(ENV, encoding='utf-8'))
    key = (cfg.get('FIREBASE_API_KEY_REST') or cfg.get('FIREBASE_API_KEY_WINDOWS'))
    base = ('https://firestore.googleapis.com/v1/projects/%s/databases/'
            '(default)/documents' % cfg['FIREBASE_PROJECT_ID'])

    print('== 2 人ぶん用意する ==')
    who = []
    for n in ('A', 'B'):
        j = post('https://identitytoolkit.googleapis.com/v1/accounts:signUp'
                 '?key=' + key, {'returnSecureToken': True})
        who.append((j['idToken'], j['localId']))
        print('  %s %s...' % (n, j['localId'][:10]))
    (ta, ua), (tb, _ub) = who

    code = 'zzBODY%d' % (int(time.time()) % 100000)
    doc = '%s/published/%s/doc/main' % (base, code)
    body = '%s/published/%s/body/main' % (base, code)
    print('  合言葉: %s' % code)

    def mask(*f):
        return '?' + '&'.join('updateMask.fieldPaths=' + x for x in f)

    try:
        # A が土台を作る (規則が hostUid を見るので必ず先に)。
        st, _ = req(doc + mask('hostUid', 'access', 'editors', 'rev'), ta,
                    'PATCH', {'fields': {
                        'hostUid': {'stringValue': ua},
                        'access': {'stringValue': 'edit'},
                        'editors': {'arrayValue': {'values': []}},
                        'rev': {'integerValue': '1'}}})
        check('土台を作れる', st == 200, 'HTTP %d' % st)

        print('\n== 本文を A が書く ==')
        st, j = req(body + mask('body', 'rev'), ta, 'PATCH',
                    {'fields': {'body': {'stringValue': 'X+A'},
                                'rev': {'integerValue': '100'}}})
        check('A の本文が通る', st == 200, 'HTTP %d' % st)
        ut_a = j.get('updateTime')
        check('書き込みの応答に updateTime が入っている', bool(ut_a), str(ut_a))

        print('\n== 今のやり方 (条件なし) では、 B が黙って上書きできる ==')
        st, j2 = req(body + mask('body', 'rev'), tb, 'PATCH',
                     {'fields': {'body': {'stringValue': 'X+B'},
                                 'rev': {'integerValue': '101'}}})
        check('B の上書きが通ってしまう (= 直すべき挙動)', st == 200,
              'HTTP %d' % st)
        ut_b = j2.get('updateTime')
        st, j3 = req(body, ta)
        now = j3.get('fields', {}).get('body', {}).get('stringValue')
        check('A の本文が消えている', now == 'X+B', str(now))

        print('\n== 条件付き (currentDocument.updateTime) にすると弾ける ==')
        # A は自分が最後に見た版 (ut_a) を条件に書く → 既に B が書いたので弾かれる
        st, err = req(body + mask('body', 'rev') +
                      '&currentDocument.updateTime=' + ut_a, ta, 'PATCH',
                      {'fields': {'body': {'stringValue': 'X+A2'},
                                  'rev': {'integerValue': '102'}}})
        check('古い版を持つ側の書き込みは弾かれる', st != 200, 'HTTP %d' % st)
        print('    弾かれた時の中身: %s' % json.dumps(err)[:180])
        st, j4 = req(body, ta)
        still = j4.get('fields', {}).get('body', {}).get('stringValue')
        check('弾かれた時、 相手の本文は無事', still == 'X+B', str(still))

        # 取り込んでから (= 新しい updateTime で) 書き直せば通る
        st, j5 = req(body + mask('body', 'rev') +
                     '&currentDocument.updateTime=' + ut_b, ta, 'PATCH',
                     {'fields': {'body': {'stringValue': 'X+A+B'},
                                 'rev': {'integerValue': '103'}}})
        check('取り込み直してから書けば通る', st == 200, 'HTTP %d' % st)

        print('\n== まだ無い本文を「作る」 時の条件 ==')
        body2 = '%s/published/%s/body/other' % (base, code)
        st, _ = req(body2 + mask('body') + '&currentDocument.exists=false', ta,
                    'PATCH', {'fields': {'body': {'stringValue': 'first'}}})
        check('exists=false なら新規作成できる', st == 200, 'HTTP %d' % st)
        st, _ = req(body2 + mask('body') + '&currentDocument.exists=false', tb,
                    'PATCH', {'fields': {'body': {'stringValue': 'second'}}})
        check('既にある物へ exists=false は弾かれる', st != 200, 'HTTP %d' % st)
        req(body2, ta, 'DELETE')

    finally:
        req(body, ta, 'DELETE')
        req(doc, ta, 'DELETE')
        print('\n  後始末: %s を削除' % code)

    print('\n%s' % ('ALL PASS' if fails == 0 else '%d FAILED' % fails))
    sys.exit(0 if fails == 0 else 1)


main()
