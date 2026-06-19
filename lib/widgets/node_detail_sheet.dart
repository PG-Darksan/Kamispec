import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/mind_map_node.dart';
import '../providers/mind_map_provider.dart';
import '../widgets/node_widget.dart';

class NodeDetailSheet extends StatefulWidget {
  final MindMapNode node;
  final int initialTabIndex;
  const NodeDetailSheet(
      {super.key, required this.node, this.initialTabIndex = 0});

  @override
  State<NodeDetailSheet> createState() => _NodeDetailSheetState();
}

class _NodeDetailSheetState extends State<NodeDetailSheet>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late TextEditingController _titleCtrl;
  late TextEditingController _memoCtrl;
  late TextEditingController _linkCtrl;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
        length: 3, vsync: this, initialIndex: widget.initialTabIndex);
    _titleCtrl = TextEditingController(text: widget.node.title);
    _memoCtrl = TextEditingController(text: widget.node.memoText ?? '');
    final existingLink = (widget.node.linkUrl ?? '').isNotEmpty
        ? widget.node.linkUrl!
        : (widget.node.youtubeUrl ?? '');
    _linkCtrl = TextEditingController(text: existingLink);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _titleCtrl.dispose();
    _memoCtrl.dispose();
    _linkCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final provider = context.read<MindMapProvider>();
    provider.updateNodeTitle(widget.node.id, _titleCtrl.text.trim());
    provider.updateNodeMemo(widget.node.id, _memoCtrl.text.trim());
    final url = _linkCtrl.text.trim();
    final videoId = NodeWidget.extractVideoId(url);
    final isImage = NodeWidget.isImageUrl(url);
    if (videoId != null) {
      // YouTube/Shorts 動画 → 動画フィールドに保存（既存サムネイル描画ルートで埋め込み）
      provider.updateNodeYoutube(widget.node.id, url);
      provider.updateNodeLink(widget.node.id, '');
      // attachment は触らない（既存のローカル添付があれば残す）
    } else if (isImage) {
      // 画像 URL → attachmentPath に格納してノード内に埋め込み表示
      // URL 末尾のファイル名部分を attachmentName とする
      String name = url;
      try {
        final u = Uri.parse(url);
        if (u.pathSegments.isNotEmpty) name = u.pathSegments.last;
      } catch (_) {}
      provider.updateNodeAttachment(widget.node.id, url, name);
      provider.updateNodeLink(widget.node.id, '');
      provider.updateNodeYoutube(widget.node.id, '');
    } else {
      // 通常リンク
      provider.updateNodeLink(widget.node.id, url);
      provider.updateNodeYoutube(widget.node.id, '');
    }
    // ユーザー要望: 編集でテキストが伸びて周囲のノードと重なり見えなくなる
    //   問題への対応。 タイトル/メモ確定後の最終サイズで重なりを解消する。
    provider.resolveNodeOverlaps(widget.node.id);
    Navigator.pop(context);
  }

  void _showColorPicker() {
    Color pickerColor = widget.node.color;
    final provider = context.read<MindMapProvider>();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(provider.t('node.pickColor')),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: pickerColor,
            onColorChanged: (c) => pickerColor = c,
            pickerAreaHeightPercent: 0.8,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(provider.t('node.cancel')),
          ),
          ElevatedButton(
            onPressed: () {
              context
                  .read<MindMapProvider>()
                  .updateNodeColor(widget.node.id, pickerColor);
              Navigator.pop(ctx);
            },
            child: Text(provider.t('node.confirm')),
          ),
        ],
      ),
    );
  }

  void _openLinkEmbed(String url) {
    final videoId = NodeWidget.extractVideoId(url);
    if (videoId != null) {
      // YouTube → WebView
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.black,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (_) => _WebViewSheet(
            url: 'https://www.youtube.com/watch?v=$videoId'),
      );
    } else {
      // 汎用リンク → 外部ブラウザ
      final uri = Uri.tryParse(url);
      if (uri != null) {
        launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scrollController) {
        return Focus(
          autofocus: true,
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.escape) {
              // Escでも保存して閉じる（途中まで変更したものを破棄しない）
              _save();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Container(
            decoration: const BoxDecoration(
              color: Color(0xFF1E1E2E),
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(
              children: [
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 10),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: _showColorPicker,
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: widget.node.color,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white30),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _titleCtrl,
                          // タイトルでも改行を許す (モバイルでの AI 生成長文タイトルや
                          // ユーザーが意図的に折り返したいケース向け)
                          maxLines: null,
                          minLines: 1,
                          keyboardType: TextInputType.multiline,
                          textInputAction: TextInputAction.newline,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                          decoration: InputDecoration(
                            hintText: context.read<MindMapProvider>().t('node.hintTitle'),
                            hintStyle: const TextStyle(color: Colors.white38),
                            border: InputBorder.none,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.check_circle,
                            color: Color(0xFF6C63FF)),
                        onPressed: _save,
                      ),
                    ],
                  ),
                ),
                Builder(builder: (ctx) {
                  final p = ctx.read<MindMapProvider>();
                  return TabBar(
                    controller: _tabController,
                    indicatorColor: const Color(0xFF6C63FF),
                    labelColor: Colors.white,
                    unselectedLabelColor: Colors.white38,
                    tabs: [
                      Tab(icon: const Icon(Icons.info_outline, size: 20),
                          text: p.t('node.tabInfo')),
                      Tab(icon: const Icon(Icons.notes, size: 20),
                          text: p.t('node.tabMemo')),
                      Tab(icon: const Icon(Icons.link_rounded, size: 20),
                          text: p.t('node.tabLink')),
                    ],
                  );
                }),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildInfoTab(),
                      _buildMemoTab(scrollController),
                      _buildLinkTab(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildInfoTab() {
    final node = context.watch<MindMapProvider>().nodes[widget.node.id];
    if (node == null) return const SizedBox();
    final provider = context.read<MindMapProvider>();
    final tNone = provider.t('node.none');
    final linkText = (node.linkUrl ?? '').isNotEmpty
        ? node.linkUrl!
        : (node.youtubeUrl ?? '').isNotEmpty
            ? node.youtubeUrl!
            : tNone;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _infoTile(provider.t('node.fieldTitle'), node.title),
          _infoTile(provider.t('node.fieldMemo'),
              (node.memoText ?? '').isEmpty ? tNone : node.memoText!),
          _infoTile(provider.t('node.fieldLink'), linkText),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _showColorPicker,
              icon: Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                    color: node.color, shape: BoxShape.circle),
              ),
              label: Text(provider.t('node.changeColor'),
                  style: const TextStyle(color: Colors.white70)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.white24),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoTile(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(color: Colors.white38, fontSize: 11)),
          const SizedBox(height: 4),
          Text(value,
              style: const TextStyle(color: Colors.white, fontSize: 14)),
        ],
      ),
    );
  }

  /// メモ本文中の URL を検出して、最初の「埋め込み可能」(画像/動画) URL を返す。
  /// 通常のリンク URL は埋め込み表示されないので対象外。
  String? _detectEmbeddableUrlInMemo() {
    final text = _memoCtrl.text;
    if (text.isEmpty) return null;
    // ざっくり URL を抽出（半角空白・改行・全角空白で区切る）
    final tokens = text.split(RegExp(r'[\s\u3000]+'));
    for (final t in tokens) {
      final s = t.trim();
      if (!(s.startsWith('http://') || s.startsWith('https://'))) continue;
      if (NodeWidget.extractVideoId(s) != null ||
          NodeWidget.isImageUrl(s) ||
          NodeWidget.isMp4Url(s)) {
        return s;
      }
    }
    return null;
  }

  /// メモから検出された URL を「リンク」フィールドに移動し、メモからはその
  /// 1 件を除去する。タブも自動的にリンクタブに切り替えてプレビュー表示。
  void _moveMemoUrlToLink(String url) {
    // メモから該当 URL を削除（前後の空白も詰める）
    final text = _memoCtrl.text;
    final newText = text
        .replaceAll(url, '')
        // 連続改行を整理
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    _memoCtrl.text = newText;
    _linkCtrl.text = url;
    setState(() {});
    // リンクタブ (index=2) に切り替え
    _tabController.animateTo(2);
  }

  Widget _buildMemoTab(ScrollController scrollController) {
    final detectedUrl = _detectEmbeddableUrlInMemo();
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // ── メモに画像/動画 URL があったら、リンク欄に移動して埋め込みする提案 ──
          if (detectedUrl != null && _linkCtrl.text.trim().isEmpty)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF43B97F).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: const Color(0xFF43B97F).withValues(alpha: 0.4)),
              ),
              child: Row(children: [
                Icon(
                  NodeWidget.extractVideoId(detectedUrl) != null
                      ? Icons.play_circle_outline_rounded
                      : (NodeWidget.isImageUrl(detectedUrl)
                          ? Icons.image_outlined
                          : Icons.videocam_outlined),
                  color: const Color(0xFF43B97F),
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    detectedUrl,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 12),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => _moveMemoUrlToLink(detectedUrl),
                  style: TextButton.styleFrom(
                    backgroundColor:
                        const Color(0xFF43B97F).withValues(alpha: 0.25),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    minimumSize: const Size(0, 28),
                  ),
                  child: const Text('埋め込み',
                      style: TextStyle(fontSize: 11)),
                ),
              ]),
            ),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
              ),
              child: TextField(
                controller: _memoCtrl,
                maxLines: null,
                expands: true,
                // 入力ごとに「URL 検出バナー」の表示を更新するため setState
                onChanged: (_) => setState(() {}),
                // モバイルでの改行入力を確実にするため明示指定。
                // これがないと Android キーボードによっては Enter が「完了」に
                // 割り当てられ、改行が入らないことがある。
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 14),
                  hintText: context.read<MindMapProvider>().t('node.hintMemo'),
                  hintStyle: const TextStyle(color: Colors.white38),
                  border: InputBorder.none,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_outlined),
              label: Text(context.read<MindMapProvider>().t('node.save')),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6C63FF),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLinkTab() {
    final url = _linkCtrl.text.trim();
    final videoId = NodeWidget.extractVideoId(url);
    final isImageUrl = NodeWidget.isImageUrl(url);
    final hasUrl = url.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: TextField(
                    controller: _linkCtrl,
                    style:
                        const TextStyle(color: Colors.white, fontSize: 14),
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      hintText: context.read<MindMapProvider>().t('node.hintUrl'),
                      hintStyle: const TextStyle(color: Colors.white38),
                      border: InputBorder.none,
                      // 入力中の URL の種別をアイコンで示すと、ユーザーは
                      // 「これは画像/動画/通常リンクとして識別されている」
                      // ことが一目で分かる。
                      prefixIcon: Icon(
                        videoId != null
                            ? Icons.play_circle_outline
                            : (isImageUrl
                                ? Icons.image_outlined
                                : Icons.link),
                        color: videoId != null
                            ? const Color(0xFFFF6B6B)
                            : (isImageUrl
                                ? const Color(0xFF43B97F)
                                : Colors.white38),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () {
                  final prov = context.read<MindMapProvider>();
                  final inputUrl = _linkCtrl.text.trim();
                  final vid = NodeWidget.extractVideoId(inputUrl);
                  final isImg = NodeWidget.isImageUrl(inputUrl);
                  if (vid != null) {
                    prov.updateNodeYoutube(widget.node.id, inputUrl);
                    prov.updateNodeLink(widget.node.id, '');
                  } else if (isImg) {
                    String name = inputUrl;
                    try {
                      final u = Uri.parse(inputUrl);
                      if (u.pathSegments.isNotEmpty) name = u.pathSegments.last;
                    } catch (_) {}
                    prov.updateNodeAttachment(widget.node.id, inputUrl, name);
                    prov.updateNodeLink(widget.node.id, '');
                    prov.updateNodeYoutube(widget.node.id, '');
                  } else {
                    prov.updateNodeLink(widget.node.id, inputUrl);
                    prov.updateNodeYoutube(widget.node.id, '');
                  }
                  setState(() {});
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4FC3F7),
                  padding: const EdgeInsets.symmetric(
                      vertical: 14, horizontal: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Icon(Icons.save_outlined, color: Colors.white),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: hasUrl
                  ? GestureDetector(
                      onTap: () => _openLinkEmbed(url),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (videoId != null)
                            Image.network(
                              NodeWidget.thumbnailUrl(videoId),
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(
                                color: Colors.black54,
                                child: const Center(
                                  child: Icon(Icons.broken_image_outlined,
                                      color: Colors.white38, size: 48),
                                ),
                              ),
                            )
                          else if (isImageUrl)
                            // 画像 URL → ネットワーク画像をプレビュー表示
                            Container(
                              color: const Color(0xFF0F0F1F),
                              child: Image.network(
                                url,
                                fit: BoxFit.contain,
                                errorBuilder: (_, __, ___) => Container(
                                  color: Colors.black54,
                                  child: const Center(
                                    child: Icon(Icons.broken_image_outlined,
                                        color: Colors.white38, size: 48),
                                  ),
                                ),
                                loadingBuilder: (_, child, progress) {
                                  if (progress == null) return child;
                                  return const Center(
                                    child: CircularProgressIndicator(
                                        color: Colors.white38),
                                  );
                                },
                              ),
                            )
                          else
                            Container(
                              color: const Color(0xFF1A1A30),
                              child: Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.language_rounded,
                                        color: Colors.white38, size: 48),
                                    const SizedBox(height: 8),
                                    Text(
                                      Uri.tryParse(url)?.host ?? url,
                                      style: const TextStyle(
                                          color: Colors.white54, fontSize: 13),
                                      textAlign: TextAlign.center,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          // 画像 URL のときは「タップで開く」オーバーレイは
                          // 邪魔になるので非表示
                          if (!isImageUrl)
                            Container(
                              color: Colors.black.withValues(alpha: 0.3),
                              child: Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      videoId != null
                                          ? Icons.play_circle_fill_rounded
                                          : Icons.open_in_browser_rounded,
                                      color: Colors.white,
                                      size: 56,
                                    ),
                                    const SizedBox(height: 8),
                                    Text(context.read<MindMapProvider>().t('node.tapToOpen'),
                                        style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 13)),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    )
                  : Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.link_rounded,
                                color: Colors.white24, size: 48),
                            const SizedBox(height: 12),
                            Text(
                              context.read<MindMapProvider>().t('node.urlHelp'),
                              style: const TextStyle(
                                  color: Colors.white38, fontSize: 13),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
          ),
          if (hasUrl) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => _openLinkEmbed(url),
                icon: Icon(videoId != null
                    ? Icons.play_arrow_rounded
                    : Icons.open_in_browser_rounded),
                label: Text(videoId != null
                    ? context.read<MindMapProvider>().t('node.openVideo')
                    : context.read<MindMapProvider>().t('node.openLink')),
                style: ElevatedButton.styleFrom(
                  backgroundColor: videoId != null
                      ? const Color(0xFFFF0000)
                      : const Color(0xFF4FC3F7),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_outlined),
              label: Text(context.read<MindMapProvider>().t('node.saveAndClose')),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6C63FF),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── 汎用 WebView シート ────────────────────────────────────────────────────

class _WebViewSheet extends StatefulWidget {
  final String url;
  const _WebViewSheet({required this.url});

  @override
  State<_WebViewSheet> createState() => _WebViewSheetState();
}

class _WebViewSheetState extends State<_WebViewSheet> {
  late final WebViewController _controller;
  bool _loading = true;
  String _currentTitle = '';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setUserAgent(
          'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36')
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (url) {
          if (mounted) setState(() => _loading = false);
          _controller.getTitle().then((title) {
            if (mounted && title != null) {
              setState(() => _currentTitle = title);
            }
          });
        },
        onNavigationRequest: (request) {
          return NavigationDecision.navigate;
        },
      ))
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.of(context).size.height;
    final uri = Uri.tryParse(widget.url);
    final host = uri?.host ?? widget.url;

    return SizedBox(
      height: screenH * 0.85,
      child: Column(
        children: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 10),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: const BoxDecoration(
                      color: Color(0xFF4FC3F7), shape: BoxShape.circle),
                  child: const Icon(Icons.language_rounded,
                      color: Colors.white, size: 16),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                      _currentTitle.isNotEmpty ? _currentTitle : host,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis),
                ),
                IconButton(
                  icon:
                      const Icon(Icons.close, color: Colors.white54, size: 20),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                ClipRRect(
                  borderRadius:
                      const BorderRadius.vertical(bottom: Radius.circular(20)),
                  child: WebViewWidget(controller: _controller),
                ),
                if (_loading)
                  const Center(
                    child: CircularProgressIndicator(
                        valueColor:
                            AlwaysStoppedAnimation<Color>(Color(0xFF4FC3F7))),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
