import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';

/// ギャラリーのタイルに「中身のさわり」を出すための読み取り
/// (= ユーザー要望: xlsx や docx もサムネイルで中身が見えるように)。
///
/// 重い処理なので次の 3 つで抑えている。
///   1. 大きすぎるファイルは読まない ([_maxBytes])
///   2. 一度読んだら覚えておく ([_cache])。 ファイルの更新時刻もキーに入れる
///      ので、 中身を書き換えれば読み直される
///   3. zip を開く形式 (xlsx / docx / pptx) はアイソレートへ逃がす
///
/// 表示は数行あれば足りるので、 先頭の一部だけを返す。
class DocPreview {
  /// これより大きいファイルは、 タイルの表示のために読むには重すぎる。
  static const int _maxBytes = 8 * 1024 * 1024;

  /// タイルに出す行数の上限。
  static const int maxLines = 12;

  /// 1 行の長さの上限 (長い行で描画が重くならないように)。
  static const int _maxLineChars = 60;

  static final Map<String, List<String>> _cache = {};
  static final Map<String, Future<List<String>>> _inFlight = {};

  /// パスだけで引ける控え (= ユーザー報告: タイルを動かすたびにサムネイルが
  /// 点滅する)。 毎フレーム新しい Future を作ると FutureBuilder が待機状態に
  /// 戻ってしまうため、 一度読めた中身はここから即座に返して描き直す。
  static final Map<String, List<String>> _byPath = {};

  /// 既に読んである中身 (無ければ null)。 ファイルは触らないので軽い。
  static List<String>? cachedFor(String path) => _byPath[path];

  /// 中身を取り出せる拡張子か。
  static bool supports(String ext) => const {
        'txt', 'md', 'markdown', 'csv', 'tsv', 'json', 'log',
        'xml', 'yml', 'yaml', 'html', 'htm', //
        // CSS は HTML と一緒に使うので同じ扱いにする (= ユーザー要望)。
        'css', 'scss', 'sass', 'less', //
        'dart', 'py', 'js', 'ts', 'java', 'kt', 'c', 'cpp', 'h', 'cs', 'go',
        'rb', 'rs', 'swift', 'sh', 'sql', //
        'xlsx', 'docx', 'pptx',
      }.contains(ext.toLowerCase());

  /// [path] の中身の先頭を行の配列で返す。 読めなければ空。
  static Future<List<String>> load(String path, String ext) {
    final e = ext.toLowerCase();
    if (!supports(e)) return Future.value(const []);
    String key;
    try {
      final f = File(path);
      if (!f.existsSync()) return Future.value(const []);
      final st = f.statSync();
      if (st.size > _maxBytes) return Future.value(const []);
      key = '$path|${st.modified.millisecondsSinceEpoch}|${st.size}';
    } catch (_) {
      return Future.value(const []);
    }
    final hit = _cache[key];
    if (hit != null) {
      _byPath[path] = hit;
      return Future.value(hit);
    }
    final running = _inFlight[key];
    if (running != null) return running;

    final future = _read(path, e).then((lines) {
      _cache[key] = lines;
      _byPath[path] = lines;
      _inFlight.remove(key);
      // 覚えすぎないように、 古い物から捨てる。
      if (_cache.length > 200) {
        _cache.remove(_cache.keys.first);
      }
      return lines;
    }).catchError((_) {
      _inFlight.remove(key);
      return const <String>[];
    });
    _inFlight[key] = future;
    return future;
  }

  static Future<List<String>> _read(String path, String ext) async {
    if (ext == 'xlsx' || ext == 'docx' || ext == 'pptx') {
      final bytes = await File(path).readAsBytes();
      return compute(_readOoxml, (bytes: bytes, ext: ext));
    }
    // ── 素のテキスト ──
    String text;
    try {
      text = await File(path).readAsString();
    } catch (_) {
      // UTF-8 で読めない (Shift-JIS 等) 時はバイトから読む。
      final bytes = await File(path).readAsBytes();
      text = String.fromCharCodes(bytes.take(60000));
    }
    return _toLines(text);
  }

