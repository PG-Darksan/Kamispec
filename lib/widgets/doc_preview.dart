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

  /// スライドに貼られている絵 (置き場所つき)。 重ね順は [boxes] より先
  /// (= 開いた時の描き方に合わせて、 図形 → 絵 → 文字 の順に描く)。
  final List<SlideImg> images;

  const SlidePreview({
    required this.width,
    required this.height,
    this.bg,
    required this.boxes,
    this.images = const [],
  });

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
                kind: (b['k'] as String?) ?? 'rect',
                lineColor: (b['l'] as num?)?.toInt(),
                bold: b['bd'] == true,
                align: (b['a'] as String?) ?? 'l',
                anchor: (b['an'] as String?) ?? 't',
              ),
        ],
        images: [
          for (final im in (m['i'] as List? ?? const []))
            if (im is Map)
              () {
                try {
                  return SlideImg(
                    x: (im['x'] as num?)?.toInt() ?? 0,
                    y: (im['y'] as num?)?.toInt() ?? 0,
                    w: (im['w'] as num?)?.toInt() ?? 0,
                    h: (im['h'] as num?)?.toInt() ?? 0,
                    bytes: base64Decode('${im['d'] ?? ''}'),
                  );
                } catch (_) {
                  return null;
                }
              }(),
        ].whereType<SlideImg>().toList(),
      );
    } catch (_) {
      return null;
    }
  }
}

/// スライドに貼られている絵 1 枚 (置き場所は EMU)。
class SlideImg {
  final int x;
  final int y;
  final int w;
  final int h;
  final Uint8List bytes;
  const SlideImg({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.bytes,
  });
}

/// スライドの中の 1 要素 (文字の枠 か 塗りの図形)。
class SlideBox {
  final int x;
  final int y;
  final int w;
  final int h;

  /// 文字 (改行入り。 段落ごとに 1 行)。 null なら図形。
  final String? text;
  final int? fill;
  final int? color;
  final int? sizeHundredths;

  /// 図形の形 ('rect' / 'roundRect' / 'ellipse' / 'line' / 'arrow')。
  final String kind;

  /// 線の色 (塗りの無い線・矢印はこれだけを持つ)。
  final int? lineColor;

  /// 太字か。
  final bool bold;

  /// 横のそろえ ('l' / 'ctr' / 'r')。
  final String align;

  /// 縦のそろえ ('t' / 'ctr' / 'b')。
  final String anchor;

  const SlideBox({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.text,
    this.fill,
    this.color,
    this.sizeHundredths,
    this.kind = 'rect',
    this.lineColor,
    this.bold = false,
    this.align = 'l',
    this.anchor = 't',
  });
}

class DocPreview {
  /// これより大きいファイルは、 タイルの表示のために読むには重すぎる。
  static const int _maxBytes = 8 * 1024 * 1024;

  /// 資料 (pptx) だけは大きめまで読む。
  /// 写真やテンプレートの入った資料はすぐ 8MB を超えるが、 そういう資料こそ
  /// 表紙を見たい (= 超えると絵も文字も無いアイコンだけになっていた)。
  /// 読むのは 1 枚目とその関係先だけなので、 重さは大きさに比例しない。
  static const int _maxBytesPptx = 48 * 1024 * 1024;

  static int _limitFor(String ext) =>
      ext == 'pptx' ? _maxBytesPptx : _maxBytes;

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

  /// [_byPath] に控えた時のファイルの姿 (パス|更新時刻|大きさ)。
  /// 今のファイルと違っていたら中身が書き換わったという事なので、 控えを
  /// 捨てて読み直す (= ユーザー報告: AI にテキストファイルへ 100 行
  /// 書かせても、 ギャラリーのサムネイルが古いまま更新されない)。
  static final Map<String, String> _keyByPath = {};

  /// 最後にファイルの姿を確かめた時刻 (ミリ秒)。 タイルは毎フレーム
  /// 描き直されるので、 一定の間をおいてだけ確かめる (タイルの枚数だけ
  /// 毎フレーム ディスクを触らないため)。
  static final Map<String, int> _checkedAt = {};

  /// 確かめ直す間隔 (ミリ秒)。
  static const int _recheckMs = 1200;

