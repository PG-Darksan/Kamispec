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
/// サムネイル用に控えた「スライド 1 枚」 (= ユーザー要望: 文字の配置まで
/// 1 枚目と同じに)。 座標は EMU。
class SlidePreview {
  final int width;
  final int height;
  final int? bg;
  final List<SlideBox> boxes;
  const SlidePreview(
      {required this.width,
      required this.height,
      this.bg,
      required this.boxes});

  static SlidePreview? fromJsonString(String raw) {
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return null;
      return SlidePreview(
        width: (m['w'] as num?)?.toInt() ?? 12192000,
        height: (m['h'] as num?)?.toInt() ?? 6858000,
        bg: (m['bg'] as num?)?.toInt(),
        boxes: [
          for (final b in (m['b'] as List? ?? const []))
            if (b is Map)
              SlideBox(
                x: (b['x'] as num?)?.toInt() ?? 0,
                y: (b['y'] as num?)?.toInt() ?? 0,
                w: (b['w'] as num?)?.toInt() ?? 0,
                h: (b['h'] as num?)?.toInt() ?? 0,
                text: b['t'] as String?,
                fill: (b['f'] as num?)?.toInt(),
                color: (b['c'] as num?)?.toInt(),
                sizeHundredths: (b['s'] as num?)?.toInt(),
              ),
        ],
      );
    } catch (_) {
      return null;
    }
  }
}

