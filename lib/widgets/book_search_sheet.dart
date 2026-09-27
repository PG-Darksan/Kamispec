// 書籍をさがす画面。
//
// = ユーザー要望「Kindle のヒットする検索結果がイマイチだから、 kindle
//   ボタンに書籍検索機能を設けて、 別で検索結果を手に入れて描画する」。
//
// ★ Amazon の検索結果を読み取るのではなく、 鍵の要らない書誌 API
//   ([BookSearch]) から題名・著者・出版社・表紙・ISBN を取ってきて
//   **アプリの一覧として描く**。 選んだ本だけを Kindle ストアの検索
//   (ISBN があれば ISBN) で開く。
//
// ★ Jev (判断補助) が入っていれば、 探し物に近い順へ並べ替え、
//   「候補の中に無さそう」 も伝える (= 検索結果がイマイチ、 への対処)。
//
// ★ モバイルは WebView の上に重ねない (Android は WebView の上の
//   ダイアログが触れなくなる)。 呼ぶ側が全画面で出す。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/mind_map_provider.dart';
import '../services/book_search.dart';

class BookSearchSheet extends StatefulWidget {
  const BookSearchSheet({
    super.key,
    this.initialQuery = '',
    required this.onOpen,
    this.onOpenLibrary,
  });

  final String initialQuery;

  /// 「本棚を開く」 (= 今までの Kindle ボタンの動き)。
  final VoidCallback? onOpenLibrary;

  /// 選ばれた本を開く (呼ぶ側がアプリ内ブラウザへ渡す)。
  final void Function(BookHit hit, String url) onOpen;

  /// 出す。 戻り値は使わない。
  static Future<void> show(
    BuildContext context, {
    String initialQuery = '',
    required void Function(BookHit hit, String url) onOpen,
    VoidCallback? onOpenLibrary,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: const Color(0xFF12121F),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 760),
          child: BookSearchSheet(
            initialQuery: initialQuery,
            onOpen: onOpen,
            onOpenLibrary: onOpenLibrary,
          ),
        ),
      ),
    );
  }

  @override
  State<BookSearchSheet> createState() => _BookSearchSheetState();
}

class _BookSearchSheetState extends State<BookSearchSheet> {
  late final TextEditingController _q =
      TextEditingController(text: widget.initialQuery);
  final FocusNode _focus = FocusNode();

  bool _loading = false;
  String _error = '';

  /// 'found' / 'partial' / 'absent' / 'unknown' (Jev の「有るか」)。
  String _verdict = 'unknown';
  List<BookHit> _hits = const [];
  bool _searched = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _run());
    } else {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _focus.requestFocus());
    }
  }

  @override
  void dispose() {
    _q.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final query = _q.text.trim();
    if (query.isEmpty || _loading) return;
    setState(() {
      _loading = true;
      _error = '';
      _searched = true;
    });
    final provider = context.read<MindMapProvider>();
    try {
      final r = await provider.searchBooks(query);
      if (!mounted) return;
      setState(() {
        _hits = r.hits;
        _verdict = r.verdict;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MindMapProvider>();
    return Column(mainAxisSize: MainAxisSize.min, children: [
      // ── 見出し ──
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
        child: Row(children: [
          const Icon(Icons.menu_book_rounded,
              color: Color(0xFFFFB74D), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(provider.t('book.title'),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700)),
          ),
          // 今までどおり本棚をそのまま開く道も残す (= ボタンの元の動き)。
          if (widget.onOpenLibrary != null)
            TextButton.icon(
              onPressed: () {
                Navigator.of(context).maybePop();
                widget.onOpenLibrary!();
              },
              icon: const Icon(Icons.collections_bookmark_rounded, size: 15),
              label: Text(provider.t('book.library'),
                  style: const TextStyle(fontSize: 12)),
            ),
          IconButton(
            icon: const Icon(Icons.close_rounded,
                color: Colors.white54, size: 20),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ]),
      ),
      // ── 探す欄 ──
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _q,
              focusNode: _focus,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _run(),
              decoration: InputDecoration(
                isDense: true,
                hintText: provider.t('book.hint'),
                hintStyle:
                    const TextStyle(color: Colors.white38, fontSize: 13),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.06),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _loading ? null : _run,
            icon: const Icon(Icons.search_rounded, size: 17),
            label: Text(provider.t('book.search')),
          ),
        ]),
      ),
      // ── Jev の「候補の中に無さそう」 の注意書き ──
      if (!_loading && _searched && _verdict == 'absent')
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Row(children: [
            const Icon(Icons.info_outline_rounded,
                size: 14, color: Color(0xFFFFB74D)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(provider.t('book.maybeAbsent'),
                  style: const TextStyle(
                      color: Color(0xFFFFB74D), fontSize: 11.5)),
            ),
          ]),
        ),
      const Divider(color: Colors.white12, height: 1),
      // ── 一覧 ──
      Expanded(child: _buildBody(provider)),
    ]);
  }

  Widget _buildBody(MindMapProvider provider) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
      );
    }
    if (_error.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Text('${provider.t('book.failed')}\n$_error',
            style: const TextStyle(color: Color(0xFFE57373), fontSize: 12.5)),
      );
    }
    if (!_searched) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Text(provider.t('book.hint'),
            style: const TextStyle(color: Colors.white38, fontSize: 12.5)),
      );
    }
    if (_hits.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Text(provider.t('book.none'),
            style: const TextStyle(color: Colors.white54, fontSize: 12.5)),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: _hits.length,
      separatorBuilder: (_, __) =>
          const Divider(color: Colors.white10, height: 1),
      itemBuilder: (_, i) => _row(provider, _hits[i]),
    );
  }

  Widget _row(MindMapProvider provider, BookHit h) {
    return InkWell(
      onTap: () {
        final url = h.kindleSearchUrl(host: _amazonHost(provider));
        Navigator.of(context).maybePop();
        widget.onOpen(h, url);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // 表紙 (無い本も多いので、 無ければ枠だけ)。
          SizedBox(
            width: 44,
            height: 62,
            child: h.thumbnail.isEmpty
                ? Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Icon(Icons.menu_book_outlined,
                        size: 18, color: Colors.white24),
                  )
                : ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.network(
                      h.thumbnail,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        color: Colors.white.withValues(alpha: 0.06),
                      ),
                    ),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(h.displayTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600)),
                  if (h.byline.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(h.byline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 11.5)),
                  ],
                  if (h.description.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(h.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 11)),
                  ],
                ]),
          ),
          const SizedBox(width: 8),
          Column(children: [
            const Icon(Icons.open_in_new_rounded,
                size: 15, color: Colors.white38),
            const SizedBox(height: 4),
            if (h.isbn.isNotEmpty)
              Text('ISBN',
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.24),
                      fontSize: 9)),
          ]),
        ]),
      ),
    );
  }

  /// 言語から Amazon の地域を選ぶ (Kindle ストアの検索先)。
  String _amazonHost(MindMapProvider provider) {
    switch (provider.appLanguage) {
      case 'ja':
        return 'www.amazon.co.jp';
      case 'de':
        return 'www.amazon.de';
      case 'fr':
        return 'www.amazon.fr';
      case 'es':
        return 'www.amazon.es';
      case 'pt':
        return 'www.amazon.com.br';
      case 'zh':
        return 'www.amazon.cn';
      default:
        return 'www.amazon.com';
    }
  }
}
