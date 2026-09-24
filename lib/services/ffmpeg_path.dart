// ffmpeg の置き場を探す小さな道具。
//
// ★ 元は `lib/screens/mind_map_screen.dart` の中に置いてあったが、
//   自動操作のパネル (lib/widgets/web_automation_panel.dart) からも
//   「実行を録画する」 で要るようになった。 あちらから 101k 行の画面を
//   import すると輪 (循環参照) になるので、 葉っぱのファイルへ出した。
//   画面の側は同じ名前で再輸出しているので、 今までの呼び出しはそのまま。
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 同梱していない ffmpeg を置くアプリ専用フォルダー。
Future<Directory> ffmpegInstallDir() async {
  final base = await getApplicationSupportDirectory();
  final dir = Directory('${base.path}${Platform.pathSeparator}ffmpeg_bin');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

/// ffmpeg の実体を探す (アプリの隣 → アプリ専用フォルダー → PATH →
/// 定番の場所)。 見つからなければ null。
Future<String?> findFfmpegExe() async {
  if (Platform.isWindows) {
    // ★ まずアプリ本体の隣を見る (= 同梱した時に使えるように)。 ストア版は
    //   自動ダウンロードを落としてあるので、 同梱するならここに置く。
    try {
      final near = File('${File(Platform.resolvedExecutable).parent.path}'
          '${Platform.pathSeparator}ffmpeg.exe');
      if (await near.exists()) return near.path;
    } catch (_) {}
    try {
      final dir = await ffmpegInstallDir();
      final p = '${dir.path}${Platform.pathSeparator}ffmpeg.exe';
      if (await File(p).exists()) return p;
    } catch (_) {}
  }
  for (final c in ['ffmpeg', 'ffmpeg.exe']) {
    try {
      final r = await Process.run(c, ['-version']);
      if (r.exitCode == 0) return c;
    } catch (_) {}
  }
  if (Platform.isWindows) {
    for (final p in [
      r'C:\ffmpeg\bin\ffmpeg.exe',
      r'C:\Program Files\ffmpeg\bin\ffmpeg.exe',
    ]) {
      try {
        if (await File(p).exists()) return p;
      } catch (_) {}
    }
  }
  return null;
}