  /// 今のファイルの姿を表す鍵 (読めなければ null)。
  static String? _statKey(String path) {
    try {
      final f = File(path);
      if (!f.existsSync()) return null;
      final st = f.statSync();
      return '$path|${st.modified.millisecondsSinceEpoch}|${st.size}';
    } catch (_) {
      return null;
    }
  }

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
    _keyByPath.remove(path);
    _checkedAt.remove(path);
    _missAt[path] = DateTime.now().millisecondsSinceEpoch;
    return Future.value(const <String>[]);
  }

  /// 既に読んである中身 (無ければ null)。
  ///
  /// ★ 控えたあとに、 同じパスのままファイルの中身だけが書き換わる事がある
  ///   (= ユーザー報告: AI にテキストファイルへ 100 行書かせてもサムネイルが
  ///   更新されない)。 この控えはパスだけを鍵にしているので中身の変化に
  ///   気付けない。 一定の間をおいてファイルの姿 (更新時刻と大きさ) を見に
  ///   行き、 変わっていたら捨てて読み直させる。 [_recheckMs] より短い間隔
  ///   では触らないので、 タイルが何十枚あっても毎フレームのディスク読みには
  ///   ならない。
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
    final hit = _byPath[path];
    if (hit == null) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - (_checkedAt[path] ?? 0) >= _recheckMs) {
      _checkedAt[path] = now;
      final known = _keyByPath[path];
      final fresh = _statKey(path);
      if (known != null && fresh != null && known != fresh) {
        invalidate(path);
        return null;
      }
    }
    return hit;
  }

  /// このパスの控えを捨てる (= ファイルを差し替えた時などに読み直させる)。
  static void invalidate(String path) {
    _byPath.remove(path);
    _keyByPath.remove(path);
    _checkedAt.remove(path);
    _missAt.remove(path);
    _styleByPath.remove(path);
    _slideByPath.remove(path);
    // ★ 更新時刻つきの控え ([_cache]) も一緒に捨てる。 同じミリ秒・同じ
    //   大きさで書き換わると鍵が変わらず、 読み直しても古い中身を返して
    //   しまうため (= 短い文章を続けて書かせた時に起きる)。
    _cache.removeWhere((k, _) => k.startsWith('$path|'));
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
      if (st.size > _limitFor(e)) return _miss(path);
      key = '$path|${st.modified.millisecondsSinceEpoch}|${st.size}';
    } catch (_) {
      return _miss(path);
    }
    // ここまで来たら読めるファイルなので、 読めなかった控えは捨てる。
    _missAt.remove(path);
    final hit = _cache[key];
    if (hit != null) {
      _byPath[path] = hit;
      _keyByPath[path] = key;
      _checkedAt[path] = DateTime.now().millisecondsSinceEpoch;
      return Future.value(hit);
    }
    final running = _inFlight[key];
    if (running != null) return running;

    final future = _read(path, e).then((raw) {
      final lines = _extractStyle(path, _extractSlide(path, raw));
      _cache[key] = lines;
      _byPath[path] = lines;
      // どの姿のファイルを控えたかを覚えておく (= cachedFor が中身の
      //   書き換えに気付くための目印)。
      _keyByPath[path] = key;
      _checkedAt[path] = DateTime.now().millisecondsSinceEpoch;
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
      _keyByPath.remove(path);
      _checkedAt.remove(path);
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
    // ★ JSON は改行の無い 1 行で書かれている事が多い (= ユーザー報告:
    //   JSON を埋め込んでも中身が見えない)。 そのままだと 1 行だけの
    //   切れた表紙になるので、 段を付けてから行に分ける。
    //   大きいファイルで固まらないよう、 頭の方だけを整える。
    if (ext == 'json') {
      try {
        final head = text.length > 200000 ? text.substring(0, 200000) : text;
        text = const JsonEncoder.withIndent('  ').convert(jsonDecode(head));
      } catch (_) {
        // 壊れている / 途中で切った時はそのまま出す。
      }
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
          // ★ 「1 枚目」 は presentation.xml の並び (<p:sldIdLst>) で決める。
          //   ファイル名の順ではない (= 並べ替えても中の番号は変わらないので、
          //   名前順だとタイルだけ別のページを出してしまう。 slide10.xml が
          //   slide2.xml より前に来る、 という問題もある)。
          final firstName = _pptxFirstSlidePart(zip);
          final first = firstName == null ? null : _fileOf(zip, firstName);
          String firstXml = '';
          if (first != null) {
            firstXml =
                utf8.decode(first.content as List<int>, allowMalformed: true);
            buf.writeln(_stripXml(firstXml, blockTags: const ['</a:p>']));
          }
          final lines = _toLines(buf.toString());
          // ── 1 枚目の配色と中身 (= ユーザー要望: 文字の配置まで同じに) ──
          final style = _pptxFirstSlideColors(firstXml);
          final slide =
              _pptxFirstSlideLayout(zip, firstXml, firstName ?? '');
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
  static String? _pptxFirstSlideLayout(
      Archive zip, String xml, String slidePath) {
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

    /// この XML の中の最初の単色を拾う。
    int? firstSolid(String s) => hex(
        RegExp(r'<a:srgbClr val="([0-9A-Fa-f]{6})"')
            .firstMatch(s)
            ?.group(1)
            ?.toUpperCase());

    /// `<p:bg>` の色 (無ければ null)。 単色でもグラデーションでも、
    /// 最初に出てくる色を紙の色として使う。
    int? bgOf(String s) {
      final m = RegExp(r'<p:bg>[\s\S]*?</p:bg>').firstMatch(s);
      return m == null ? null : firstSolid(m.group(0)!);
    }

    // ── 紙の色: スライド → レイアウト → マスター の順に探す ──
    //    (= 開いた時のビューアも 3 段を見ているので、 タイルも合わせる)。
    final rels = _relsOf(zip, slidePath);
    var bg = bgOf(xml);
    String? layoutPath;
    for (final t in rels.values) {
      if (t.contains('slideLayout')) {
        layoutPath = _resolvePart(slidePath, t);
        break;
      }
    }
    String? masterPath;
    if (layoutPath != null) {
      final layoutXml = _fileText(zip, layoutPath);
      bg ??= bgOf(layoutXml);
      for (final t in _relsOf(zip, layoutPath).values) {
        if (t.contains('slideMaster')) {
          masterPath = _resolvePart(layoutPath, t);
          break;
        }
      }
    }
    if (bg == null && masterPath != null) {
      bg = bgOf(_fileText(zip, masterPath));
    }

    // ── 中身 (図形 / 絵 / 文字) を、 書かれている順に読む ──
    //    重ね順がそのまま奥から手前になるので、 並べ替えない。
    final spTree = _sliceBetween(xml, '<p:spTree>', '</p:spTree>');
    final boxes = <Map<String, dynamic>>[];
    final images = <Map<String, dynamic>>[];
    var imageBytes = 0;

    for (final m in RegExp(
            r'<p:(sp|pic)\b[\s\S]*?</p:\1>')
        .allMatches(spTree)) {
      if (boxes.length >= 40) break;
      final tag = m.group(1)!;
      final el = m.group(0)!;
      final off = RegExp(r'<a:off x="(-?\d+)" y="(-?\d+)"').firstMatch(el);
      final ext = RegExp(r'<a:ext cx="(\d+)" cy="(\d+)"').firstMatch(el);
      if (off == null || ext == null) continue;
      final x = int.parse(off.group(1)!);
      final y = int.parse(off.group(2)!);
      final w = int.parse(ext.group(1)!);
      final h = int.parse(ext.group(2)!);

      if (tag == 'pic') {
        // ★ 絵 (= これまで 1 枚も読んでいなかったので、 タイルからは写真が
        //   まるごと消えていた)。 大きい物・多い物は読まない (タイルの
        //   ために何 MB も抱えないため)。
        if (images.length >= 3 || imageBytes > 2500000) continue;
        final rid = RegExp(r'<a:blip[^>]*r:embed="([^"]+)"')
            .firstMatch(el)
            ?.group(1);
        if (rid == null) continue;
        final target = rels[rid];
        if (target == null) continue;
        final part = _resolvePart(slidePath, target);
        final f = _fileOf(zip, part);
        if (f == null) continue;
        final ext2 = part.split('.').last.toLowerCase();
        if (!const {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'}
            .contains(ext2)) {
          continue;
        }
        final data = f.content as List<int>;
        if (data.length > 1500000) continue;
        imageBytes += data.length;
        images.add({
          'x': x,
          'y': y,
          'w': w,
          'h': h,
          'd': base64Encode(data),
        });
        continue;
      }

      // ── 図形 / 文字の枠 ──
      // 形。 線・矢印は塗らずに線で描く。
      final prst = RegExp(r'<a:prstGeom\s+prst="([A-Za-z0-9]+)"')
              .firstMatch(el)
              ?.group(1) ??
          'rect';
      final kind = prst == 'ellipse' || prst == 'roundRect'
          ? prst
          : (prst == 'line' || prst == 'straightConnector1')
              ? 'line'
              : prst.toLowerCase().contains('arrow')
                  ? 'arrow'
                  : 'rect';

      // 段落ごとに 1 行として読む (= 全部つなげると、 開いた時と行の
      //   分かれ方が変わってしまう)。
      final paras = <String>[];
      var align = 'l';
      var bold = false;
      int? textColor;
      int? sizeH;
      for (final pm
          in RegExp(r'<a:p\b[^>]*>([\s\S]*?)</a:p>').allMatches(el)) {
        final pxml = pm.group(0)!;
        final t = [
          for (final tm
              in RegExp(r'<a:t[^>]*>([^<]*)</a:t>').allMatches(pxml))
            tm.group(1) ?? ''
        ].join();
        if (t.trim().isEmpty) continue;
        paras.add(t.trim());
        final al = RegExp(r'<a:pPr[^>]*\salgn="([a-z]+)"')
            .firstMatch(pxml)
            ?.group(1);
        if (al != null && paras.length == 1) {
          align = al == 'ctr' || al == 'r' ? al : 'l';
        }
        final rpr = RegExp(r'<a:(?:rPr|defRPr)\b[^>]*>').firstMatch(pxml);
        if (rpr != null && paras.length == 1) {
          bold = rpr.group(0)!.contains('b="1"');
          final sz = RegExp(r'sz="(\d+)"').firstMatch(rpr.group(0)!);
          if (sz != null) sizeH = int.tryParse(sz.group(1)!);
        }
        if (textColor == null) {
          final rprFull =
              RegExp(r'<a:rPr\b[\s\S]*?</a:rPr>').firstMatch(pxml);
          if (rprFull != null) textColor = firstSolid(rprFull.group(0)!);
        }
      }
      // 自分で閉じる `<a:rPr .../>` しか無い時も拾う。
      if (sizeH == null) {
        final sz = RegExp(r'<a:(?:rPr|defRPr)[^>]*\ssz="(\d+)"')
            .firstMatch(el);
        if (sz != null) sizeH = int.tryParse(sz.group(1)!);
      }
      // 縦のそろえ。
      final anchorM =
          RegExp(r'<a:bodyPr[^>]*\sanchor="([a-z]+)"').firstMatch(el);
      final anchor0 = anchorM?.group(1) ?? 't';
      final anchor = anchor0 == 'ctr' || anchor0 == 'b' ? anchor0 : 't';

      // ★ 塗りは `<p:spPr>` の中だけを見る。 以前は要素まるごとを見ていた
      //   ので、 線や矢印の `<a:ln>` の色を「塗り」 と読み違えて、 細い矢印が
      //   大きな色板として描かれていた。
      final spPr = _sliceBetween(el, '<p:spPr>', '</p:spPr>');
      final noFill = spPr.contains('<a:noFill/>');
      int? fill;
      if (!noFill) {
        final fm = RegExp(
                r'<a:solidFill>\s*<a:srgbClr val="([0-9A-Fa-f]{6})"')
            .firstMatch(spPr.split('<a:ln').first);
        fill = hex(fm?.group(1)?.toUpperCase());
      }
      final lnPart = spPr.contains('<a:ln')
          ? spPr.substring(spPr.indexOf('<a:ln'))
          : '';
      final lineColor = lnPart.isEmpty ? null : firstSolid(lnPart);

      final hasText = paras.isNotEmpty;
      if (!hasText && fill == null && lineColor == null) continue;
      boxes.add({
        'x': x,
        'y': y,
        'w': w,
        'h': h,
        'k': kind,
        if (hasText) 't': paras.join('\n'),
        if (fill != null) 'f': fill,
        if (lineColor != null) 'l': lineColor,
        if (hasText && textColor != null) 'c': textColor,
        if (hasText && sizeH != null) 's': sizeH,
        if (hasText && bold) 'bd': true,
        if (hasText && align != 'l') 'a': align,
        if (hasText && anchor != 't') 'an': anchor,
      });
    }
    if (boxes.isEmpty && images.isEmpty && bg == null) return null;
    return '$_slideMark${jsonEncode({
          'w': slideW,
          'h': slideH,
          if (bg != null) 'bg': bg,
          'b': boxes,
          if (images.isNotEmpty) 'i': images,
        })}';
  }

  /// 表示順で最初のスライドの部品名 (`ppt/slides/slideN.xml`)。
  ///
  /// PowerPoint の並びは presentation.xml の `<p:sldIdLst>` が持っている。
  /// ファイル名の番号順とは限らないので、 そちらを優先する
  /// (= 並べ替えるとタイルだけ別のページを出していた)。
  static String? _pptxFirstSlidePart(Archive zip) {
    final pres = _fileText(zip, 'ppt/presentation.xml');
    final rels = _relsOf(zip, 'ppt/presentation.xml');
    final rid = RegExp(r'<p:sldId[^>]*?r:id="([^"]+)"')
        .firstMatch(pres)
        ?.group(1);
    if (rid != null) {
      final t = rels[rid];
      if (t != null) {
        final part = _resolvePart('ppt/presentation.xml', t);
        if (_fileOf(zip, part) != null) return part;
      }
    }
    // 読めなければ番号順 (slide2 より slide10 が先に来ないように数で並べる)。
    final all = zip.files
        .where((f) =>
            f.isFile && RegExp(r'ppt/slides/slide\d+\.xml$').hasMatch(f.name))
        .toList();
    if (all.isEmpty) return null;
    int no(String name) =>
        int.tryParse(
            RegExp(r'slide(\d+)\.xml').firstMatch(name)?.group(1) ?? '0') ??
        0;
    all.sort((a, b) => no(a.name).compareTo(no(b.name)));
    return all.first.name;
  }

  /// 部品名 → その部品の `_rels` (rId → Target)。
  static Map<String, String> _relsOf(Archive zip, String partPath) {
    final i = partPath.lastIndexOf('/');
    if (i < 0) return const {};
    final relPath =
        '${partPath.substring(0, i)}/_rels/${partPath.substring(i + 1)}.rels';
    final xml = _fileText(zip, relPath);
    if (xml.isEmpty) return const {};
    final out = <String, String>{};
    for (final m
        in RegExp(r'<Relationship[^>]*?Id="([^"]+)"[^>]*?Target="([^"]+)"')
            .allMatches(xml)) {
      out[m.group(1)!] = m.group(2)!;
    }
    return out;
  }

  /// 相対パスを zip の中の絶対パスに直す。
  static String _resolvePart(String fromPart, String target) {
    if (target.startsWith('/')) return target.substring(1);
    final baseDir = fromPart.contains('/')
        ? fromPart.substring(0, fromPart.lastIndexOf('/'))
        : '';
    final segs = <String>[
      ...baseDir.split('/').where((e) => e.isNotEmpty),
    ];
    for (final s in target.split('/')) {
      if (s.isEmpty || s == '.') continue;
      if (s == '..') {
        if (segs.isNotEmpty) segs.removeLast();
      } else {
        segs.add(s);
      }
    }
    return segs.join('/');
  }

  static ArchiveFile? _fileOf(Archive zip, String name) {
    for (final f in zip.files) {
      if (f.isFile && f.name == name) return f;
    }
    return null;
  }

  /// [open] と [close] に挟まれた部分 (無ければ元のまま)。
  static String _sliceBetween(String s, String open, String close) {
    final a = s.indexOf(open);
    if (a < 0) return s;
    final b = s.lastIndexOf(close);
    if (b <= a) return s.substring(a + open.length);
    return s.substring(a + open.length, b);
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
