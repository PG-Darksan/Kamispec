// 加速の曲線を引き伸ばす計算の見張り。
//
// ここは **利用者のレジストリに書き込む**値を作る所で、 しかも効くのは
// サインインし直した後。 間違えると「次に入った時にポインターが操作不能」
// という戻しにくい壊れ方をするので、 計算だけ切り出して測る。
//
// 曲線は 5 点 x 8 バイト。 各点の**先頭 4 バイト**が 16.16 の固定小数で、
// 残りの 4 バイトは常に 0 (Windows の決まり)。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mindmap_app/services/pc_settings.dart';

/// 16.16 の固定小数を実数に直す。
double _fx(Uint8List b, int i) =>
    (b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24)) / 65536.0;

void main() {
  // Windows の資料に載っている折れ点 (96 DPI):
  //   0 / 1.37 / 5.30001 / 24.30001 / 568
  final sample = Uint8List.fromList(const <int>[
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
    0xb8, 0x5e, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, //
    0xcd, 0x4c, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, //
    0xcd, 0x4c, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, //
    0x00, 0x00, 0x38, 0x02, 0x00, 0x00, 0x00, 0x00, //
  ]);

  test('もとの並びを 16.16 として読めている', () {
    expect(_fx(sample, 0), closeTo(0, 0.001));
    expect(_fx(sample, 8), closeTo(1.37, 0.001));
    expect(_fx(sample, 16), closeTo(5.30001, 0.001));
    expect(_fx(sample, 24), closeTo(24.30001, 0.001));
    expect(_fx(sample, 32), closeTo(568, 0.001));
  });

  test('200% で全部 2 倍・長さと詰め物はそのまま', () {
    final out = PcSettings.debugScaleCurve(sample, 200);
    expect(out.length, 40, reason: '40 バイトでないと Windows が読まない');
    for (var i = 0; i + 8 <= out.length; i += 8) {
      expect(_fx(out, i), closeTo(_fx(sample, i) * 2, 0.01));
      // 後ろ 4 バイトは 0 のまま。
      for (var k = 4; k < 8; k++) {
        expect(out[i + k], 0, reason: '詰め物を壊している (i=$i k=$k)');
      }
    }
  });

  test('100% は元のまま', () {
    expect(PcSettings.debugScaleCurve(sample, 100), sample);
  });

  test('何度掛けても積み重ならない (毎回 控えが土台)', () {
    // 画面側は「控え x 倍率」 で毎回作り直す。 その前提を固定しておく。
    final a = PcSettings.debugScaleCurve(sample, 150);
    final b = PcSettings.debugScaleCurve(sample, 150);
    expect(a, b);
    // 150% を土台にもう一度 150% を掛けると 225% = 積み重なる。
    // これは「やってはいけない使い方」 の見本。
    final wrong = PcSettings.debugScaleCurve(a, 150);
    expect(_fx(wrong, 32), closeTo(568 * 2.25, 1.0));
  });

  test('感度の倍率表: 10 が等倍、 20 が 3.5 倍', () {
    expect(PcSettings.mouseSpeedFactor(10), 1.0);
    expect(PcSettings.mouseSpeedFactor(20), 3.5);
    expect(PcSettings.mouseSpeedFactor(1), closeTo(1 / 32, 1e-9));
    expect(PcSettings.mouseSpeedFactor(3), closeTo(1 / 8, 1e-9));
    expect(PcSettings.mouseSpeedFactor(4), closeTo(2 / 8, 1e-9));
    expect(PcSettings.mouseSpeedFactor(6), closeTo(0.5, 1e-9));
    // 範囲の外は端に丸める。
    expect(PcSettings.mouseSpeedFactor(0), PcSettings.mouseSpeedFactor(1));
    expect(PcSettings.mouseSpeedFactor(99), 3.5);
  });
}
