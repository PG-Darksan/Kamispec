// 面接練習・ロールプレイの「下調べ」 (= ユーザー要望: AI の知識だけでなく
// Web から学校/企業の情報を取ってきて、 さらにユーザーが用意した
// 「過去にこんな質問が来た」 という資料ファイルも参照させたい)。
//
// ブラウジングと言っても WebView を立ち上げるのではなく、 HTTP で本文を
// 取ってきて素のテキストにするだけ (= 表示は不要で、 AI に渡せればよい)。
// 鍵の要らない情報源だけを使う:
//   1. Wikipedia API (検索 → 本文抽出 → 公式サイトのリンク)
//   2. その公式サイト本体 (HTML → タグ落とし)
//   3. DuckDuckGo Lite (Wikipedia に載っていない学校/企業の公式サイト探し)
// どれも失敗し得るので、 全ての段で握りつぶして「取れた分だけ」 返す。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart' as xls;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:syncfusion_flutter_pdf/pdf.dart' as sfpdf;

/// 下調べで集めた 1 件分の資料。
class TalkRefSource {
  /// 出どころ (例: 'Wikipedia', '公式サイト', 'ファイル: 過去問.pdf')。
  final String label;

  /// 本文 (プレーンテキスト)。
  final String text;

  const TalkRefSource(this.label, this.text);
}

class TalkReference {
  TalkReference._();

  /// Wikimedia は連絡先の無いアクセスを弾く (実測で 429 が返る)。
  static const String _ua = 'HisatorNotebook/1.0 '
      '(https://github.com/PG-Darksan/Kamispec) interview-practice';

  static const Duration _shortTimeout = Duration(seconds: 12);

  // ───────────────────────── Web 下調べ ─────────────────────────

