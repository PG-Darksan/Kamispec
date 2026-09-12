// ── Windows で「2 つ目の窓が設定を潰す」 のを止めるための差し替え ──
//
// 標準の `shared_preferences_windows` は、 設定ファイルを **プロセスごとに
// 1 回しか**読まない (`_cachedPreferences ??= await _readFromFile(...)`)。
// `prefs.reload()` を呼んでも、 その古い控えを配り直すだけなので、 別の窓
// (= 別プロセス) が書いた内容は**永久に見えない**。 しかも 1 つ鍵を書く度に
// 控えを**丸ごと**書き戻すので、 相手が後から書いた鍵 (書類そのものを持つ
// `mindmap_pages_v4_coordinated` を含む) がまとめて消える。
//
// その結果、 本体を 2 つ立ち上げて片方で編集すると、 もう片方の保存で
// 書類が巻き戻ったり、 ページごと消えたりしていた
// (= ユーザー報告: 複数ウィンドウで編集するとデータに不整合が起こる)。
//
// ここでは控えを持たない実装に差し替える:
//   * 読む時は必ずファイルを読み直す (= `reload()` が本当に効く)
//   * 書く時は「OS のロックを取る → 読み直す → その 1 鍵だけ変える →
//     書き戻す」 (= 相手の書き込みを消さない)
//   * 書き込みは一時ファイル + 置き換えで行う (= 途中で落ちても壊れない)
//
// 書き込み 1 回につきファイルの読みが 1 回増えるが、 元々**全文の書き直し**
// をしているので釣り合いは取れる。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

const String _kDefaultPrefix = 'flutter.';
const String _kFileName = 'shared_preferences.json';

/// 控えを持たない Windows 用の設定ストア。
///
/// [registerIfWindows] を **`SharedPreferences` を触るより前**に呼ぶ
/// (= `main()` の頭)。 それ以降の `SharedPreferences` は全部こちらを通る。
class FreshSharedPreferencesWindows extends SharedPreferencesStorePlatform {
  /// Windows の時だけ差し替える。 他の OS は素のままで良い
  /// (Android/iOS は OS 側が同時書き込みを面倒見るし、 そもそも本体を
  ///  2 つ立ち上げられない)。
  static void registerIfWindows() {
    if (kIsWeb || !Platform.isWindows) return;
    SharedPreferencesStorePlatform.instance = FreshSharedPreferencesWindows();
  }

  /// 同じプロセスの中で読み書きが重ならないようにする鎖。
  Future<void> _chain = Future<void>.value();

  /// 置き場所は標準実装と同じ (= 今までの設定をそのまま引き継ぐ)。
  File? _file;

  Future<File> _dataFile() async {
    final cached = _file;
    if (cached != null) return cached;
    final dir = await getApplicationSupportDirectory();
    if (!await dir.exists()) await dir.create(recursive: true);
    final f = File('${dir.path}${Platform.pathSeparator}$_kFileName');
    _file = f;
    return f;
  }

  /// 書き換えの間だけ握る鍵。 設定ファイルとは別ファイルにする
  /// (本体を掴んだままだと置き換えができない)。
  Future<File> _lockFile() async {
    final data = await _dataFile();
    return File('${data.path}.lock');
  }

