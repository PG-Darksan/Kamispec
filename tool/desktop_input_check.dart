// パソコンの操作 (desktop_input.dart) が本当に効くかを確かめる道具。
//
//   dart run tool/desktop_input_check.dart
//
// ★ なぜ要るか: SendInput へ渡す INPUT 構造体は、 並び (オフセット) を
//   1 つでも間違えると「動くけれど違う所を押す」 という一番たちの悪い
//   壊れ方をする。 アプリから試すと本物の画面を触ってしまうので、
//   ここでは**マウスを動かして座標を読み戻すだけ**にして、 押さない。
//
// 触るもの: マウスの位置だけ (最後に元へ戻す)。 クリックも入力もしない。
import 'dart:io';

import 'package:mindmap_app/services/desktop_input.dart';

int fails = 0;
void check(String what, bool ok, [String extra = '']) {
  stdout.writeln('  ${ok ? "ok  " : "FAIL"} $what${extra.isEmpty ? '' : '  ($extra)'}');
  if (!ok) fails++;
}

Future<void> main() async {
  if (!Platform.isWindows) {
    stdout.writeln('Windows 専用の道具です。');
    exit(0);
  }

  stdout.writeln('== 画面の大きさ ==');
  final b = DesktopInput.screenBounds();
  check('取れる', b.width > 0 && b.height > 0,
      '${b.width}x${b.height} @(${b.x},${b.y})');

  stdout.writeln('\n== 開いている窓 ==');
  final wins = DesktopInput.listWindows();
  check('1 つ以上見つかる', wins.isNotEmpty, '${wins.length} 個');
  for (final w in wins.take(5)) {
    stdout.writeln('       - ${w.title}');
  }

  stdout.writeln('\n== 許していない間は動かない (安全弁) ==');
  final before = DesktopInput.cursorPos();
  check('今の位置が読める', before != null, '${before?.x},${before?.y}');
  DesktopInput.enabled = false;
  final blocked = DesktopInput.moveTo(
      (b.x + b.width ~/ 3), (b.y + b.height ~/ 3));
  check('enabled=false では動かない', !blocked);
  final afterBlocked = DesktopInput.cursorPos();
  check('位置も変わっていない',
      afterBlocked?.x == before?.x && afterBlocked?.y == before?.y,
      '${afterBlocked?.x},${afterBlocked?.y}');

  stdout.writeln('\n== 許した時だけ動く (座標の正しさ) ==');
  DesktopInput.enabled = true;
  // 画面の真ん中あたりへ動かして、 読み戻して確かめる。
  final targets = <(int, int)>[
    (b.x + b.width ~/ 2, b.y + b.height ~/ 2),
    (b.x + b.width ~/ 4, b.y + b.height ~/ 4),
  ];
  for (final (tx, ty) in targets) {
    final ok = DesktopInput.moveTo(tx, ty);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    final now = DesktopInput.cursorPos();
    // SendInput の絶対座標は 0..65535 の目盛りなので、 1〜2px はずれる。
    final dx = ((now?.x ?? -9999) - tx).abs();
    final dy = ((now?.y ?? -9999) - ty).abs();
    check('($tx,$ty) へ動かせる', ok && dx <= 2 && dy <= 2,
        '着いた先=(${now?.x},${now?.y}) ずれ=($dx,$dy)');
  }

  // 元の位置へ戻す (使っている人の邪魔をしない)。
  if (before != null) {
    DesktopInput.moveTo(before.x, before.y);
  }
  DesktopInput.enabled = false;

  stdout.writeln('\n== 後始末 ==');
  final restored = DesktopInput.cursorPos();
  check('マウスを元の位置に戻した',
      before == null ||
          (((restored?.x ?? 0) - before.x).abs() <= 2 &&
              ((restored?.y ?? 0) - before.y).abs() <= 2),
      '${restored?.x},${restored?.y}');
  check('安全弁を閉じ直した', DesktopInput.enabled == false);

  stdout.writeln('\n${fails == 0 ? "ALL PASS" : "$fails FAILED"}');
  exit(fails == 0 ? 0 : 1);
}