  /// [query] (学校名 / 会社名など) について Web から情報を集める。
  ///
  /// [lang] はアプリの言語コード (例 'ja')。 その言語版の Wikipedia を先に
  /// 見て、 空振りなら英語版も見る。 取れなければ空リストを返す
  /// (= 呼び出し側は今まで通り AI の知識だけで続ければよい)。
  static Future<List<TalkRefSource>> lookupWeb(
    String query, {
    String lang = 'ja',
    int maxChars = 6000,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    // 「◯◯大学 経営学部」 のように学部まで入れられることがある。
    // Wikipedia は学校名だけで引き、 検索は入力そのままで引く
    // (学部ページが公式サイト側にあることが多いため)。
    final primary = q.split(RegExp(r'[\s　]+')).first;
    final out = <TalkRefSource>[];
    String? officialUrl;
    // Wikidata の「公式ウェブサイト」 は本人の申告なので、 中身の照合は要らない。
    // 検索エンジン任せの時だけ、 別人のページを掴んでいないか確かめる。
    var officialTrusted = false;

    for (final code in <String>{lang.isEmpty ? 'ja' : lang, 'en'}) {
      try {
        final title = await _resolveTitle(primary, code);
        if (title == null) continue;
        final extract = await _wikiExtract(title, code);
        // 短いものは曖昧さ回避ページ (「◯◯を参照」 だけの記事) が多いので捨てる。
        if (extract != null && extract.trim().length > 300) {
          out.add(TalkRefSource(
              'Wikipedia ($code): $title', _clip(extract, maxChars)));
          officialUrl ??= await _wikidataOfficialUrl(title, code);
          officialTrusted = officialUrl != null;
          break;
        }
      } catch (_) {
        // この言語版は諦めて次へ。
      }
    }

    // Wikipedia に載っていない学校/企業もある (むしろそちらが本命)。
    if (officialUrl == null) {
      officialUrl = await _searchOfficialUrl(q);
      officialTrusted = false;
    }

    if (officialUrl != null) {
      final body = await _fetchPageText(officialUrl);
      if (body != null &&
          body.trim().length > 120 &&
          (officialTrusted || _looksRelevant(body, primary))) {
        out.add(TalkRefSource('公式サイト: $officialUrl', _clip(body, maxChars)));
      }
    }
    return out;
  }

  /// 記事名を決める。 完全一致 → 近似一致 → 全文検索 の順。
  ///
  /// いきなり全文検索に頼ると的外れな記事を掴む
  /// (実測: 「トヨタ自動車」 の 1 位が記事「自動車」 になった)。
  static Future<String?> _resolveTitle(String q, String lang) async {
    // ① その名前の記事がそのままあるか。
    final exact = await _get(Uri.https('$lang.wikipedia.org', '/w/api.php', {
      'action': 'query',
      'titles': q,
      'redirects': '1',
      'format': 'json',
      'utf8': '1',
    }));
    if (exact != null) {
      final pages = _pagesOf(exact);
      if (pages != null) {
        for (final v in pages.values) {
          if (v is Map && v['missing'] == null && v['title'] is String) {
            return v['title'] as String;
          }
        }
      }
    }
    // ② 近似一致 → ③ 全文検索。
    for (final what in const ['nearmatch', 'text']) {
      final s = await _get(Uri.https('$lang.wikipedia.org', '/w/api.php', {
        'action': 'query',
        'list': 'search',
        'srsearch': q,
        'srlimit': '1',
        'srwhat': what,
        'format': 'json',
        'utf8': '1',
      }));
      if (s == null) continue;
      final j = jsonDecode(s);
      if (j is! Map) continue;
      final list = (j['query'] as Map?)?['search'];
      if (list is! List || list.isEmpty) continue;
      final first = list.first;
      if (first is! Map) continue;
      final t = '${first['title'] ?? ''}'.trim();
      if (t.isEmpty) continue;
      if (what == 'nearmatch') return t;
      // 全文検索は関係ない記事も上位に来るので、 名前が重なる時だけ採る。
      final norm = q.replaceAll(RegExp(r'[\s　]'), '');
      if (t.contains(norm) || norm.contains(t)) return t;
      return null;
    }
    return null;
  }

  /// 取ってきたページが本当にその相手のものか、 ざっと見る。
  static bool _looksRelevant(String text, String name) {
    final n = name.replaceAll(RegExp(r'[\s　]'), '');
    if (n.length < 2) return true;
    final t = text.toLowerCase();
    if (t.contains(n.toLowerCase())) return true;
    // 「◯◯高等学校」 が公式では 「◯◯高校」 と書かれている等のゆらぎ対策。
    final head = n.substring(0, n.length < 4 ? n.length : 4).toLowerCase();
    return t.contains(head);
  }

  static Map? _pagesOf(String body) {
    try {
      final j = jsonDecode(body);
      if (j is! Map) return null;
      final query = j['query'];
      if (query is! Map) return null;
      final pages = query['pages'];
      return pages is Map ? pages : null;
    } catch (_) {
      return null;
    }
  }

  /// 記事本文をプレーンテキストで取る。
  static Future<String?> _wikiExtract(String title, String lang) async {
    final uri = Uri.https('$lang.wikipedia.org', '/w/api.php', {
      'action': 'query',
      'prop': 'extracts',
      'explaintext': '1',
      'exsectionformat': 'plain',
      'redirects': '1',
      'titles': title,
      'format': 'json',
      'utf8': '1',
    });
    final r = await _get(uri);
    if (r == null) return null;
    final j = jsonDecode(r);
    if (j is! Map) return null;
    final pages = (j['query'] as Map?)?['pages'];
    if (pages is! Map) return null;
    for (final v in pages.values) {
      if (v is Map && v['extract'] is String) return v['extract'] as String;
    }
    return null;
  }

  /// Wikidata の「公式ウェブサイト」 (P856) から公式 URL を取る。
  ///
  /// 記事の外部リンク (extlinks) は出典だらけで当てにならない
  /// (実測: 開成中学校・高等学校の 1 件目が漕艇協会のページだった)。
  static Future<String?> _wikidataOfficialUrl(String title, String lang) async {
    final pp = await _get(Uri.https('$lang.wikipedia.org', '/w/api.php', {
      'action': 'query',
      'prop': 'pageprops',
      'ppprop': 'wikibase_item',
      'redirects': '1',
      'titles': title,
      'format': 'json',
      'utf8': '1',
    }));
    if (pp == null) return null;
    String? qid;
    final pages = _pagesOf(pp);
    if (pages != null) {
      for (final v in pages.values) {
        if (v is! Map) continue;
        final props = v['pageprops'];
        if (props is Map && props['wikibase_item'] is String) {
          qid = props['wikibase_item'] as String;
        }
      }
    }
    if (qid == null || qid.isEmpty) return null;
    final cl = await _get(Uri.https('www.wikidata.org', '/w/api.php', {
      'action': 'wbgetclaims',
      'entity': qid,
      'property': 'P856',
      'format': 'json',
    }));
    if (cl == null) return null;
    try {
      final j = jsonDecode(cl);
      if (j is! Map) return null;
      final claims = (j['claims'] as Map?)?['P856'];
      if (claims is! List || claims.isEmpty) return null;
      for (final c in claims) {
        if (c is! Map) continue;
        final snak = c['mainsnak'];
        if (snak is! Map) continue;
        final dv = snak['datavalue'];
        if (dv is! Map) continue;
        final v = dv['value'];
        if (v is String && v.startsWith('http')) return v;
      }
    } catch (_) {}
    return null;
  }

  /// 検索結果から公式サイトらしい URL を選ぶ。
  ///
  /// 学校紹介サイトや百科事典は本人の言葉ではないので外す。
  static String? _pickOfficial(List<String> links) {
    const skip = [
      'wikipedia.org', 'wikimedia.org', 'wikidata.org', 'wikiwand',
      'archive.org', 'webcitation', 'chakuwiki',
      'twitter.com', 'x.com', 'facebook.com', 'instagram.com', 'youtube.com',
      'google.com', 'bing.com', 'duckduckgo.com', 'amazon.', 'doi.org',
      'nii.ac.jp', 'ndl.go.jp', 'linkedin.com', 'note.com', 'weblio',
      'minkou.jp', 'mynavi', 'rikunabi', 'benesse', 'inter-edu', 'juken',
      'goo.ne.jp', 'yahoo.co.jp', 'jsp.co.jp', 'en-japan', 'doda.jp',
    ];
    for (final l in links) {
      final low = l.toLowerCase();
      if (!low.startsWith('http')) continue;
      if (skip.any(low.contains)) continue;
      return l;
    }
    return null;
  }

  /// Wikipedia に無い相手の公式サイトを検索で探す (best effort)。
  static Future<String?> _searchOfficialUrl(String q) async {
    try {
      final uri = Uri.https('lite.duckduckgo.com', '/lite/', {
        'q': '$q 公式サイト',
      });
      final html = await _get(uri);
      if (html == null) return null;
      // lite 版は素の <a href="..."> で結果を並べる。 リダイレクタ経由の
      // 場合は uddg= に本来の URL が入っている。
      final links = <String>[];
      for (final m
          in RegExp(r'href="([^"]+)"', caseSensitive: false).allMatches(html)) {
        var href = m.group(1) ?? '';
        if (href.contains('uddg=')) {
          final u = Uri.tryParse(
              href.startsWith('//') ? 'https:$href' : href);
          final real = u?.queryParameters['uddg'];
          if (real != null && real.isNotEmpty) href = real;
        }
        if (href.startsWith('http')) links.add(_unescapeHtml(href));
      }
      return _pickOfficial(links);
    } catch (_) {
      return null;
    }
  }

  /// ページを取って本文だけのテキストにする。
  static Future<String?> _fetchPageText(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.isScheme('http') && !uri.isScheme('https')) {
      return null;
    }
    final html = await _get(uri);
    if (html == null) return null;
    return _htmlToText(html);
  }

