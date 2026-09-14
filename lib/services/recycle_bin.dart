// ファイル / フォルダーを「ごみ箱」 へ送る。
//
// = ユーザー要望「手動でも消すことができないのが変だから、 手動では消したり
//   複数選択できるようにして欲しい」。
//
// ★ 消し方は **ごみ箱へ送る** を第一にする。 一覧に出ているのは利用者自身の
//   デスクトップや書類の中身なので、 取り返しが付かない消し方は選ばない。
// ★ Windows は `SHFileOperationW` に `FOF_ALLOWUNDO` を渡すのが唯一の
//   「ごみ箱へ入れる」 道 (Dart の `File.delete()` はごみ箱を通らない)。
//   渡す道筋は **2 つの NUL で終える**決まりなので、 自分で組み立てる。
// ★ Windows 以外と、 ごみ箱へ送れなかった時は、 呼ぶ側に知らせて
//   「完全に消してよいか」 を改めてたずねてもらう (黙って消さない)。
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart' as w32;

/// ごみ箱へ送った結果。
enum RecycleResult {
  /// ごみ箱へ入った。
  recycled,

  /// この環境にはごみ箱へ送る道が無い (Windows 以外)。
  unsupported,

  /// 道はあるが失敗した (使用中 / 権限が無い など)。
  failed,
}

class RecycleBin {
  RecycleBin._();

  /// この環境でごみ箱へ送れるか。
  static bool get isSupported => !kIsWeb && Platform.isWindows;

  /// [paths] をまとめてごみ箱へ送る。
  ///
  /// 1 回の呼び出しでまとめて渡すので、 選択した分がごみ箱の中でも
  /// 1 つの「元に戻す」 で戻せる。
  static RecycleResult send(List<String> paths) {
    final list = paths.where((p) => p.trim().isNotEmpty).toList();
    if (list.isEmpty) return RecycleResult.recycled;
    if (!isSupported) return RecycleResult.unsupported;
    ffi.Pointer<w32.SHFILEOPSTRUCT>? op;
    ffi.Pointer<ffi.Uint16>? from;
    try {
      // ── 道筋の並びを組み立てる ──
      //   "a\0b\0\0" の形。 区切りも終わりも NUL なので、 `toNativeUtf16`
      //   (1 つの NUL で終わる) は使えない。
      final units = <int>[];
      for (final p in list) {
        // 区切りが '/' のままだと shell が受け取らないので直す。
        units.addAll(p.replaceAll('/', r'\').codeUnits);
        units.add(0);
      }
      units.add(0); // 終わりの 2 つ目の NUL
      from = calloc<ffi.Uint16>(units.length);
      for (var i = 0; i < units.length; i++) {
        from[i] = units[i];
      }
      op = calloc<w32.SHFILEOPSTRUCT>();
      op.ref
        ..hwnd = 0
        ..wFunc = w32.FO_DELETE
        ..pFrom = from.cast<Utf16>()
        ..pTo = ffi.nullptr
        // ALLOWUNDO = ごみ箱へ / NOCONFIRMATION = OS の確認は出さない
        // (アプリ側で既にたずねているので二重に聞かない) /
        // NOERRORUI = 失敗しても OS の窓を出さない (戻り値で判断する) /
        // SILENT = 進み具合の窓を出さない。
        ..fFlags = w32.FOF_ALLOWUNDO |
            w32.FOF_NOCONFIRMATION |
            w32.FOF_NOERRORUI |
            w32.FOF_SILENT
        ..fAnyOperationsAborted = 0
        ..hNameMappings = ffi.nullptr
        ..lpszProgressTitle = ffi.nullptr;
      final rc = w32.SHFileOperation(op);
      if (rc != 0) {
        debugPrint('ごみ箱へ送れませんでした (SHFileOperation=$rc)');
        return RecycleResult.failed;
      }
      if (op.ref.fAnyOperationsAborted != 0) return RecycleResult.failed;
      return RecycleResult.recycled;
    } catch (e) {
      debugPrint('ごみ箱へ送れませんでした: $e');
      return RecycleResult.failed;
    } finally {
      if (op != null) calloc.free(op);
      if (from != null) calloc.free(from);
    }
  }

  /// ごみ箱を通さずに消す (呼ぶ側が改めてたずねた後だけ使う)。
  static Future<bool> deleteForever(List<String> paths) async {
    var ok = true;
    for (final p in paths) {
      try {
        final d = Directory(p);
        if (await d.exists()) {
          await d.delete(recursive: true);
          continue;
        }
        final f = File(p);
        if (await f.exists()) await f.delete();
      } catch (e) {
        debugPrint('消せませんでした ($p): $e');
        ok = false;
      }
    }
    return ok;
  }
}
