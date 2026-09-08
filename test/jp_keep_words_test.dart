// 語のまとまりの途中で改行されないようにする処理の確認
// (= ユーザー報告: 「要素」 が「要 / 素」、 「返す」 が「返 / す」 に割れる)。
//
// jpKeepWords は画面ファイルのトップレベル関数なので、 同じ実装をここに
// 写して振る舞いだけを確かめる (画面ファイルは import すると重すぎる)。
import 'package:flutter_test/flutter_test.dart';

const _joiner = '⁠';

String jpKeepWords(String text, {int maxRun = 12}) {
  if (text.isEmpty) return text;
  if (text.contains('```') || text.contains('\n|')) return text;
  bool isKanji(int c) => c >= 0x4E00 && c <= 0x9FFF;
  bool isHira(int c) => c >= 0x3040 && c <= 0x309F;
  bool isKata(int c) => (c >= 0x30A0 && c <= 0x30FF) || c == 0x30FC;
  bool isAlnum(int c) =>
      (c >= 0x30 && c <= 0x39) ||
      (c >= 0x41 && c <= 0x5A) ||
      (c >= 0x61 && c <= 0x7A) ||
      c == 0x5F;
  // 助詞は語の一部ではないので、 ここで切れてよい (「配列の要素」 は
  // 「配列 / の要素」 のように折り返せる)。
  const particles = 'のをにはがへともやかでねよ';
  bool isParticle(int c) => particles.contains(String.fromCharCode(c));

  final runes = text.runes.toList();
  final out = StringBuffer();
  var i = 0;
  while (i < runes.length) {
    final c = runes[i];
    var end = i + 1;
    if (isAlnum(c)) {
      while (end < runes.length && isAlnum(runes[end])) {
        end++;
      }
    } else if (isKata(c)) {
      while (end < runes.length && isKata(runes[end])) {
        end++;
      }
    } else if (isKanji(c)) {
      // 漢字の並び + 送り仮名 を繰り返し繋ぐ (「並べ替える」「書き込む」)。
      while (end < runes.length) {
        while (end < runes.length && isKanji(runes[end])) {
          end++;
        }
        var okuri = 0;
        while (end < runes.length &&
            isHira(runes[end]) &&
            !isParticle(runes[end]) &&
            okuri < 2) {
          end++;
          okuri++;
        }
        // 次がまた漢字なら同じ語の続きとみなす。 そうでなければ終わり。
        if (end < runes.length && isKanji(runes[end]) && end - i < maxRun) {
          continue;
        }
        break;
      }
    }
    final len = end - i;
    for (var k = i; k < end; k++) {
      out.writeCharCode(runes[k]);
      // まとまりの内側にだけ挟む。 長すぎる時は挟まない (はみ出し防止)。
      if (len > 1 && len <= maxRun && k < end - 1) out.write(_joiner);
    }
    i = end;
  }
  return out.toString();
}

/// 見やすさ用: 折り返してよい位置を | で表す。
String breaks(String s) {
  final out = StringBuffer();
  final r = s.runes.toList();
  for (var i = 0; i < r.length; i++) {
    if (r[i] == 0x2060) continue;
    out.writeCharCode(r[i]);
    final next = i + 1 < r.length ? r[i + 1] : -1;
    if (next != 0x2060 && i < r.length - 1) out.write('|');
  }
  return out.toString();
}

void main() {
  test('漢字の並びと送り仮名は割れない', () {
    expect(breaks(jpKeepWords('要素')), '要素');
    expect(breaks(jpKeepWords('返す')), '返す');
    // 漢字 + 送り仮名 が交互に続く語も 1 かたまりに保つ。
    expect(breaks(jpKeepWords('並べ替える')), '並べ替える');
    expect(breaks(jpKeepWords('書き込む')), '書き込む');
  });

  test('語と語のあいだでは折り返せる', () {
    final r = breaks(jpKeepWords('配列の要素をすべて返す'));
    // ignore: avoid_print
    print('WRAP $r');
    expect(r.contains('要素'), isTrue, reason: '要素 が割れている');
    expect(r.contains('配列'), isTrue, reason: '配列 が割れている');
    expect(r.contains('返す'), isTrue, reason: '返す が割れている');
    // 助詞の所では折り返せる (= どこでも折れないと画面からはみ出す)。
    expect(r.contains('|'), isTrue, reason: 'どこでも折れないのは行き過ぎ');
  });

  test('英数字とカタカナもまとまる', () {
    expect(breaks(jpKeepWords('alleven')), 'alleven');
    expect(breaks(jpKeepWords('ソート')), 'ソート');
  });

  test('長すぎる語は例外 (折り返せる)', () {
    const long = '超電磁砲式量子暗号通信基盤技術研究開発機構';
    final r = breaks(jpKeepWords(long));
    expect(r.contains('|'), isTrue, reason: '長い語は折れないとはみ出す');
  });

  test('コードや表はそのまま', () {
    const code = '```c\nint f(void) { return 0; }\n```';
    expect(jpKeepWords(code), code);
  });
}