  static Future<String?> _get(Uri uri) async {
    try {
      final r = await http.get(uri, headers: {
        'User-Agent': _ua,
        'Accept-Language': 'ja,en;q=0.8',
      }).timeout(_shortTimeout);
      if (r.statusCode != 200) return null;
      // 文字化け対策: Content-Type に charset が無くても UTF-8 で読み直す。
      try {
        return utf8.decode(r.bodyBytes, allowMalformed: true);
      } catch (_) {
        return r.body;
      }
    } catch (e) {
      debugPrint('下調べ取得失敗 ($uri): $e');
      return null;
    }
  }

  /// HTML からタグ・スクリプトを落として読める文にする。
  static String _htmlToText(String html) {
    var s = html;
    s = s.replaceAll(
        RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), ' ');
    s = s.replaceAll(
        RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), ' ');
    s = s.replaceAll(
        RegExp(r'<noscript[\s\S]*?</noscript>', caseSensitive: false), ' ');
    // 段落・見出し・改行は改行として残す (箇条書きが潰れないように)。
    s = s.replaceAll(
        RegExp(r'</(p|div|li|tr|h[1-6]|section|article)>',
            caseSensitive: false),
        '\n');
    s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    s = s.replaceAll(RegExp(r'<[^>]+>'), ' ');
    s = _unescapeHtml(s);
    s = s.replaceAll(RegExp(r'[ \t ]+'), ' ');
    s = s.replaceAll(RegExp(r'\n\s*\n\s*\n+'), '\n\n');
    return s.trim();
  }

  static String _unescapeHtml(String s) {
    var r = s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'");
    r = r.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
      final code = int.tryParse(m.group(1) ?? '');
      if (code == null || code < 32 || code > 0x10FFFF) return '';
      return String.fromCharCode(code);
    });
    return r;
  }

  static String _clip(String s, int max) =>
      s.length > max ? '${s.substring(0, max)}\n…(以下省略)' : s;

  // ─────────────────── AI アシスタント用の公開口 ───────────────────
  //
  // = ユーザー要望: 「Web を調べて読む」 を出来るようにする。
  //   面接練習で既に動いている取得部 (鍵不要・UA 必須) をそのまま使う。

  /// URL を 1 本読んで、 本文だけのテキストにして返す (読めなければ null)。
  static Future<String?> fetchPageText(String url, {int maxChars = 8000}) async {
    final t = await _fetchPageText(url);
    return t == null ? null : _clip(t, maxChars);
  }

  /// Web を検索して [{title, url}] を返す。
  ///
  /// まず DuckDuckGo の軽量版を読む (鍵不要)。 取れなければ Wikipedia の
  /// 検索 API に落とす (こちらは必ず動くが、 百科事典の記事だけ)。
  static Future<List<Map<String, String>>> searchWeb(String query,
      {int limit = 8, String lang = 'ja'}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final out = <Map<String, String>>[];
    final seen = <String>{};
    try {
      final html = await _get(Uri.https('lite.duckduckgo.com', '/lite/', {
        'q': q,
      }));
      if (html != null) {
        // lite 版は素の <a href="...">題名</a> で結果を並べる。
        final re = RegExp(r'<a[^>]+href="([^"]+)"[^>]*>([\s\S]*?)</a>',
            caseSensitive: false);
        for (final m in re.allMatches(html)) {
          var href = m.group(1) ?? '';
          if (href.contains('uddg=')) {
            final u =
                Uri.tryParse(href.startsWith('//') ? 'https:$href' : href);
            final real = u?.queryParameters['uddg'];
            if (real != null && real.isNotEmpty) href = real;
          }
          href = _unescapeHtml(href);
          if (!href.startsWith('http')) continue;
          final host = Uri.tryParse(href)?.host ?? '';
          if (host.contains('duckduckgo.com')) continue;
          if (!seen.add(href)) continue;
          final title = _htmlToText(m.group(2) ?? '').trim();
          out.add({'title': title.isEmpty ? href : _clip(title, 120), 'url': href});
          if (out.length >= limit) break;
        }
      }
    } catch (_) {/* 検索は best effort。 下の予備へ */}
    if (out.isNotEmpty) return out;
    // 予備: Wikipedia の検索 (鍵不要・必ず応答する)。
    try {
      final uri = Uri.https('$lang.wikipedia.org', '/w/api.php', {
        'action': 'query',
        'list': 'search',
        'srsearch': q,
        'srlimit': '$limit',
        'format': 'json',
        'formatversion': '2',
      });
      final body = await _get(uri);
      if (body != null) {
        final j = jsonDecode(body);
        final query = j is Map ? j['query'] : null;
        final hits = query is Map ? query['search'] : null;
        if (hits is List) {
          for (final h in hits) {
            if (h is! Map) continue;
            final t = '${h['title'] ?? ''}';
            if (t.isEmpty) continue;
            out.add({
              'title': t,
              'url': 'https://$lang.wikipedia.org/wiki/'
                  '${Uri.encodeComponent(t.replaceAll(' ', '_'))}',
            });
          }
        }
      }
    } catch (_) {}
    return out;
  }

  // ─────────────────── 手元の資料ファイル ───────────────────

  /// ユーザーが上げたファイルから本文テキストを取り出す。
  ///
  /// 対応: テキスト系 / pdf / docx / pptx / xlsx。 読めなければ null。
  static Future<String?> extractFileText(String path,
      {int maxChars = 12000}) async {
    final ext = path.contains('.')
        ? path.split('.').last.toLowerCase()
        : '';
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      if (_isTextLike(ext)) {
        String text;
        try {
          text = await file.readAsString();
        } catch (_) {
          // UTF-8 で読めない (Shift-JIS など) → バイト列から取り出す。
          text = String.fromCharCodes(await file.readAsBytes());
        }
        return _clip(text.trim(), maxChars);
      }
      final bytes = await file.readAsBytes();
      if (ext == 'pdf') {
        // 大きな PDF は解析が重いので、 別 isolate で処理する。
        final t = await compute(_pdfTextInIsolate, bytes);
        return t == null ? null : _clip(t.trim(), maxChars);
      }
      if (ext == 'docx') {
        return _clip(_ooxmlPartText(bytes, 'word/document.xml'), maxChars);
      }
      if (ext == 'pptx') {
        final archive = ZipDecoder().decodeBytes(bytes);
        final slides = archive.files
            .where((f) =>
                f.isFile &&
                RegExp(r'ppt/slides/slide\d+\.xml$').hasMatch(f.name))
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));
        final buf = StringBuffer();
        for (final f in slides) {
          buf.writeln(_stripXml(
              utf8.decode(f.content as List<int>, allowMalformed: true)));
        }
        return _clip(buf.toString().trim(), maxChars);
      }
      if (ext == 'xlsx') {
        // ★ = 動作検証の不具合「XLSX の数値セルが読み取りとフォルダー内検索
        //   から欠落する」。 共有文字列 (xl/sharedStrings.xml) には**文字の
        //   セルだけ**が入るので、 1・3・4 のような数値は 1 つも出て来ず、
        //   本文としても検索対象としても消えていた。 表として開いて全セルを
        //   歩く (読めない時だけ従来の道へ落とす)。
        try {
          final book = xls.Excel.decodeBytes(bytes);
          final buf = StringBuffer();
          for (final e in book.tables.entries) {
            buf.writeln('[${e.key}]');
            for (final row in e.value.rows) {
              final cells = [for (final c in row) xlsxCellToPlain(c?.value)];
              if (cells.any((c) => c.trim().isNotEmpty)) {
                buf.writeln(cells.join('\t'));
              }
            }
          }
          final t = buf.toString().trim();
          if (t.isNotEmpty) return _clip(t, maxChars);
        } catch (_) {
          // 壊れた xlsx / excel が開けない形 → 下の控えへ。
        }
        // ★ = 動作検証 2026-09-30「20 桁整数を含む xlsx の MCP 読込で、 表と
        //   数値が返らず共有文字列の重複除去一覧だけが返る」。
        //   原因は excel パッケージの読み手: 数値セルを必ず `int.parse` に
        //   掛けるので、 Dart の int に収まらない桁 (= 20 桁) で例外になり、
        //   表がまるごと諦められて上の catch に落ちていた。 諦める前に
        //   worksheet の XML を自分で読む ([_xlsxRowsFromXml]。 数値は書かれた
        //   文字のまま扱うので、 どんな桁でも落ちない・丸めない)。
        final manual = _xlsxRowsFromXml(bytes);
        if (manual.isNotEmpty) return _clip(manual, maxChars);
        return _clip(
            _ooxmlPartText(bytes, 'xl/sharedStrings.xml'), maxChars);
      }
    } catch (e) {
      debugPrint('資料の読み取りに失敗 ($path): $e');
    }
    return null;
  }

  /// xlsx の worksheet を**自分で**読んで、 1 行 = タブ区切りの文字にする。
  ///
  /// excel パッケージが開けなかった時の控え (= 動作検証 2026-09-30「20 桁
  /// 整数を含む xlsx で表が返らない」)。 あちらは数値セルを必ず `int.parse`
  /// に掛けるので、 Dart の int に収まらない桁で例外になり表を諦めてしまう。
  /// ここでは数値を**書かれている文字のまま**扱うので、 桁がいくら大きくても
  /// 落ちないし丸めない。
  ///
  /// ★ 読み手を足すだけで、 上の本筋 (excel パッケージ) は変えていない。
  ///   ふつうのファイルは今までどおりあちらが読む。
  /// ★ xml パッケージは直の依存に入っていないので、 正規表現で拾う
  ///   (取り出すのは `<row>` / `<c>` / `<v>` / `<f>` / `<t>` だけ)。
  static String _xlsxRowsFromXml(List<int> bytes) {
    String textOfT(String xml) {
      final buf = StringBuffer();
      for (final m
          in RegExp(r'<t[^>]*>(.*?)</t>', dotAll: true).allMatches(xml)) {
        buf.write(_unescapeHtml(m.group(1) ?? ''));
      }
      return buf.toString();
    }

    // 'B' → 1、 'AA' → 26 (0 から数えた列番号)。
    int colOf(String letters) {
      if (letters.isEmpty) return -1;
      var n = 0;
      for (final u in letters.codeUnits) {
        if (u < 65 || u > 90) return -1;
        n = n * 26 + (u - 64);
      }
      return n - 1;
    }

    int sheetNoOf(String name) =>
        int.tryParse(
            RegExp(r'sheet(\d+)\.xml$').firstMatch(name)?.group(1) ?? '') ??
        0;

    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      // ── 共有文字列 (<si> 1 つ = 1 件) ──
      final shared = <String>[];
      for (final f in archive.files) {
        if (f.isFile && f.name == 'xl/sharedStrings.xml') {
          final xml = utf8.decode(f.content as List<int>, allowMalformed: true);
          for (final m
              in RegExp(r'<si\b[^>]*>(.*?)</si>', dotAll: true).allMatches(xml)) {
            shared.add(textOfT(m.group(1) ?? ''));
          }
          break;
        }
      }
      // ── シートの名前 (workbook.xml に並んでいる順) ──
      final sheetNames = <String>[];
      for (final f in archive.files) {
        if (f.isFile && f.name == 'xl/workbook.xml') {
          final xml = utf8.decode(f.content as List<int>, allowMalformed: true);
          for (final m
              in RegExp(r'<sheet\b[^>]*\bname="([^"]*)"').allMatches(xml)) {
            sheetNames.add(_unescapeHtml(m.group(1) ?? ''));
          }
          break;
        }
      }
      final sheets = archive.files
          .where((f) =>
              f.isFile &&
              RegExp(r'xl/worksheets/sheet\d+\.xml$').hasMatch(f.name))
          .toList()
        ..sort((a, b) => sheetNoOf(a.name).compareTo(sheetNoOf(b.name)));
      final out = StringBuffer();
      for (int si = 0; si < sheets.length; si++) {
        final xml =
            utf8.decode(sheets[si].content as List<int>, allowMalformed: true);
        // ★ 中身のある行が 1 つでも出た時だけ見出しを書く。 見出しだけを
        //   返してしまうと、 本当は何も読めていないのに「読めた」 事に
        //   なって、 下の共有文字列の控えへ落ちなくなる。
        final lines = <String>[];
        for (final rowM
            in RegExp(r'<row\b[^>]*>(.*?)</row>', dotAll: true).allMatches(xml)) {
          final cells = <int, String>{};
          var maxCol = -1;
          for (final cM in RegExp(r'<c\b([^>]*?)(?:/>|>(.*?)</c>)',
                  dotAll: true)
              .allMatches(rowM.group(1) ?? '')) {
            final attrs = cM.group(1) ?? '';
            final inner = cM.group(2) ?? '';
            final ref =
                RegExp(r'\br="([A-Z]+)\d+"').firstMatch(attrs)?.group(1) ?? '';
            final col = colOf(ref);
            if (col < 0) continue;
            final type =
                RegExp(r'\bt="([^"]+)"').firstMatch(attrs)?.group(1) ?? 'n';
            final v = RegExp(r'<v[^>]*>(.*?)</v>', dotAll: true)
                .firstMatch(inner)
                ?.group(1);
            String text;
            if (type == 's') {
              final i = int.tryParse((v ?? '').trim());
              text = (i != null && i >= 0 && i < shared.length)
                  ? shared[i]
                  : '';
            } else if (type == 'inlineStr') {
              text = textOfT(inner);
            } else if (type == 'b') {
              text = (v ?? '').trim() == '1' ? 'TRUE' : 'FALSE';
            } else {
              // 数値 / 数式 / 文字列の結果。 数値は書かれた文字のまま。
              final fx = RegExp(r'<f[^>]*>(.*?)</f>', dotAll: true)
                  .firstMatch(inner)
                  ?.group(1);
              text = (v != null && v.trim().isNotEmpty)
                  ? _unescapeHtml(v.trim())
                  : (fx == null || fx.isEmpty ? '' : '=${_unescapeHtml(fx)}');
            }
            cells[col] = text;
            if (col > maxCol) maxCol = col;
          }
          if (maxCol < 0) continue;
          final line = [for (var i = 0; i <= maxCol; i++) cells[i] ?? ''];
          if (line.any((c) => c.trim().isNotEmpty)) lines.add(line.join('\t'));
        }
        if (lines.isEmpty) continue;
        // 名前の数が合う時だけ workbook.xml の名前を使う (ずれた推測はしない)。
        out.writeln(sheetNames.length == sheets.length
            ? '[${sheetNames[si]}]'
            : '[Sheet${si + 1}]');
        for (final l in lines) {
          out.writeln(l);
        }
      }
      return out.toString().trim();
    } catch (_) {
      return '';
    }
  }

  static bool _isTextLike(String ext) => const {
        'txt', 'md', 'markdown', 'csv', 'tsv', 'json', 'log', 'text',
        'html', 'htm', 'xml', 'yml', 'yaml', 'rtf',
      }.contains(ext);

  /// 添付できる拡張子 (ファイル選択ダイアログの絞り込み用)。
  static const List<String> allowedExtensions = [
    'txt', 'md', 'csv', 'tsv', 'json', 'log',
    'pdf', 'docx', 'pptx', 'xlsx', 'html', 'htm',
  ];

  /// 表のセル 1 つを素の文字にする。
  ///
  /// ★ 数値・日付・真偽・数式まで面倒を見る (= 動作検証の不具合「数値セルが
  ///   読み取りと検索から欠落する」)。 同じ物差しを画面側の読み取りでも使う
  ///   ので、 ここに 1 つだけ置く (双子を作らない)。
  /// ★ 小数は整数なら整数の形にする (= 3.0 を「3」 で探せるように)。
  static String xlsxCellToPlain(xls.CellValue? v) {
    if (v == null) return '';
    if (v is xls.TextCellValue) {
      // excel 4.x の TextCellValue.value は独自 TextSpan 型 → dynamic で走査。
      final buf = StringBuffer();
      void walk(dynamic span) {
        if (span == null) return;
        try {
          final t = span.text;
          if (t is String) buf.write(t);
        } catch (_) {}
        try {
          final children = span.children;
          if (children is Iterable) {
            for (final c in children) {
              walk(c);
            }
          }
        } catch (_) {}
      }

      walk(v.value);
      final r = buf.toString();
      return r.isEmpty ? v.value.toString() : r;
    }
    if (v is xls.IntCellValue) return v.value.toString();
    if (v is xls.DoubleCellValue) {
      final d = v.value;
      return d == d.truncateToDouble() ? d.toInt().toString() : d.toString();
    }
    if (v is xls.BoolCellValue) return v.value ? 'TRUE' : 'FALSE';
    if (v is xls.DateCellValue) {
      return '${v.year.toString().padLeft(4, '0')}-'
          '${v.month.toString().padLeft(2, '0')}-'
          '${v.day.toString().padLeft(2, '0')}';
    }
    if (v is xls.DateTimeCellValue) {
      return '${v.year.toString().padLeft(4, '0')}-'
          '${v.month.toString().padLeft(2, '0')}-'
          '${v.day.toString().padLeft(2, '0')} '
          '${v.hour.toString().padLeft(2, '0')}:'
          '${v.minute.toString().padLeft(2, '0')}';
    }
    if (v is xls.TimeCellValue) {
      return '${v.hour.toString().padLeft(2, '0')}:'
          '${v.minute.toString().padLeft(2, '0')}';
    }
    if (v is xls.FormulaCellValue) return '=${v.formula}';
    return v.toString();
  }

  static String _ooxmlPartText(List<int> bytes, String partPath) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      for (final f in archive.files) {
        if (f.isFile && f.name == partPath) {
          return _stripXml(
              utf8.decode(f.content as List<int>, allowMalformed: true));
        }
      }
    } catch (_) {}
    return '';
  }

  /// OOXML のタグを落とす。 段落 (`</w:p>` 等) は改行として残す。
  static String _stripXml(String xml) {
    var s = xml;
    s = s.replaceAll(RegExp(r'</w:p>|</a:p>|<w:br\s*/>|<a:br\s*/>'), '\n');
    s = s.replaceAll(RegExp(r'</si>'), '\n');
    s = s.replaceAll(RegExp(r'<[^>]+>'), '');
    s = _unescapeHtml(s);
    s = s.replaceAll(RegExp(r'[ \t]+'), ' ');
    s = s.replaceAll(RegExp(r'\n\s*\n\s*\n+'), '\n\n');
    return s.trim();
  }
}

/// isolate 側で PDF を開いて本文を取り出す (UI を止めないため)。
String? _pdfTextInIsolate(Uint8List bytes) {
  try {
    final doc = sfpdf.PdfDocument(inputBytes: bytes);
    try {
      return sfpdf.PdfTextExtractor(doc).extractText();
    } finally {
      doc.dispose();
    }
  } catch (_) {
    return null;
  }
}
