// 書籍をさがす所。
//
// = ユーザー要望「Kindle のヒットする検索結果がイマイチだから、 kindle
//   ボタンに書籍検索機能を設けて、 別で検索結果を手に入れて描画する」。
//
// ★ なぜ Amazon を直に読まないか: Amazon は自動取得を弾く (503 / 画像認証)。
//   同じ理由で Google の検索結果ページも取れない
//   (google_search_dialog.dart の覚書に実測が残っている)。
//   そこで**書誌データは鍵の要らない書誌 API から取り**、 Amazon は
//   「選んだ本を開く行き先」 としてだけ使う。
//
// ★ 使う先 (どちらも鍵なし):
//   1. Google Books … `volumes?q=` で題名・著者・出版社・表紙・ISBN が
//      まとめて取れる。 これを主にする。
//   2. openBD … 日本の書籍に強い。 ISBN が分かった物の補完に使う
//      (表紙が無い / 出版社が空の時だけ)。 全文検索は持っていないので
//      主には使えない。
//
// ★ 並べ替えは呼ぶ側 (provider) が Jev に任せる。 ここは取ってくるだけ。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// 見付かった 1 冊。
class BookHit {
  final String title;
  final String subtitle;
  final List<String> authors;
  final String publisher;

  /// 出版年月日 (取れた形のまま。 "2019" / "2019-04-01")。
  final String published;

  /// 表紙の URL (無ければ空)。
  final String thumbnail;

  /// 概要 (長いので呼ぶ側で切る)。
  final String description;

  /// ISBN-13 を優先。 無ければ ISBN-10、 どちらも無ければ空。
  final String isbn;

  final int pageCount;

  /// Google Books の詳細ページ (中身検索ができる)。
  final String infoLink;

  const BookHit({
    required this.title,
    this.subtitle = '',
    this.authors = const [],
    this.publisher = '',
    this.published = '',
    this.thumbnail = '',
    this.description = '',
    this.isbn = '',
    this.pageCount = 0,
    this.infoLink = '',
  });

  /// 画面に出す 1 行目。
  String get displayTitle =>
      subtitle.isEmpty ? title : '$title — $subtitle';

  /// 画面に出す 2 行目 (著者 / 出版社 / 年)。
  String get byline {
    final parts = <String>[
      if (authors.isNotEmpty) authors.join(', '),
      if (publisher.isNotEmpty) publisher,
      if (published.isNotEmpty) published.split('-').first,
    ];
    return parts.join(' · ');
  }

  /// Jev に渡す短い抜粋 (本文は送らない)。
  String get digest {
    final d = description.length > 180
        ? description.substring(0, 180)
        : description;
    return [displayTitle, byline, if (d.isNotEmpty) d].join(' / ');
  }

  BookHit copyWith({
    String? publisher,
    String? thumbnail,
    String? published,
  }) =>
      BookHit(
        title: title,
        subtitle: subtitle,
        authors: authors,
        publisher: publisher ?? this.publisher,
        published: published ?? this.published,
        thumbnail: thumbnail ?? this.thumbnail,
        description: description,
        isbn: isbn,
        pageCount: pageCount,
        infoLink: infoLink,
      );

  /// Kindle ストアでこの本をさがす URL。
  ///
  /// ★ ASIN は書誌 API では分からないので、 **店の検索**へ渡す。
  ///   ISBN があれば ISBN で引くのが一番当たる。
  String kindleSearchUrl({String host = 'www.amazon.co.jp'}) {
    final q = isbn.isNotEmpty ? isbn : '$title ${authors.join(' ')}'.trim();
    // digital-text = Kindle ストア。
    return 'https://$host/s?k=${Uri.encodeQueryComponent(q)}'
        '&i=digital-text';
  }
}

class BookSearch {
  BookSearch._();

  /// 連絡先を入れておく (入れないと弾く所がある)。
  static const String _ua = 'HisatorNotebook/1.0 '
      '(https://github.com/PG-Darksan/Kamispec) book-search';

  static const Duration _timeout = Duration(seconds: 12);