  /// 読み書きを 1 本の列にする。 待っている間に相手が終わるのを待つだけで、
  /// 例外が出ても列は止めない。
  Future<T> _serialize<T>(Future<T> Function() body) {
    final done = Completer<T>();
    _chain = _chain.then<void>((_) async {
      try {
        done.complete(await body());
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  /// 他のプロセスと取り合わないよう、 OS のファイルロックを取る。
  ///
  /// ★ 無期限に待たない。 異常終了したプロセスが握ったままだと、 次に
  ///   起動したアプリが設定を読めずに起動できなくなる。 諦めた時は
  ///   ロック無しで進む (最悪、 その 1 回の書き込みが競合するだけ)。
  Future<RandomAccessFile?> _acquire() async {
    try {
      final handle = await (await _lockFile()).open(mode: FileMode.append);
      try {
        await handle
            .lock(FileLock.blockingExclusive)
            .timeout(const Duration(seconds: 5));
        return handle;
      } on TimeoutException {
        debugPrint('prefs lock timed out; continuing without the lock');
        try {
          await handle.close();
        } catch (_) {}
        return null;
      }
    } catch (e) {
      debugPrint('prefs lock failed: $e');
      return null;
    }
  }

  Future<void> _release(RandomAccessFile? handle) async {
    if (handle == null) return;
    try {
      await handle.unlock();
    } catch (_) {}
    try {
      await handle.close();
    } catch (_) {}
  }

  /// ファイルから読み直す。 壊れていた / 無い時は空を返す (= 素の実装と同じ)。
  Future<Map<String, Object>> _readFresh() async {
    try {
      final f = await _dataFile();
      if (!await f.exists()) return <String, Object>{};
      final raw = await f.readAsString();
      if (raw.isEmpty) return <String, Object>{};
      final data = json.decode(raw);
      if (data is Map) return data.cast<String, Object>();
    } catch (e) {
      debugPrint('prefs read failed: $e');
    }
    return <String, Object>{};
  }

  /// 一時ファイルへ書いてから置き換える (= 途中で落ちても元が残る)。
  Future<bool> _writeAll(Map<String, Object> prefs) async {
    try {
      final f = await _dataFile();
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(json.encode(prefs), flush: true);
      try {
        await tmp.rename(f.path);
      } on FileSystemException {
        // 置き換えに失敗する環境 (ウイルス対策ソフトが掴んでいる等) では
        // 直接書きに落とす。
        await f.writeAsString(json.encode(prefs), flush: true);
        try {
          await tmp.delete();
        } catch (_) {}
      }
      return true;
    } catch (e) {
      debugPrint('prefs write failed: $e');
      return false;
    }
  }

  /// 「ロックを取る → 読み直す → 変える → 書き戻す」 をひと続きで行う。
  Future<bool> _mutate(void Function(Map<String, Object> prefs) change) {
    return _serialize<bool>(() async {
      final lock = await _acquire();
      try {
        final prefs = await _readFresh();
        change(prefs);
        return await _writeAll(prefs);
      } finally {
        await _release(lock);
      }
    });
  }

  @override
  Future<bool> clear() => clearWithParameters(
        ClearParameters(filter: PreferencesFilter(prefix: _kDefaultPrefix)),
      );

  @override
  Future<bool> clearWithPrefix(String prefix) => clearWithParameters(
        ClearParameters(filter: PreferencesFilter(prefix: prefix)),
      );

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) {
    final filter = parameters.filter;
    return _mutate((prefs) {
      prefs.removeWhere((key, _) =>
          key.startsWith(filter.prefix) &&
          (filter.allowList == null || filter.allowList!.contains(key)));
    });
  }

  @override
  Future<Map<String, Object>> getAll() => getAllWithParameters(
        GetAllParameters(filter: PreferencesFilter(prefix: _kDefaultPrefix)),
      );

  @override
  Future<Map<String, Object>> getAllWithPrefix(String prefix) =>
      getAllWithParameters(
        GetAllParameters(filter: PreferencesFilter(prefix: prefix)),
      );

  @override
  Future<Map<String, Object>> getAllWithParameters(
      GetAllParameters parameters) {
    final filter = parameters.filter;
    return _serialize<Map<String, Object>>(() async {
      final prefs = await _readFresh();
      prefs.removeWhere((key, _) => !(key.startsWith(filter.prefix) &&
          (filter.allowList?.contains(key) ?? true)));
      return prefs;
    });
  }

  @override
  Future<bool> remove(String key) => _mutate((prefs) => prefs.remove(key));

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    return _serialize<bool>(() async {
      final lock = await _acquire();
      try {
        final prefs = await _readFresh();
        // 同じ値を書き直さない (= 設定を少し触る度に、 書類ごと
        // 全文を書き戻すのを避ける)。
        if (_sameValue(prefs[key], value)) return true;
        prefs[key] = value;
        return await _writeAll(prefs);
      } finally {
        await _release(lock);
      }
    });
  }

  /// 設定の値が同じか。 並び (StringList) は中身で見る。
  static bool _sameValue(Object? a, Object? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    }
    return a == b;
  }
}
