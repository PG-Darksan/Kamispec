// 自動操作で使う「秘密の値」 (合言葉など) の控え。
//
// ★ = ユーザー要望「自動操作で何かにログインしてってお願いした時に、 AI に
//   パスワードを直接平文で渡さずに、 変数で読ませずに渡す仕組みが欲しい」。
//
// 仕組み:
//   ・利用者は名前を付けて値を入れる (例: 名前 `会社メール`、 値 = 合言葉)。
//   ・AI には**名前しか見せない**。 手順の中では `{{secret:会社メール}}` と
//     書かせる (AI は中身を知らないまま手順を組める)。
//   ・実際に打ち込む直前に、 アプリが名前を値へ置き換える。
//     つまり値は AI にも、 手順の控えにも、 画面の記録にも出ない。
//
// 置き場:
//   Windows では **DPAPI** (`CryptProtectData`) で包んでから控える。 同じ
//   Windows ユーザーでしか開けない形になるので、 設定ファイルを覗かれても
//   中身は読めない。 包めなかった時 (Windows 以外など) は、 そのままでは
//   平文になってしまうので**入れさせない**で断る (= 中途半端に守った気に
//   させない)。
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as pkg_ffi;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 控えの鍵。 中身は {名前: 包んだ値の base64}。
const String _kPrefsKey = 'automation_secrets_v1';

/// 手順の中で秘密を指す書き方。
final RegExp kSecretRef = RegExp(r'\{\{\s*secret\s*:\s*([^}]+?)\s*\}\}');

// ── DPAPI (crypt32.dll) ───────────────────────────────────────────────
final class _Blob extends ffi.Struct {
  @ffi.Uint32()
  external int cbData;
  external ffi.Pointer<ffi.Uint8> pbData;
}

typedef _ProtectNative = ffi.Int32 Function(
    ffi.Pointer<_Blob> dataIn,
    ffi.Pointer<ffi.Uint16> desc,
    ffi.Pointer<_Blob> entropy,
    ffi.Pointer<ffi.Void> reserved,
    ffi.Pointer<ffi.Void> prompt,
    ffi.Uint32 flags,
    ffi.Pointer<_Blob> dataOut);
typedef _ProtectDart = int Function(
    ffi.Pointer<_Blob> dataIn,
    ffi.Pointer<ffi.Uint16> desc,
    ffi.Pointer<_Blob> entropy,
    ffi.Pointer<ffi.Void> reserved,
    ffi.Pointer<ffi.Void> prompt,
    int flags,
    ffi.Pointer<_Blob> dataOut);

class SecretStore {
  SecretStore._();

  /// この端末で秘密を安全に預かれるか (= 包める仕組みがあるか)。
  static bool get supported => !kIsWeb && Platform.isWindows;

  static ffi.DynamicLibrary? _lib;
  static ffi.DynamicLibrary get _crypt32 =>
      _lib ??= ffi.DynamicLibrary.open('crypt32.dll');

  static Uint8List? _dpapi(Uint8List src, {required bool protect}) {
    if (!supported) return null;
    final fn = _crypt32.lookupFunction<_ProtectNative, _ProtectDart>(
        protect ? 'CryptProtectData' : 'CryptUnprotectData');
    final inPtr = pkg_ffi.calloc<ffi.Uint8>(src.length);
    final inBlob = pkg_ffi.calloc<_Blob>();
    final outBlob = pkg_ffi.calloc<_Blob>();
    try {
      inPtr.asTypedList(src.length).setAll(0, src);
      inBlob.ref
        ..cbData = src.length
        ..pbData = inPtr;
      final ok = fn(inBlob, ffi.nullptr, ffi.nullptr, ffi.nullptr, ffi.nullptr,
          0, outBlob);
      if (ok == 0) return null;
      final n = outBlob.ref.cbData;
      final out = Uint8List.fromList(outBlob.ref.pbData.asTypedList(n));
      return out;
    } catch (_) {
      return null;
    } finally {
      pkg_ffi.calloc.free(inPtr);
      pkg_ffi.calloc.free(inBlob);
      pkg_ffi.calloc.free(outBlob);
    }
  }

  // ── 控え ───────────────────────────────────────────────────────────
  static Map<String, String> _wrapped = <String, String>{};
  static bool _loaded = false;

  static Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_kPrefsKey) ?? '';
      if (raw.isEmpty) return;
      final m = jsonDecode(raw);
      if (m is Map) {
        _wrapped = <String, String>{
          for (final e in m.entries) '${e.key}': '${e.value}',
        };
      }
    } catch (_) {}
  }

  static Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kPrefsKey, jsonEncode(_wrapped));
    } catch (_) {}
  }

  /// 預けてある秘密の**名前だけ**。 AI にも画面にもこれしか見せない。
  static Future<List<String>> names() async {
    await _load();
    final out = _wrapped.keys.toList()..sort();
    return out;
  }

  /// 名前を付けて預ける。 包めなければ false (= 平文では置かない)。
  static Future<bool> put(String name, String value) async {
    final key = name.trim();
    if (key.isEmpty || value.isEmpty) return false;
    if (!supported) return false;
    final sealed = _dpapi(Uint8List.fromList(utf8.encode(value)),
        protect: true);
    if (sealed == null) return false;
    await _load();
    _wrapped[key] = base64Encode(sealed);
    await _save();
    return true;
  }

  static Future<void> remove(String name) async {
    await _load();
    if (_wrapped.remove(name.trim()) != null) await _save();
  }

  /// 中身を取り出す (打ち込む直前だけ呼ぶ)。 無ければ null。
  static Future<String?> read(String name) async {
    await _load();
    final b = _wrapped[name.trim()];
    if (b == null) return null;
    try {
      final open = _dpapi(base64Decode(b), protect: false);
      if (open == null) return null;
      return utf8.decode(open);
    } catch (_) {
      return null;
    }
  }

  /// 文字の中の `{{secret:名前}}` を中身へ置き換える。
  ///
  /// ★ 置き換えるのは**打ち込む直前**だけ。 手順の控えにも、 画面の記録にも
  ///   置き換えた後の文字を残さないこと。
  static Future<String> expand(String text) async {
    if (!text.contains('{{')) return text;
    final ms = kSecretRef.allMatches(text).toList();
    if (ms.isEmpty) return text;
    var out = text;
    for (final m in ms) {
      final name = (m.group(1) ?? '').trim();
      final v = await read(name);
      if (v == null) continue;
      out = out.replaceAll(m.group(0)!, v);
    }
    return out;
  }

  /// 記録に残す用に、 秘密の所を伏せた文字を返す。
  static String mask(String text) =>
      text.replaceAll(kSecretRef, '********');
}