  static List<String> _toLines(String text) {
    final out = <String>[];
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) continue;
      out.add(line.length > _maxLineChars
          ? '${line.substring(0, _maxLineChars)}…'
          : line);
      if (out.length >= maxLines) break;
    }
    return out;
  }

  /// zip を開いて中の XML から文字を拾う。 アイソレートで動く。
  static List<String> _readOoxml(({Uint8List bytes, String ext}) arg) {
    try {
      final zip = ZipDecoder().decodeBytes(arg.bytes);
      switch (arg.ext) {
        case 'xlsx':
          return _readXlsx(zip);
        case 'docx':
          return _toLines(_stripXml(_fileText(zip, 'word/document.xml'),
              blockTags: const ['</w:p>']));
        case 'pptx':
          final buf = StringBuffer();
          final slides = zip.files
              .where((f) =>
                  f.isFile &&
                  RegExp(r'ppt/slides/slide\d+\.xml$').hasMatch(f.name))
              .toList()
            ..sort((a, b) => a.name.compareTo(b.name));
          for (final s in slides.take(3)) {
            buf.writeln(_stripXml(utf8.decode(s.content as List<int>,
                    allowMalformed: true),
                blockTags: const ['</a:p>']));
          }
          return _toLines(buf.toString());
      }
    } catch (_) {}
    return const [];
  }

  /// xlsx は「共有文字列 + 先頭シート」 を読んで、 表の形のまま返す。
  static List<String> _readXlsx(Archive zip) {
    // 共有文字列 (セルの文字はここに集約されていることが多い)。
    final shared = <String>[];
    final ssXml = _fileText(zip, 'xl/sharedStrings.xml');
    if (ssXml.isNotEmpty) {
      for (final m in RegExp(r'<si>(.*?)</si>', dotAll: true).allMatches(ssXml)) {
        shared.add(_stripXml(m.group(1) ?? ''));
      }
    }
    // 先頭のシート。
    final sheet = zip.files.firstWhere(
      (f) => f.isFile && RegExp(r'xl/worksheets/sheet\d+\.xml$').hasMatch(f.name),
      orElse: () => ArchiveFile('', 0, const <int>[]),
    );
    if (sheet.name.isEmpty) return const [];
    final xml = utf8.decode(sheet.content as List<int>, allowMalformed: true);
    final out = <String>[];
    for (final row in RegExp(r'<row[^>]*>(.*?)</row>', dotAll: true)
        .allMatches(xml)) {
      final cells = <String>[];
      for (final c
          in RegExp(r'<c([^>]*)>(.*?)</c>', dotAll: true).allMatches(row.group(1) ?? '')) {
        final attrs = c.group(1) ?? '';
        final body = c.group(2) ?? '';
        final v = RegExp(r'<v>(.*?)</v>', dotAll: true).firstMatch(body);
        String text;
        if (attrs.contains('t="s"')) {
          // 共有文字列の番号。
          final idx = int.tryParse(v?.group(1)?.trim() ?? '');
          text = (idx != null && idx >= 0 && idx < shared.length)
              ? shared[idx]
              : '';
        } else if (attrs.contains('t="inlineStr"')) {
          text = _stripXml(body);
        } else {
          text = _stripXml(v?.group(1) ?? '');
        }
        cells.add(text.trim());
      }
      // 全部空の行は飛ばす。
      if (cells.every((c) => c.isEmpty)) continue;
      var line = cells.join('  ');
      if (line.length > _maxLineChars) {
        line = '${line.substring(0, _maxLineChars)}…';
      }
      out.add(line);
      if (out.length >= maxLines) break;
    }
    return out;
  }

  static String _fileText(Archive zip, String name) {
    for (final f in zip.files) {
      if (f.isFile && f.name == name) {
        return utf8.decode(f.content as List<int>, allowMalformed: true);
      }
    }
    return '';
  }

  /// XML のタグを落として文字だけにする。
  /// [blockTags] に段落の終わりを渡すと、 そこで改行を入れる。
  static String _stripXml(String xml, {List<String> blockTags = const []}) {
    var s = xml;
    for (final t in blockTags) {
      s = s.replaceAll(t, '$t\n');
    }
    s = s.replaceAll(RegExp(r'<[^>]*>'), '');
    // ── 実体参照を戻す ──
    // 日本語は `&#21830;` のような数値参照で書かれることが多い。 ここを
    // 落とすと、 タイルに「&#21830;&#21697;」 がそのまま出てしまう
    // (= 実際に起きた)。 名前付きより先に数値を戻す。
    s = s.replaceAllMapped(
      RegExp(r'&#(x?)([0-9A-Fa-f]+);'),
      (m) {
        final isHex = (m.group(1) ?? '').isNotEmpty;
        final code = int.tryParse(m.group(2) ?? '', radix: isHex ? 16 : 10);
        if (code == null || code < 0 || code > 0x10FFFF) return m.group(0)!;
        return String.fromCharCode(code);
      },
    );
    s = s
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&amp;', '&');
    return s;
  }
}
