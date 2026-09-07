// PC設定 (マウス感度 / スクリーンセーバー / スリープ) の読み書きを実測する。
//
//   dart run tool/pc_settings_probe.dart
//
// ★ 書き込みは「今の値をそのまま書き直す」 だけ。 利用者の設定は変えない。
// ★ 出力はファイルへ (Windows のコンソールは日本語で落ちる)。
import 'dart:io';

import 'package:mindmap_app/services/pc_settings.dart';

void main() {
  final b = StringBuffer();
  void say(String s) {
    b.writeln(s);
  }

  say('supported = ${PcSettings.isSupported}');

  final m = PcSettings.readMouse();
  say('mouse: speed=${m.speed} accel=${m.acceleration} '
      'wheel=${m.wheelLines} dblclick=${m.doubleClickMs}ms');
  say('  setMouseSpeed(same)      -> ${PcSettings.setMouseSpeed(m.speed)}');
  say('  setWheelScrollLines(same)-> '
      '${PcSettings.setWheelScrollLines(m.wheelLines < 1 ? 3 : m.wheelLines)}');
  say('  setDoubleClickTime(same) -> '
      '${PcSettings.setDoubleClickTime(m.doubleClickMs)}');
  say('  setMouseAcceleration(same)-> '
      '${PcSettings.setMouseAcceleration(m.acceleration)}');
  final m2 = PcSettings.readMouse();
  say('  再読み込み: speed=${m2.speed} accel=${m2.acceleration} '
      'wheel=${m2.wheelLines} dblclick=${m2.doubleClickMs}');

  final s = PcSettings.readScreenSaver();
  say('saver: active=${s.active} timeout=${s.timeoutSec}s '
      'secure=${s.secure} path="${s.path}"');
  say('  候補 ${s.choices.length} 件:');
  for (final c in s.choices) {
    say('    ${c.name}  <-  ${c.path}');
  }
  say('  setScreenSaverTimeout(same) -> '
      '${PcSettings.setScreenSaverTimeout(s.timeoutSec < 60 ? 60 : s.timeoutSec)}');

  final p = PcSettings.readPower();
  say('power: battery=${p.hasBattery}');
  say('  AC 画面を消す=${p.acDisplayOffSec}s スリープ=${p.acSleepSec}s');
  say('  DC 画面を消す=${p.dcDisplayOffSec}s スリープ=${p.dcSleepSec}s');
  say('  setPowerTimeout(AC, display, same) -> ${PcSettings.setPowerTimeout(
    onBattery: false,
    display: true,
    sec: p.acDisplayOffSec,
  )}');
  final p2 = PcSettings.readPower();
  say('  再読み込み: AC 画面=${p2.acDisplayOffSec}s スリープ=${p2.acSleepSec}s / '
      'DC 画面=${p2.dcDisplayOffSec}s スリープ=${p2.dcSleepSec}s');

  final out = File('build/pc_settings_probe.txt');
  out.parent.createSync(recursive: true);
  out.writeAsStringSync(b.toString());
  stdout.writeln('wrote ${out.path}');
}