/// スライドの中の 1 要素 (文字の枠 か 塗りの図形)。
class SlideBox {
  final int x;
  final int y;
  final int w;
  final int h;
  final String? text;
  final int? fill;
  final int? color;
  final int? sizeHundredths;
  const SlideBox({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.text,
    this.fill,
    this.color,
    this.sizeHundredths,
  });
}

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

  /// 読めなかったパスと、 その時刻 (ミリ秒)。
  ///
  /// ★ = ユーザー報告「指定されたパスが見つからない txt ファイルのサムネイルが
  ///   画面を移動させる度にチカチカする」。 読めた時は [_byPath] に控えるので
  ///   次からは即座に返せるが、 読めなかった時は何も控えていなかったため、
  ///   毎フレーム新しい Future が作られ、 FutureBuilder が「待機」 に戻って
  ///   仮の絵 → 白紙 → 仮の絵… と点滅していた。 読めなかった事も控える。
  ///
  /// ずっと覚えたままだとファイルを戻しても出てこないので、 一定時間が
  /// 経ったら 1 度だけ読み直す。
  static final Map<String, int> _missAt = {};

  /// 読めなかった控えを捨てるまでの時間。
  static const int _missTtlMs = 30 * 1000;

  /// 読めなかった事を控えて、 空を返す。
  static Future<List<String>> _miss(String path) {
    _byPath[path] = const <String>[];
    _missAt[path] = DateTime.now().millisecondsSinceEpoch;
    return Future.value(const <String>[]);
  }

  /// 既に読んである中身 (無ければ null)。 ファイルは触らないので軽い。
  static List<String>? cachedFor(String path) {
    final miss = _missAt[path];
    if (miss != null &&
        DateTime.now().millisecondsSinceEpoch - miss > _missTtlMs) {
      // 時間が経ったので、 1 度だけ読み直させる (= ファイルを戻した時に
      //   いつまでも白紙のままにならないように)。
      _missAt.remove(path);
      _byPath.remove(path);
      return null;
    }
    return _byPath[path];
  }

  /// このパスの控えを捨てる (= ファイルを差し替えた時などに読み直させる)。
  static void invalidate(String path) {
    _byPath.remove(path);
    _missAt.remove(path);
    _styleByPath.remove(path);
    _slideByPath.remove(path);
  }

  /// pptx の 1 枚目から拾った配色 (= ユーザー要望: 表紙のデザインが
  /// サムネイルに出るように)。 背景色と文字色 (どちらも RGB 24bit)。
  static final Map<String, ({int? bg, int? fg})> _styleByPath = {};

  /// [path] の配色 (無ければ null)。
  static ({int? bg, int? fg})? styleFor(String path) => _styleByPath[path];

  /// pptx の 1 枚目の中身を「置き場所つき」 で控えたもの
  /// (= ユーザー要望: サムネイルの文字の配置まで 1 枚目と同じに)。
  static final Map<String, SlidePreview> _slideByPath = {};

  /// [path] の 1 枚目 (無ければ null)。
  static SlidePreview? slideFor(String path) => _slideByPath[path];

  /// 中身の先頭に潜ませる配色の目印 (アイソレートからの受け渡し用)。
  static const String _styleMark = '\u0000hnstyle:';

  /// スライドの中身を渡すための目印。
  static const String _slideMark = '\u0000hnslide:';

  /// 目印の行を取り除いて、 1 枚目の中身として控える。
  static List<String> _extractSlide(String path, List<String> lines) {
    if (lines.isEmpty || !lines.first.startsWith(_slideMark)) return lines;
    try {
      final sp = SlidePreview.fromJsonString(
          lines.first.substring(_slideMark.length));
      if (sp != null) _slideByPath[path] = sp;
    } catch (_) {}
    return lines.sublist(1);
  }

  /// 目印の行を取り除いて、 配色として控える。
  static List<String> _extractStyle(String path, List<String> lines) {
    if (lines.isEmpty || !lines.first.startsWith(_styleMark)) return lines;
    final body = lines.first.substring(_styleMark.length);
    int? parse(String v) =>
        v.length == 6 ? int.tryParse(v, radix: 16) : null;
    final parts = body.split('|');
    _styleByPath[path] = (
      bg: parts.isNotEmpty ? parse(parts[0]) : null,
      fg: parts.length > 1 ? parse(parts[1]) : null,
    );
    return lines.sublist(1);
  }

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
    // ★ 読めない時も「読めなかった」 と控える (_miss)。 控えないと
    //   cachedFor が毎回 null を返し、 描き直すたびに新しい Future が
    //   作られて FutureBuilder が待機状態へ戻り、 タイルが点滅する
    //   (= ユーザー報告: 無くなった txt のサムネイルがチカチカする)。
    if (!supports(e)) return _miss(path);
    String key;
    try {
      final f = File(path);
      if (!f.existsSync()) return _miss(path);
      final st = f.statSync();
      if (st.size > _maxBytes) return _miss(path);
      key = '$path|${st.modified.millisecondsSinceEpoch}|${st.size}';
    } catch (_) {
      return _miss(path);
    }
    // ここまで来たら読めるファイルなので、 読めなかった控えは捨てる。
    _missAt.remove(path);
    final hit = _cache[key];
    if (hit != null) {
      _byPath[path] = hit;
      return Future.value(hit);
    }
    final running = _inFlight[key];
    if (running != null) return running;

    final future = _read(path, e).then((raw) {
      final lines = _extractStyle(path, _extractSlide(path, raw));
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
      // 読み取りに失敗した事も控える (= 点滅を止める)。
      _byPath[path] = const <String>[];
      _missAt[path] = DateTime.now().millisecondsSinceEpoch;
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
          String firstXml = '';
          // 1 枚目だけを出す (= ユーザー要望: サムネイルに 2 枚目以降の
          // 内容まで混ざらないように)。
          for (final s in slides.take(1)) {
            final xml =
                utf8.decode(s.content as List<int>, allowMalformed: true);
            if (firstXml.isEmpty) firstXml = xml;
            buf.writeln(_stripXml(xml, blockTags: const ['</a:p>']));
          }
          final lines = _toLines(buf.toString());
          // ── 1 枚目の配色と中身 (= ユーザー要望: 文字の配置まで同じに) ──
          final style = _pptxFirstSlideColors(firstXml);
          final slide = _pptxFirstSlideLayout(zip, firstXml);
          return [
            if (slide != null) slide,
            if (style != null) style,
            ...lines,
          ];
      }
    } catch (_) {}
    return const [];
  }

  /// 1 枚目のスライドの背景色と文字色を拾う。 見つからなければ null。
  ///
  /// 背景は `<p:bg>` の中の単色、 文字色は最初の `<a:rPr>` の中の単色。
  /// どちらも無い (= テーマ色任せ) ファイルは、 従来どおり白い紙にする。
  static String? _pptxFirstSlideColors(String xml) {
    if (xml.isEmpty) return null;
    String? bg;
    final bgBlock = RegExp(r'<p:bg>[\s\S]*?</p:bg>').firstMatch(xml);
    if (bgBlock != null) {
      final m = RegExp(r'<a:srgbClr val="([0-9A-Fa-f]{6})"')
          .firstMatch(bgBlock.group(0)!);
      bg = m?.group(1)?.toUpperCase();
    }
    String? fg;
    final rpr = RegExp(r'<a:rPr\b[\s\S]*?</a:rPr>').firstMatch(xml);
    if (rpr != null) {
      final m = RegExp(r'<a:srgbClr val="([0-9A-Fa-f]{6})"')
          .firstMatch(rpr.group(0)!);
      fg = m?.group(1)?.toUpperCase();
    }
    if (bg == null && fg == null) return null;
    return '$_styleMark${bg ?? ''}|${fg ?? ''}';
  }

  /// 1 枚目のスライドを「置き場所つき」 で読む。
  ///
  /// `<p:sp>` の `<a:off>/<a:ext>` (EMU) と中の文字、 塗り色を拾って、
  /// 縮小表示で並べ直せるだけの情報にする。 読めなければ null。
  static String? _pptxFirstSlideLayout(Archive zip, String xml) {
    if (xml.isEmpty) return null;
    // スライドの大きさ (presentation.xml)。 取れなければ 16:9 の既定値。
    var slideW = 12192000;
    var slideH = 6858000;
    final presXml = _fileText(zip, 'ppt/presentation.xml');
    final szm = RegExp(r'<p:sldSz\s+cx="(\d+)"\s+cy="(\d+)"')
        .firstMatch(presXml);
    if (szm != null) {
      slideW = int.tryParse(szm.group(1)!) ?? slideW;
      slideH = int.tryParse(szm.group(2)!) ?? slideH;
    }
    int? hex(String? v) => (v != null && v.length == 6)
        ? int.tryParse(v, radix: 16)
        : null;

    int? bg;
    final bgBlock = RegExp(r'<p:bg>[\s\S]*?</p:bg>').firstMatch(xml);
    if (bgBlock != null) {
      bg = hex(RegExp(r'<a:srgbClr val="([0-9A-Fa-f]{6})"')
          .firstMatch(bgBlock.group(0)!)
          ?.group(1)
          ?.toUpperCase());
    }

    final boxes = <Map<String, dynamic>>[];
    for (final m
        in RegExp(r'<p:sp\b[\s\S]*?</p:sp>').allMatches(xml)) {
      final sp = m.group(0)!;
      final off = RegExp(r'<a:off x="(-?\d+)" y="(-?\d+)"').firstMatch(sp);
      final ext = RegExp(r'<a:ext cx="(\d+)" cy="(\d+)"').firstMatch(sp);
      if (off == null || ext == null) continue;
      final texts = [
        for (final t in RegExp(r'<a:t[^>]*>([^<]*)</a:t>').allMatches(sp))
          t.group(1) ?? ''
      ].join();
      final fillM = RegExp(
              r'<a:solidFill>\s*<a:srgbClr val="([0-9A-Fa-f]{6})"')
          .firstMatch(sp);
      final szM = RegExp(r'<a:(?:rPr|defRPr)[^>]*sz="(\d+)"').firstMatch(sp);
      // 文字色は <a:rPr> の中の塗り。
      int? textColor;
      final rpr = RegExp(r'<a:rPr\b[\s\S]*?</a:rPr>').firstMatch(sp);
      if (rpr != null) {
        textColor = hex(RegExp(r'<a:srgbClr val="([0-9A-Fa-f]{6})"')
            .firstMatch(rpr.group(0)!)
            ?.group(1)
            ?.toUpperCase());
      }
      final hasText = texts.trim().isNotEmpty;
      boxes.add({
        'x': int.parse(off.group(1)!),
        'y': int.parse(off.group(2)!),
        'w': int.parse(ext.group(1)!),
        'h': int.parse(ext.group(2)!),
        if (hasText) 't': texts.trim(),
        if (!hasText && fillM != null) 'f': hex(fillM.group(1)!.toUpperCase()),
        if (hasText && textColor != null) 'c': textColor,
        if (hasText && szM != null) 's': int.parse(szM.group(1)!),
      });
      if (boxes.length >= 24) break;
    }
    if (boxes.isEmpty && bg == null) return null;
    return '$_slideMark${jsonEncode({
          'w': slideW,
          'h': slideH,
          if (bg != null) 'bg': bg,
          'b': boxes,
        })}';
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
