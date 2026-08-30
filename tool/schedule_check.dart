// 「時刻で実行」 の曜日・日付・複数時刻の判定を確かめる。
//
//   dart run tool/schedule_check.dart
//
// = ユーザー要望「複数時刻を指定したり、曜日や日付指定したりできるように」。
// ★ 判定は web_automation_panel.dart の中の private なので、
//   同じ規則をここに写して確かめる。 直す時は両方直すこと。
import 'dart:io';

String two(int v) => v.toString().padLeft(2, '0');
String hhmm(int m) => '${two(m ~/ 60)}:${two(m % 60)}';

/// その日に動かす日か (曜日と日付のしぼり込み)。
bool matchesDay(DateTime now, Set<int> days, Set<String> dates) {
  if (days.isNotEmpty && !days.contains(now.weekday)) return false;
  if (dates.isEmpty) return true;
  final md = '${two(now.month)}-${two(now.day)}';
  final ymd = '${now.year}-$md';
  return dates.contains(md) || dates.contains(ymd);
}

/// 1 日ぶんを回して、 何回・何時に動くかを数える。
List<String> firesOn(DateTime day, List<int> times, Set<int> days,
    Set<String> dates) {
  final fired = <String>[];
  final seen = <String>{};
  // 20 秒ごとの見回りを 1 日ぶん真似る。
  for (var sec = 0; sec < 24 * 60 * 60; sec += 20) {
    final now = DateTime(day.year, day.month, day.day).add(
        Duration(seconds: sec));
    final nowMin = now.hour * 60 + now.minute;
    if (!times.contains(nowMin)) continue;
    if (!matchesDay(now, days, dates)) continue;
    final key = '${now.year}-${two(now.month)}-${two(now.day)} '
        '${hhmm(nowMin)}';
    if (!seen.add(key)) continue;
    fired.add(hhmm(nowMin));
  }
  return fired;
}

int fails = 0;
void check(String what, bool ok, [String extra = '']) {
  stdout.writeln(
      '  ${ok ? "ok  " : "FAIL"} $what${extra.isEmpty ? '' : '  ($extra)'}');
  if (!ok) fails++;
}

void main() {
  // 2026-08-31 は月曜、 2026-09-05 は土曜。
  final mon = DateTime(2026, 8, 31);
  final sat = DateTime(2026, 9, 5);

  stdout.writeln('== 複数の時刻 ==');
  final t3 = [9 * 60, 12 * 60 + 30, 18 * 60 + 5];
  final f = firesOn(mon, t3, {}, {});
  check('1 日に 3 回とも動く', f.length == 3, f.join(' / '));
  check('時刻が合っている',
      f.join(',') == '09:00,12:30,18:05', f.join(','));

  stdout.writeln('\n== 二重に動かさない ==');
  // 同じ分をまたぐ見回りが 3 回あっても 1 回だけ。
  check('同じ分で 1 回だけ', firesOn(mon, [9 * 60], {}, {}).length == 1);

  stdout.writeln('\n== 曜日 ==');
  check('月曜だけ指定 → 月曜は動く',
      firesOn(mon, [9 * 60], {1}, {}).length == 1);
  check('月曜だけ指定 → 土曜は動かない',
      firesOn(sat, [9 * 60], {1}, {}).isEmpty);
  check('土日を指定 → 土曜は動く',
      firesOn(sat, [9 * 60], {6, 7}, {}).length == 1);
  check('選ばなければ毎日',
      firesOn(sat, [9 * 60], {}, {}).length == 1);

  stdout.writeln('\n== 日付 ==');
  check('その日だけ指定 → 合う日は動く',
      firesOn(mon, [9 * 60], {}, {'2026-08-31'}).length == 1);
  check('その日だけ指定 → 別の日は動かない',
      firesOn(sat, [9 * 60], {}, {'2026-08-31'}).isEmpty);
  check('毎年その日 (MM-DD) も効く',
      firesOn(mon, [9 * 60], {}, {'08-31'}).length == 1);
  check('日付を選ばなければ絞らない',
      firesOn(sat, [9 * 60], {}, {}).length == 1);

  stdout.writeln('\n== 曜日と日付の重ね合わせ ==');
  check('曜日が合わなければ日付が合っても動かない',
      firesOn(sat, [9 * 60], {1}, {'2026-09-05'}).isEmpty);
  check('両方合えば動く',
      firesOn(mon, [9 * 60], {1}, {'2026-08-31'}).length == 1);

  stdout.writeln('\n== 古い保存形からの読み替え ==');
  // {h:9, m:0, daily:true} → times=[540], days={}, repeat=true
  const oldH = 9, oldM = 0;
  final migrated = [oldH * 60 + oldM];
  check('9:00 の 1 つになる',
      migrated.length == 1 && migrated.first == 540, hhmm(migrated.first));
  check('毎日として動く', firesOn(sat, migrated, {}, {}).length == 1);

  stdout.writeln('\n${fails == 0 ? "ALL PASS" : "$fails FAILED"}');
  exit(fails == 0 ? 0 : 1);
}