  /// [query] で本をさがす。 取れなければ空。
  ///
  /// [langRestrict] は 'ja' / 'en' など。 空なら指定しない。
  static Future<List<BookHit>> search(
    String query, {
    int limit = 20,
    String langRestrict = '',
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final n = limit.clamp(1, 40);
    final uri = Uri.https('www.googleapis.com', '/books/v1/volumes', {
      'q': q,
      'maxResults': '$n',
      'printType': 'books',
      'orderBy': 'relevance',
      if (langRestrict.isNotEmpty) 'langRestrict': langRestrict,
    });
    final body = await _get(uri);
    if (body == null) return const [];
    try {
      final j = jsonDecode(body);
      if (j is! Map) return const [];
      final items = j['items'];
      if (items is! List) return const [];
      final out = <BookHit>[];
      for (final it in items) {
        final hit = _fromGoogleVolume(it);
        if (hit != null) out.add(hit);
      }
      return out;
    } catch (e) {
      debugPrint('書籍検索の解釈に失敗: $e');
      return const [];
    }
  }

  /// 出版社や表紙が空の物を openBD で補う (日本の本に効く)。
  ///
  /// ★ ISBN が分かっている物だけ。 1 回のリクエストにまとめて渡せる。
  static Future<List<BookHit>> enrichWithOpenBd(List<BookHit> hits) async {
    final need = <String>[];
    for (final h in hits) {
      if (h.isbn.isEmpty) continue;
      if (h.publisher.isNotEmpty && h.thumbnail.isNotEmpty) continue;
      need.add(h.isbn);
      if (need.length >= 20) break;
    }
    if (need.isEmpty) return hits;
    final uri = Uri.https('api.openbd.jp', '/v1/get', {
      'isbn': need.join(','),
    });
    final body = await _get(uri);
    if (body == null) return hits;
    final extra = <String, ({String publisher, String cover, String pubdate})>{};
    try {
      final j = jsonDecode(body);
      if (j is! List) return hits;
      for (final e in j) {
        if (e is! Map) continue;
        final summary = e['summary'];
        if (summary is! Map) continue;
        final isbn = '${summary['isbn'] ?? ''}';
        if (isbn.isEmpty) continue;
        extra[isbn] = (
          publisher: '${summary['publisher'] ?? ''}',
          cover: '${summary['cover'] ?? ''}',
          pubdate: '${summary['pubdate'] ?? ''}',
        );
      }
    } catch (_) {
      return hits;
    }
    return [
      for (final h in hits)
        if (extra[h.isbn] == null)
          h
        else
          h.copyWith(
            publisher: h.publisher.isEmpty ? extra[h.isbn]!.publisher : null,
            thumbnail: h.thumbnail.isEmpty ? extra[h.isbn]!.cover : null,
            published: h.published.isEmpty ? extra[h.isbn]!.pubdate : null,
          )
    ];
  }

  static BookHit? _fromGoogleVolume(Object? raw) {
    if (raw is! Map) return null;
    final v = raw['volumeInfo'];
    if (v is! Map) return null;
    final title = '${v['title'] ?? ''}'.trim();
    if (title.isEmpty) return null;
    final authors = <String>[];
    final a = v['authors'];
    if (a is List) {
      for (final e in a) {
        final t = '$e'.trim();
        if (t.isNotEmpty) authors.add(t);
      }
    }
    var isbn13 = '';
    var isbn10 = '';
    final ids = v['industryIdentifiers'];
    if (ids is List) {
      for (final e in ids) {
        if (e is! Map) continue;
        final type = '${e['type'] ?? ''}';
        final id = '${e['identifier'] ?? ''}'.replaceAll('-', '');
        if (type == 'ISBN_13' && isbn13.isEmpty) isbn13 = id;
        if (type == 'ISBN_10' && isbn10.isEmpty) isbn10 = id;
      }
    }
    var thumb = '';
    final im = v['imageLinks'];
    if (im is Map) {
      thumb = '${im['thumbnail'] ?? im['smallThumbnail'] ?? ''}';
      // http で返ることがあるので上げておく (混在コンテンツで出ない)。
      if (thumb.startsWith('http://')) {
        thumb = thumb.replaceFirst('http://', 'https://');
      }
    }
    return BookHit(
      title: title,
      subtitle: '${v['subtitle'] ?? ''}'.trim(),
      authors: authors,
      publisher: '${v['publisher'] ?? ''}'.trim(),
      published: '${v['publishedDate'] ?? ''}'.trim(),
      thumbnail: thumb,
      description: '${v['description'] ?? ''}'.trim(),
      isbn: isbn13.isNotEmpty ? isbn13 : isbn10,
      pageCount: (v['pageCount'] as num?)?.toInt() ?? 0,
      infoLink: '${v['infoLink'] ?? ''}',
    );
  }

  static Future<String?> _get(Uri uri) async {
    try {
      final r = await http.get(uri, headers: {
        'User-Agent': _ua,
        'Accept-Language': 'ja,en;q=0.8',
      }).timeout(_timeout);
      if (r.statusCode != 200) {
        debugPrint('書籍検索 ${r.statusCode}: $uri');
        return null;
      }
      try {
        return utf8.decode(r.bodyBytes, allowMalformed: true);
      } catch (_) {
        return r.body;
      }
    } catch (e) {
      debugPrint('書籍検索の取得に失敗 ($uri): $e');
      return null;
    }
  }
}
