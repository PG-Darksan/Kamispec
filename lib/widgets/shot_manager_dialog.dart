// 自動操作で撮ったスクショの管理画面 (= ユーザー要望: 「スクショした画像が
// どこにあるのか分かりにくい」「PDF にする前に画像の編集やら並び順を変えたり
// したい」)。
//
// できること:
//   ・保存フォルダの表示 / エクスプローラーで開く
//   ・サムネイル一覧、 並べ替え (ドラッグ or ↑↓)、 削除
//   ・回転 (90° 単位) / 左右反転 / 余白トリミング (上下左右を % で切る)
//   ・選んだ順で 1 つの PDF に書き出す
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sfpdf;

import '../providers/mind_map_provider.dart';

/// スクショの保存先ルートディレクトリ (自動操作と共通)。
Future<Directory> automationShotsDir() async {
  final base = await getApplicationDocumentsDirectory();
  final dir = Directory('${base.path}/automation_shots');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

/// 自動操作で作ったファイルの置き場 (= ユーザー要望: ファイルを作成して
/// そのままアップロードできるように)。
Future<Directory> automationFilesDir() async {
  final base = await getApplicationDocumentsDirectory();
  final dir = Directory('${base.path}/automation_files');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

/// フロー実行 1 回ぶんの保存先を作る (= ユーザー要望: 実行の度に別フォルダ)。
/// 例: automation_shots/run_20260802_143012
Future<Directory> newAutomationRunDir() async {
  final root = await automationShotsDir();
  final t = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final name = 'run_${t.year}${two(t.month)}${two(t.day)}_'
      '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  final dir = Directory('${root.path}/$name');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

class ShotManagerDialog extends StatefulWidget {
  const ShotManagerDialog({super.key});

  /// [useRootNavigator] を false にすると、 一番近い Navigator に出る。
  ///
  /// ★ 自動操作を「浮かせて」 開いている時はこれが要る
  ///   (= ユーザー報告: スクショ管理が開けない)。 浮遊窓は
  ///   根っこの Overlay に挿されているので、 根っこの Navigator に
  ///   積んだ窓はその下に隠れてしまう。
  static Future<void> show(BuildContext context,
      {bool useRootNavigator = true}) {
    return showDialog<void>(
      context: context,
      useRootNavigator: useRootNavigator,
      barrierColor: Colors.black87,
      builder: (_) => const ShotManagerDialog(),
    );
  }

  @override
  State<ShotManagerDialog> createState() => _ShotManagerDialogState();
}

class _ShotManagerDialogState extends State<ShotManagerDialog> {
  final List<String> _paths = [];
  final Set<String> _selected = {};
  String _dirPath = '';

  /// 大きく表示する 1 枚 (= ユーザー要望: 画像の中身が小さくて見えない)。
  String? _previewPath;

  /// Shift 範囲選択の起点 index (= ユーザー要望: まとめて選択して削除)。
  int _anchorIndex = 0;

  /// 表示中のフォルダ (null = ルート)。 実行ごとのフォルダを切り替える
  /// (= ユーザー要望: フロー実行の度に別フォルダ / フォルダ間でやり取り)。
  String? _currentDir;
  final List<String> _dirs = [];

  /// 初回だけ最新の実行フォルダを自動で開く (= ユーザー要望: 直前に取った
  /// スクショのフォルダが開かれてほしい)。
  bool _pickedInitialDir = false;
  bool _busy = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final root = await automationShotsDir();
    // サブフォルダ (実行ごと) を集める
    _dirs
      ..clear()
      ..addAll(root
          .listSync()
          .whereType<Directory>()
          .map((d) => d.path)
          .toList()
        ..sort());
    if (_currentDir != null && !_dirs.contains(_currentDir)) {
      _currentDir = null;
    }
    // 名前が run_YYYYMMDD_HHMMSS なので、 末尾が最新。
    if (!_pickedInitialDir) {
      _pickedInitialDir = true;
      if (_dirs.isNotEmpty) _currentDir = _dirs.last;
    }
    final dir =
        _currentDir == null ? root : Directory(_currentDir!);
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) {
          final l = f.path.toLowerCase();
          return l.endsWith('.png') || l.endsWith('.jpg') ||
              l.endsWith('.jpeg');
        })
        .toList()
      // ファイル名の数字部分で並べる (文字列順だと 10 が 2 より前に来る
      // = ユーザー報告の「順番がおかしい」)。
      ..sort((a, b) {
        int num(String path) {
          final name = path.split(Platform.pathSeparator).last;
          final m = RegExp(r'(\d+)').firstMatch(name);
          return m == null ? 1 << 30 : int.parse(m.group(1)!);
        }

        final c = num(a.path).compareTo(num(b.path));
        return c != 0 ? c : a.path.compareTo(b.path);
      });
    if (!mounted) return;
    setState(() {
      _dirPath = dir.path;
      _paths
        ..clear()
        ..addAll(files.map((f) => f.path));
      _selected.removeWhere((p) => !_paths.contains(p));
      if (_previewPath == null || !_paths.contains(_previewPath)) {
        _previewPath = _paths.isEmpty ? null : _paths.first;
      }
    });
  }

  /// 一覧タップ時の選択処理 (= ユーザー要望: Ctrl / Shift でまとめて選択)。
  void _handleTileTap(int index) {
    final path = _paths[index];
    final ctrl = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    setState(() {
      if (shift) {
        final a = _anchorIndex.clamp(0, _paths.length - 1);
        final lo = a < index ? a : index;
        final hi = a < index ? index : a;
        for (var i = lo; i <= hi; i++) {
          _selected.add(_paths[i]);
        }
      } else if (ctrl) {
        if (!_selected.remove(path)) _selected.add(path);
        _anchorIndex = index;
      } else {
        _anchorIndex = index;
      }
      _previewPath = path;
    });
  }

  /// 全選択 / 全解除のトグル (= ユーザー要望: 再度 Ctrl+A で解除)。
  void _selectAll() {
    setState(() {
      final allSelected =
          _paths.isNotEmpty && _selected.length >= _paths.length;
      _selected.clear();
      if (!allSelected) _selected.addAll(_paths);
    });
  }

  void _clearSelection() => setState(() => _selected.clear());

  /// 選択したものをまとめて削除 (= ユーザー要望)。
  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final targets = _selected.toList();
    for (final p in targets) {
      try {
        await File(p).delete();
      } catch (_) {}
    }
    _selected.clear();
    await _reload();
  }

  /// 選択した画像を別フォルダへ移す (= ユーザー要望: フォルダ間でやり取り)。
  Future<void> _moveSelectedTo(MindMapProvider provider) async {
    if (_selected.isEmpty) return;
    final root = await automationShotsDir();
    final choices = <String?>[null, ..._dirs];
    final target = await showDialog<String>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A3E),
        title: Text(provider.t('shots.moveTo'),
            style: const TextStyle(color: Colors.white, fontSize: 15)),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final d in choices)
              if (d != _currentDir)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.folder_rounded,
                      size: 18, color: Color(0xFFFFB74D)),
                  title: Text(
                      d == null
                          ? provider.t('shots.rootFolder')
                          : d.split(Platform.pathSeparator).last,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 13)),
                  onTap: () => Navigator.pop(dctx, d ?? root.path),
                ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.create_new_folder_rounded,
                  size: 18, color: Color(0xFF80CBC4)),
              title: Text(provider.t('shots.newFolder'),
                  style:
                      const TextStyle(color: Colors.white, fontSize: 13)),
              onTap: () async {
                final d = await newAutomationRunDir();
                if (dctx.mounted) Navigator.pop(dctx, d.path);
              },
            ),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: Text(provider.t('common.cancel'),
                style: const TextStyle(color: Colors.white54)),
          ),
        ],
      ),
    );
    if (target == null || !mounted) return;
    setState(() => _busy = true);
    try {
      // 移動先で番号が衝突しないよう、 空き番号を探して付け直す。
      var next = 1;
      try {
        for (final f in Directory(target).listSync().whereType<File>()) {
          final name = f.path.split(Platform.pathSeparator).last;
          final n = int.tryParse(name.split('.').first);
          if (n != null && n >= next) next = n + 1;
        }
      } catch (_) {}
      for (final p in _selected.toList()) {
        final ext = p.substring(p.lastIndexOf('.'));
        try {
          await File(p)
              .rename('$target${Platform.pathSeparator}${next++}$ext');
        } catch (_) {}
      }
      _selected.clear();
    } finally {
      if (mounted) setState(() => _busy = false);
      await _reload();
    }
  }

  /// 今の並び順どおりに 1.jpg, 2.jpg ... と番号を振り直す。
  /// (分割後の順序を保つためにも使う)
  Future<void> _renumber(List<String> ordered) async {
    // 一旦テンポラリ名に逃がしてから確定させる (名前の衝突回避)。
    final tmp = <String>[];
    for (var i = 0; i < ordered.length; i++) {
      final f = File(ordered[i]);
      final ext = ordered[i].substring(ordered[i].lastIndexOf('.'));
      final t = '${f.parent.path}${Platform.pathSeparator}__tmp_$i$ext';
      try {
        await f.rename(t);
        tmp.add(t);
      } catch (_) {
        tmp.add(ordered[i]);
      }
    }
    for (var i = 0; i < tmp.length; i++) {
      final f = File(tmp[i]);
      final ext = tmp[i].substring(tmp[i].lastIndexOf('.'));
      final dst = '${f.parent.path}${Platform.pathSeparator}${i + 1}$ext';
      try {
        await f.rename(dst);
      } catch (_) {}
    }
    await _reload();
  }

  /// 見開き画像を左右 2 枚に分割する (= ユーザー要望: 中央位置を指定)。
  Future<void> _splitSpread(String path, MindMapProvider provider) async {
    final bytes = await File(path).readAsBytes();
    final src = img.decodeImage(bytes);
    if (src == null) return;
    var centerPct = 50.0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => StatefulBuilder(
        builder: (sctx, setD) => AlertDialog(
          backgroundColor: const Color(0xFF2A2A3E),
          title: Text(provider.t('shots.split'),
              style: const TextStyle(color: Colors.white, fontSize: 15)),
          content: SizedBox(
            width: 620,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                height: 320,
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white12),
                ),
                clipBehavior: Clip.antiAlias,
                child: LayoutBuilder(builder: (_, box) {
                  return Stack(children: [
                    Positioned.fill(
                      child: Center(
                        child: Image.file(File(path), fit: BoxFit.contain),
                      ),
                    ),
                    // 分割線 (ドラッグでも動かせる)
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanUpdate: (d) {
                          final w = box.maxWidth;
                          setD(() => centerPct =
                              (d.localPosition.dx / w * 100).clamp(5, 95));
                        },
                        onTapDown: (d) {
                          final w = box.maxWidth;
                          setD(() => centerPct =
                              (d.localPosition.dx / w * 100).clamp(5, 95));
                        },
                        child: CustomPaint(
                          painter: _SplitLinePainter(centerPct / 100),
                        ),
                      ),
                    ),
                  ]);
                }),
              ),
              const SizedBox(height: 6),
              Row(children: [
                SizedBox(
                  width: 90,
                  child: Text(provider.t('shots.splitCenter'),
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 12)),
                ),
                Expanded(
                  child: Slider(
                    value: centerPct,
                    min: 5,
                    max: 95,
                    divisions: 90,
                    label: '${centerPct.round()}%',
                    activeColor: const Color(0xFF6C63FF),
                    onChanged: (v) => setD(() => centerPct = v),
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text('${centerPct.round()}%',
                      style: const TextStyle(
                          color: Colors.white, fontSize: 11)),
                ),
              ]),
              Text(provider.t('shots.splitHint'),
                  style:
                      const TextStyle(color: Colors.white38, fontSize: 10.5)),
            ]),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: Text(provider.t('common.cancel'),
                  style: const TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6C63FF),
                  foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(dctx, true),
              child: Text(provider.t('shots.apply')),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final cut = (src.width * centerPct / 100).round().clamp(1, src.width - 1);
      final left = img.copyCrop(src, x: 0, y: 0, width: cut, height: src.height);
      final right = img.copyCrop(src,
          x: cut, y: 0, width: src.width - cut, height: src.height);
      final isJpg = path.toLowerCase().endsWith('.jpg') ||
          path.toLowerCase().endsWith('.jpeg');
      List<int> enc(img.Image im) =>
          isJpg ? img.encodeJpg(im, quality: 88) : img.encodePng(im);
      final dir = File(path).parent.path;
      final ext = path.substring(path.lastIndexOf('.'));
      final a = '$dir${Platform.pathSeparator}__split_a$ext';
      final b = '$dir${Platform.pathSeparator}__split_b$ext';
      await File(a).writeAsBytes(enc(left), flush: true);
      await File(b).writeAsBytes(enc(right), flush: true);
      // 元の位置に 2 枚を差し込んだ並びを作って番号を振り直す。
      final ordered = <String>[];
      for (final p in _paths) {
        if (p == path) {
          ordered..add(a)..add(b);
        } else {
          ordered.add(p);
        }
      }
      try {
        await File(path).delete();
      } catch (_) {}
      imageCache.clear();
      imageCache.clearLiveImages();
      await _renumber(ordered);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 画像を読み込んで [transform] を適用し、 同じパスへ上書き保存する。
  Future<void> _editImage(
      String path, img.Image Function(img.Image src) transform) async {
    setState(() => _busy = true);
    try {
      final bytes = await File(path).readAsBytes();
      final src = img.decodeImage(bytes);
      if (src == null) return;
      final out = transform(src);
      // 元の形式のまま保存する (JPEG のものを PNG で上書きしない)。
      final isJpg = path.toLowerCase().endsWith('.jpg') ||
          path.toLowerCase().endsWith('.jpeg');
      await File(path).writeAsBytes(
          isJpg ? img.encodeJpg(out, quality: 88) : img.encodePng(out),
          flush: true);
      // 画像キャッシュを捨てて再描画させる
      imageCache.clear();
      imageCache.clearLiveImages();
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 余白トリミング。 どこからどこまで切るのかが一目で分かるよう、
  /// 実際の画像の上に「残る範囲」 を明るく、 切り落とす部分を暗く重ねて
  /// プレビューする (= ユーザー要望: 分かりにくいので分かりやすく)。
  Future<void> _trimDialog(String path, MindMapProvider provider) async {
    var top = 0, bottom = 0, left = 0, right = 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => StatefulBuilder(
        builder: (sctx, setD) => AlertDialog(
          backgroundColor: const Color(0xFF2A2A3E),
          title: Text(provider.t('shots.trim'),
              style: const TextStyle(color: Colors.white, fontSize: 15)),
          content: SizedBox(
            width: 560,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // ── プレビュー ──
              Container(
                height: 300,
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white12),
                ),
                clipBehavior: Clip.antiAlias,
                child: LayoutBuilder(builder: (_, box) {
                  return Center(
                    child: Stack(children: [
                      Image.file(File(path),
                          key: ValueKey('trim$path${File(path).lengthSync()}'),
                          fit: BoxFit.contain,
                          height: box.maxHeight,
                          width: box.maxWidth),
                      // 切り落とす部分を暗く + 残る範囲を枠で示す
                      Positioned.fill(
                        child: LayoutBuilder(builder: (_, inner) {
                          final w = inner.maxWidth;
                          final h = inner.maxHeight;
                          final l = w * left / 100;
                          final r = w * right / 100;
                          final t = h * top / 100;
                          final b = h * bottom / 100;
                          const mask = Color(0xCC000000);
                          return Stack(children: [
                            Positioned(
                                left: 0,
                                right: 0,
                                top: 0,
                                height: t,
                                child: Container(color: mask)),
                            Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                height: b,
                                child: Container(color: mask)),
                            Positioned(
                                left: 0,
                                width: l,
                                top: t,
                                bottom: b,
                                child: Container(color: mask)),
                            Positioned(
                                right: 0,
                                width: r,
                                top: t,
                                bottom: b,
                                child: Container(color: mask)),
                            Positioned(
                              left: l,
                              right: r,
                              top: t,
                              bottom: b,
                              child: IgnorePointer(
                                child: Container(
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                        color: const Color(0xFF4FC3F7),
                                        width: 2),
                                  ),
                                ),
                              ),
                            ),
                          ]);
                        }),
                      ),
                    ]),
                  );
                }),
              ),
              const SizedBox(height: 4),
              Text(provider.t('shots.trimHint'),
                  style:
                      const TextStyle(color: Colors.white38, fontSize: 10.5)),
              const SizedBox(height: 6),
              for (final e in [
                ('shots.trimTop', () => top, (int v) => top = v),
                ('shots.trimBottom', () => bottom, (int v) => bottom = v),
                ('shots.trimLeft', () => left, (int v) => left = v),
                ('shots.trimRight', () => right, (int v) => right = v),
              ])
                Row(children: [
                  SizedBox(
                    width: 70,
                    child: Text(provider.t(e.$1),
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12)),
                  ),
                  Expanded(
                    child: Slider(
                      value: e.$2().toDouble(),
                      min: 0,
                      max: 45,
                      divisions: 45,
                      label: '${e.$2()}%',
                      activeColor: const Color(0xFF6C63FF),
                      onChanged: (v) => setD(() => e.$3(v.round())),
                    ),
                  ),
                  SizedBox(
                    width: 34,
                    child: Text('${e.$2()}%',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 11)),
                  ),
                ]),
            ]),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: Text(provider.t('common.cancel'),
                  style: const TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6C63FF),
                  foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(dctx, true),
              child: Text(provider.t('shots.apply')),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _editImage(path, (src) {
      final x = (src.width * left / 100).round();
      final y = (src.height * top / 100).round();
      final w = (src.width * (100 - left - right) / 100).round();
      final h = (src.height * (100 - top - bottom) / 100).round();
      if (w <= 4 || h <= 4) return src;
      return img.copyCrop(src, x: x, y: y, width: w, height: h);
    });
  }

  // ── PDF 書き出しの設定 (= ユーザー要望: 見開きは左右に割って別ページに、
  //    表紙と末尾は除いて本体だけ / 分割位置も指定) ──
  bool _pdfSplitSpread = false;
  int _pdfSplitFrom = 2; // 本体の開始 (1 始まり)
  int _pdfSplitTo = 0; // 本体の終了 (0 = 最後)
  double _pdfSplitCenter = 50; // 分割位置 (%) の既定値

  /// 分割位置をページごとに変えるか (= ユーザー要望: 本の綴じ位置は
  /// ページによってずれることがある)。 false = 全ページ同じ位置。
  bool _pdfPerPageCenter = false;

  /// ページ個別の分割位置 (パス → %)。 未設定なら _pdfSplitCenter を使う。
  final Map<String, double> _pdfCenterOf = {};

  /// PDF 出力時の余白トリミング (%) と、 その適用範囲。
  /// (= ユーザー要望: 表紙や末尾ページのトリミングも行いたい)
  double _pdfTrimTop = 0, _pdfTrimBottom = 0, _pdfTrimLeft = 0,
      _pdfTrimRight = 0;

  /// 'all' 全ページ / 'body' 本体だけ / 'edge' 表紙・末尾だけ
  String _pdfTrimScope = 'all';
  bool _pdfRightToLeft = true; // 右綴じ (右→左) が既定

  Future<void> _exportPdf(MindMapProvider provider) async {
    final targets =
        _selected.isEmpty ? _paths : _paths.where(_selected.contains).toList();
    if (targets.isEmpty) return;
    if (_pdfSplitTo <= 0 || _pdfSplitTo > targets.length) {
      _pdfSplitTo = targets.length - 1 > 0 ? targets.length - 1 : targets.length;
    }
    // ── 事前設定ダイアログ ──
    // ── 設定はプレビュー下の常設パネルの値をそのまま使う
    //    (= ユーザー要望: ボタンを押さないと設定が出てこないのは
    //    使いにくい)。 ここでは確認ダイアログを出さない。 ──

    setState(() {
      _busy = true;
      _status = '';
    });
    try {
      final doc = sfpdf.PdfDocument();
      // 画像 1 枚 = 1 ページ、 余白なし (= ユーザー要望: 画像に無い部分を
      // 足さない / スクショそのものが PDF になる)。
      void addImagePage(Uint8List bytes) {
        final sfpdf.PdfBitmap bmp;
        try {
          bmp = sfpdf.PdfBitmap(bytes);
        } catch (_) {
          return;
        }
        final iw = bmp.width.toDouble();
        final ih = bmp.height.toDouble();
        if (iw <= 0 || ih <= 0) return;
        doc.pageSettings.margins.all = 0;
        doc.pageSettings.size = Size(iw, ih);
        final page = doc.pages.add();
        final cs = page.getClientSize();
        page.graphics.drawImage(
            bmp, Rect.fromLTWH(0, 0, cs.width, cs.height));
      }

      for (var i = 0; i < targets.length; i++) {
        if (mounted) {
          setState(() => _status = provider
              .t('shots.pdfProgress')
              .replaceFirst('{i}', '${i + 1}')
              .replaceFirst('{n}', '${targets.length}'));
        }
        await Future<void>.delayed(Duration.zero);
        final bytes = await File(targets[i]).readAsBytes();
        final pageNo = i + 1;
        final inBody = _pdfSplitSpread &&
            pageNo >= _pdfSplitFrom &&
            pageNo <= _pdfSplitTo;
        // トリミングの対象か (= ユーザー要望: 表紙・末尾も切りたい)
        final trimThis = (_pdfTrimTop + _pdfTrimBottom + _pdfTrimLeft +
                    _pdfTrimRight) >
                0 &&
            (_pdfTrimScope == 'all' ||
                (_pdfTrimScope == 'body' && inBody) ||
                (_pdfTrimScope == 'edge' && !inBody));
        if (!inBody && !trimThis) {
          addImagePage(Uint8List.fromList(bytes));
          continue;
        }
        var src = img.decodeImage(bytes);
        if (src == null) {
          addImagePage(Uint8List.fromList(bytes));
          continue;
        }
        if (trimThis) {
          final x = (src.width * _pdfTrimLeft / 100).round();
          final y = (src.height * _pdfTrimTop / 100).round();
          final w =
              (src.width * (100 - _pdfTrimLeft - _pdfTrimRight) / 100).round();
          final h =
              (src.height * (100 - _pdfTrimTop - _pdfTrimBottom) / 100).round();
          if (w > 4 && h > 4) {
            src = img.copyCrop(src, x: x, y: y, width: w, height: h);
          }
        }
        final isJpgSrc = targets[i].toLowerCase().endsWith('.jpg') ||
            targets[i].toLowerCase().endsWith('.jpeg');
        if (!inBody) {
          // 分割せずトリミングだけ反映して 1 ページ
          addImagePage(Uint8List.fromList(isJpgSrc
              ? img.encodeJpg(src, quality: 90)
              : img.encodePng(src)));
          continue;
        }
        // 見開きを左右に割る (位置はページ個別 → 無ければ共通)
        final centerPct = _pdfPerPageCenter
            ? (_pdfCenterOf[targets[i]] ?? _pdfSplitCenter)
            : _pdfSplitCenter;
        final cut =
            (src.width * centerPct / 100).round().clamp(1, src.width - 1);
        final left =
            img.copyCrop(src, x: 0, y: 0, width: cut, height: src.height);
        final right = img.copyCrop(src,
            x: cut, y: 0, width: src.width - cut, height: src.height);
        final isJpg = targets[i].toLowerCase().endsWith('.jpg') ||
            targets[i].toLowerCase().endsWith('.jpeg');
        Uint8List enc(img.Image im) => Uint8List.fromList(
            isJpg ? img.encodeJpg(im, quality: 90) : img.encodePng(im));
        // 右綴じ (日本語の本) は 右 → 左 の順に並べる。
        if (_pdfRightToLeft) {
          addImagePage(enc(right));
          addImagePage(enc(left));
        } else {
          addImagePage(enc(left));
          addImagePage(enc(right));
        }
      }
      final dir =
          _currentDir == null ? await automationShotsDir() : Directory(_currentDir!);
      final out =
          '${dir.path}/shots_${DateTime.now().millisecondsSinceEpoch}.pdf';
      final data = await doc.save();
      await File(out).writeAsBytes(data, flush: true);
      doc.dispose();
      if (!mounted) return;
      setState(() =>
          _status = provider.t('shots.pdfDone').replaceFirst('{path}', out));
      await OpenFilex.open(out);
    } catch (e) {
      if (mounted) setState(() => _status = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _tile(MindMapProvider provider, int index) {
    final path = _paths[index];
    final picked = _selected.contains(path);
    final isPreview = path == _previewPath;
    return GestureDetector(
      onTap: () => _handleTileTap(index),
      child: Container(
      key: ValueKey(path),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: picked ? 0.10 : 0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: isPreview
                ? const Color(0xFF4FC3F7)
                : (picked ? const Color(0xFF6C63FF) : Colors.white12),
            width: isPreview ? 2 : 1),
      ),
      child: Row(children: [
        Checkbox(
          value: picked,
          activeColor: const Color(0xFF6C63FF),
          onChanged: (v) => setState(() {
            if (v == true) {
              _selected.add(path);
            } else {
              _selected.remove(path);
            }
          }),
        ),
        SizedBox(
          width: 132,
          height: 88,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Image.file(File(path),
                key: ValueKey('$path${File(path).lengthSync()}'),
                fit: BoxFit.cover),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${index + 1}. ${path.split(Platform.pathSeparator).last}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 11.5)),
              // 編集はプレビュー側のツールバーに集約した
              // (= ユーザー要望: プレビューと編集を一体化)。
            ],
          ),
        ),
        // 並べ替え (PDF の順番 = この一覧の順番)
        Column(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 26, minHeight: 24),
            icon: const Icon(Icons.arrow_upward_rounded,
                size: 15, color: Colors.white38),
            onPressed: index == 0
                ? null
                : () => setState(() {
                      final t = _paths.removeAt(index);
                      _paths.insert(index - 1, t);
                    }),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 26, minHeight: 24),
            icon: const Icon(Icons.arrow_downward_rounded,
                size: 15, color: Colors.white38),
            onPressed: index >= _paths.length - 1
                ? null
                : () => setState(() {
                      final t = _paths.removeAt(index);
                      _paths.insert(index + 1, t);
                    }),
          ),
        ]),
      ]),
      ),
    );
  }

  /// プレビューと編集を 1 つにしたペイン (= ユーザー要望: 外部アプリを
  /// 開かずアプリ内で編集 / プレビューと編集を一体化)。
  Widget _buildPreviewPane(MindMapProvider provider) {
    final path = _previewPath;
    Widget toolBtn(IconData icon, String tip, VoidCallback? onTap,
        {Color color = Colors.white70}) {
      return IconButton(
        tooltip: tip,
        visualDensity: VisualDensity.compact,
        icon: Icon(icon, size: 18, color: onTap == null ? Colors.white24 : color),
        onPressed: onTap,
      );
    }

    // 現在のプレビュー画像が 「見開き分割の対象範囲」 かどうか
    final idx = path == null ? -1 : _paths.indexOf(path);
    final inBody = _pdfSplitSpread &&
        idx >= 0 &&
        (idx + 1) >= _pdfSplitFrom &&
        (idx + 1) <= (_pdfSplitTo <= 0 ? _paths.length : _pdfSplitTo);

    return Container(
      color: const Color(0xFF12121D),
      padding: const EdgeInsets.all(10),
      child: Column(children: [
        // ── 編集ツールバー ──
        Row(children: [
          Expanded(
            child: Text(
                path == null
                    ? provider.t('shots.previewHint')
                    : path.split(Platform.pathSeparator).last,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ),
          toolBtn(Icons.rotate_left_rounded, provider.t('shots.rotate'),
              path == null
                  ? null
                  : () => _editImage(path, (im) => img.copyRotate(im, angle: -90))),
          toolBtn(Icons.rotate_right_rounded, provider.t('shots.rotate'),
              path == null
                  ? null
                  : () => _editImage(path, (im) => img.copyRotate(im, angle: 90))),
          toolBtn(Icons.flip_rounded, provider.t('shots.flip'),
              path == null
                  ? null
                  : () => _editImage(path, (im) => img.flipHorizontal(im))),
          toolBtn(Icons.crop_rounded, provider.t('shots.trim'),
              path == null ? null : () => _trimDialog(path, provider)),
          toolBtn(Icons.vertical_split_rounded, provider.t('shots.split'),
              path == null ? null : () => _splitSpread(path, provider)),
          toolBtn(Icons.delete_outline_rounded, provider.t('shots.delete'),
              path == null
                  ? null
                  : () async {
                      try {
                        await File(path).delete();
                      } catch (_) {}
                      _selected.remove(path);
                      await _reload();
                    },
              color: Colors.redAccent),
        ]),
        const Divider(height: 10, color: Colors.white12),
        Expanded(
          child: path == null
              ? Center(
                  child: Text(provider.t('shots.previewHint'),
                      style: const TextStyle(
                          color: Colors.white24, fontSize: 12)),
                )
              : LayoutBuilder(builder: (_, box) {
                  return Stack(children: [
                    Positioned.fill(
                      child: InteractiveViewer(
                        minScale: 0.2,
                        maxScale: 6,
                        child: Center(
                          child: Image.file(
                            File(path),
                            key: ValueKey(
                                '$path${File(path).lengthSync()}'),
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                    ),
                    // 見開き分割の基準線をプレビューに重ねる
                    // (= ユーザー要望: どこで割れるのか見せてほしい)
                    if (inBody)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CustomPaint(
                            painter: _SplitLinePainter(
                                _centerPctFor(path) / 100),
                          ),
                        ),
                      ),
                  ]);
                }),
        ),
        Text(provider.t('shots.previewZoom'),
            style: const TextStyle(color: Colors.white24, fontSize: 10)),
        const Divider(height: 12, color: Colors.white12),
        // ── PDF 設定をここに常設 (= ユーザー要望: ボタンを押さないと出て
        //    こないのは使いにくい) ──
        _buildPdfOptions(provider),
      ]),
    );
  }

  /// そのページに適用される分割位置 (%)。
  double _centerPctFor(String path) => _pdfPerPageCenter
      ? (_pdfCenterOf[path] ?? _pdfSplitCenter)
      : _pdfSplitCenter;

  /// PDF 作成の設定 (常設パネル)。
  Widget _buildPdfOptions(MindMapProvider provider) {
    final total = _paths.length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(Icons.picture_as_pdf_rounded,
            size: 16, color: Colors.white.withValues(alpha: 0.6)),
        const SizedBox(width: 6),
        Text(provider.t('shots.pdfOptions'),
            style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.w700)),
        const Spacer(),
        Text(provider.t('shots.pdfSplitSpread'),
            style: const TextStyle(color: Colors.white70, fontSize: 12)),
        Switch(
          value: _pdfSplitSpread,
          activeColor: const Color(0xFF6C63FF),
          onChanged: (v) => setState(() => _pdfSplitSpread = v),
        ),
      ]),
      if (_pdfSplitSpread) ...[
        Row(children: [
          SizedBox(
            width: 92,
            child: Text(provider.t('shots.pdfBodyRange'),
                style: const TextStyle(color: Colors.white70, fontSize: 11.5)),
          ),
          SizedBox(
            width: 58,
            child: TextFormField(
              initialValue: '$_pdfSplitFrom',
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Colors.white, fontSize: 12),
              decoration: const InputDecoration(isDense: true),
              onChanged: (v) => setState(
                  () => _pdfSplitFrom = int.tryParse(v) ?? _pdfSplitFrom),
            ),
          ),
          const Text('  〜  ',
              style: TextStyle(color: Colors.white54, fontSize: 12)),
          SizedBox(
            width: 58,
            child: TextFormField(
              initialValue: '${_pdfSplitTo <= 0 ? total : _pdfSplitTo}',
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Colors.white, fontSize: 12),
              decoration: const InputDecoration(isDense: true),
              onChanged: (v) => setState(
                  () => _pdfSplitTo = int.tryParse(v) ?? _pdfSplitTo),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
                provider
                    .t('shots.pdfRangeOf')
                    .replaceFirst('{n}', '$total'),
                style: const TextStyle(color: Colors.white38, fontSize: 10.5)),
          ),
        ]),
        // 位置の適用範囲: 全体共通 / ページごと (= ユーザー要望)
        Row(children: [
          SizedBox(
            width: 92,
            child: Text(provider.t('shots.centerScope'),
                style: const TextStyle(color: Colors.white70, fontSize: 11.5)),
          ),
          Expanded(
            child: Wrap(spacing: 6, children: [
              ChoiceChip(
                label: Text(provider.t('shots.centerCommon'),
                    style: const TextStyle(fontSize: 11)),
                selected: !_pdfPerPageCenter,
                selectedColor: const Color(0xFF6C63FF),
                backgroundColor: const Color(0xFF23233A),
                labelStyle: TextStyle(
                    color: !_pdfPerPageCenter ? Colors.white : Colors.white70),
                onSelected: (_) => setState(() => _pdfPerPageCenter = false),
              ),
              ChoiceChip(
                label: Text(provider.t('shots.centerPerPage'),
                    style: const TextStyle(fontSize: 11)),
                selected: _pdfPerPageCenter,
                selectedColor: const Color(0xFF6C63FF),
                backgroundColor: const Color(0xFF23233A),
                labelStyle: TextStyle(
                    color: _pdfPerPageCenter ? Colors.white : Colors.white70),
                onSelected: (_) => setState(() => _pdfPerPageCenter = true),
              ),
            ]),
          ),
        ]),
        Row(children: [
          SizedBox(
            width: 92,
            child: Text(
                _pdfPerPageCenter
                    ? provider.t('shots.splitCenterThis')
                    : provider.t('shots.splitCenter'),
                style: const TextStyle(color: Colors.white70, fontSize: 11.5)),
          ),
          Expanded(
            child: Slider(
              value: _previewPath != null && _pdfPerPageCenter
                  ? _centerPctFor(_previewPath!)
                  : _pdfSplitCenter,
              min: 20,
              max: 80,
              divisions: 60,
              label:
                  '${(_previewPath != null && _pdfPerPageCenter ? _centerPctFor(_previewPath!) : _pdfSplitCenter).round()}%',
              activeColor: const Color(0xFF6C63FF),
              onChanged: (v) => setState(() {
                if (_pdfPerPageCenter && _previewPath != null) {
                  _pdfCenterOf[_previewPath!] = v;
                } else {
                  _pdfSplitCenter = v;
                }
              }),
            ),
          ),
          SizedBox(
            width: 42,
            child: Text(
                '${(_previewPath != null && _pdfPerPageCenter ? _centerPctFor(_previewPath!) : _pdfSplitCenter).round()}%',
                style: const TextStyle(color: Colors.white, fontSize: 11)),
          ),
        ]),
        if (_pdfPerPageCenter)
          Padding(
            padding: const EdgeInsets.only(left: 92, bottom: 4),
            child: Text(provider.t('shots.centerPerPageHint'),
                style:
                    const TextStyle(color: Color(0xFF80CBC4), fontSize: 10)),
          ),
        // ── 読む向き: 「右綴じ」 では伝わらないので言い換える
        //    (= ユーザー要望) ──
        Row(children: [
          SizedBox(
            width: 92,
            child: Text(provider.t('shots.readOrder'),
                style: const TextStyle(color: Colors.white70, fontSize: 11.5)),
          ),
          Expanded(
            child: Wrap(spacing: 6, children: [
              ChoiceChip(
                label: Text(provider.t('shots.readRightFirst'),
                    style: const TextStyle(fontSize: 11)),
                selected: _pdfRightToLeft,
                selectedColor: const Color(0xFF6C63FF),
                backgroundColor: const Color(0xFF23233A),
                labelStyle: TextStyle(
                    color: _pdfRightToLeft ? Colors.white : Colors.white70),
                onSelected: (_) => setState(() => _pdfRightToLeft = true),
              ),
              ChoiceChip(
                label: Text(provider.t('shots.readLeftFirst'),
                    style: const TextStyle(fontSize: 11)),
                selected: !_pdfRightToLeft,
                selectedColor: const Color(0xFF6C63FF),
                backgroundColor: const Color(0xFF23233A),
                labelStyle: TextStyle(
                    color: !_pdfRightToLeft ? Colors.white : Colors.white70),
                onSelected: (_) => setState(() => _pdfRightToLeft = false),
              ),
            ]),
          ),
        ]),
      ],
      // ── PDF 出力時の余白トリミング (= ユーザー要望: 表紙や末尾ページの
      //    トリミングも行いたい)。 適用範囲を選べる。 ──
      const Divider(height: 12, color: Colors.white12),
      Row(children: [
        SizedBox(
          width: 92,
          child: Text(provider.t('shots.pdfTrim'),
              style: const TextStyle(color: Colors.white70, fontSize: 11.5)),
        ),
        Expanded(
          child: Wrap(spacing: 6, children: [
            for (final e in [
              ('all', provider.t('shots.trimScopeAll')),
              ('body', provider.t('shots.trimScopeBody')),
              ('edge', provider.t('shots.trimScopeEdge')),
            ])
              ChoiceChip(
                label: Text(e.$2, style: const TextStyle(fontSize: 11)),
                selected: _pdfTrimScope == e.$1,
                selectedColor: const Color(0xFF6C63FF),
                backgroundColor: const Color(0xFF23233A),
                labelStyle: TextStyle(
                    color: _pdfTrimScope == e.$1
                        ? Colors.white
                        : Colors.white70),
                onSelected: (_) => setState(() => _pdfTrimScope = e.$1),
              ),
          ]),
        ),
      ]),
      Row(children: [
        for (final e in [
          ('shots.trimTop', () => _pdfTrimTop, (double v) => _pdfTrimTop = v),
          ('shots.trimBottom', () => _pdfTrimBottom,
              (double v) => _pdfTrimBottom = v),
          ('shots.trimLeft', () => _pdfTrimLeft,
              (double v) => _pdfTrimLeft = v),
          ('shots.trimRight', () => _pdfTrimRight,
              (double v) => _pdfTrimRight = v),
        ])
          Expanded(
            child: Row(children: [
              Text(provider.t(e.$1),
                  style:
                      const TextStyle(color: Colors.white54, fontSize: 10.5)),
              Expanded(
                child: Slider(
                  value: e.$2(),
                  min: 0,
                  max: 40,
                  divisions: 40,
                  label: '${e.$2().round()}%',
                  activeColor: const Color(0xFF4DB6AC),
                  onChanged: (v) => setState(() => e.$3(v)),
                ),
              ),
              SizedBox(
                width: 30,
                child: Text('${e.$2().round()}%',
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 10)),
              ),
            ]),
          ),
      ]),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.read<MindMapProvider>();
    // Ctrl+A で全選択 / Delete で選択削除 (= ユーザー要望)。
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.keyA, control: true):
            const _SelectAllIntent(),
        const SingleActivator(LogicalKeyboardKey.keyA, meta: true):
            const _SelectAllIntent(),
        const SingleActivator(LogicalKeyboardKey.delete):
            const _DeleteSelectedIntent(),
        const SingleActivator(LogicalKeyboardKey.backspace):
            const _DeleteSelectedIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _SelectAllIntent: CallbackAction<_SelectAllIntent>(
              onInvoke: (_) => _selectAll()),
          _DeleteSelectedIntent: CallbackAction<_DeleteSelectedIntent>(
              onInvoke: (_) => _deleteSelected()),
        },
        child: Focus(
          autofocus: true,
          child: Dialog(
      backgroundColor: const Color(0xFF1B1B2A),
      insetPadding: const EdgeInsets.all(12),
      child: SizedBox(
        width: MediaQuery.of(context).size.width - 40,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
            decoration: const BoxDecoration(color: Color(0xFF23233A)),
            child: Row(children: [
              const Icon(Icons.photo_library_rounded,
                  color: Color(0xFF80CBC4), size: 18),
              const SizedBox(width: 8),
              Text(provider.t('shots.title'),
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700)),
              const Spacer(),
              IconButton(
                tooltip: provider.t('shots.openFolder'),
                icon: const Icon(Icons.folder_open_rounded,
                    color: Colors.white70, size: 18),
                onPressed: () => OpenFilex.open(_dirPath),
              ),
              IconButton(
                tooltip: provider.t('shots.reload'),
                icon: const Icon(Icons.refresh_rounded,
                    color: Colors.white70, size: 18),
                onPressed: _reload,
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded,
                    color: Colors.white54, size: 18),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
            child: Row(children: [
              Expanded(
                child: SelectableText(_dirPath,
                    maxLines: 1,
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 10.5)),
              ),
              // ── フォルダ切替 (= ユーザー要望: 実行の度に別フォルダ) ──
              if (_dirs.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String?>(
                      value: _currentDir,
                      dropdownColor: const Color(0xFF1E1E32),
                      isDense: true,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 11.5),
                      items: [
                        DropdownMenuItem<String?>(
                          value: null,
                          child: Text(provider.t('shots.rootFolder'),
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 11.5)),
                        ),
                        for (final d in _dirs)
                          DropdownMenuItem<String?>(
                            value: d,
                            child: Text(
                                d.split(Platform.pathSeparator).last,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 11.5)),
                          ),
                      ],
                      onChanged: (v) {
                        setState(() {
                          _currentDir = v;
                          _selected.clear();
                          _previewPath = null;
                        });
                        _reload();
                      },
                    ),
                  ),
                ),
              if (_selected.isNotEmpty)
                TextButton.icon(
                  style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFFFFB74D),
                      minimumSize: const Size(0, 30)),
                  icon: const Icon(Icons.drive_file_move_rounded, size: 16),
                  label: Text(provider.t('shots.moveTo'),
                      style: const TextStyle(fontSize: 11)),
                  onPressed: _busy ? null : () => _moveSelectedTo(provider),
                ),
              // ── 選択操作 (= ユーザー要望: まとめて選択して削除) ──
              TextButton.icon(
                style: TextButton.styleFrom(
                    foregroundColor: Colors.white70,
                    minimumSize: const Size(0, 30)),
                icon: const Icon(Icons.select_all_rounded, size: 16),
                label: Text(provider.t('shots.selectAll'),
                    style: const TextStyle(fontSize: 11)),
                onPressed: _selectAll,
              ),
              if (_selected.isNotEmpty)
                TextButton.icon(
                  style: TextButton.styleFrom(
                      foregroundColor: Colors.white54,
                      minimumSize: const Size(0, 30)),
                  icon: const Icon(Icons.deselect_rounded, size: 16),
                  label: Text(provider.t('shots.clearSelection'),
                      style: const TextStyle(fontSize: 11)),
                  onPressed: _clearSelection,
                ),
              if (_selected.isNotEmpty)
                TextButton.icon(
                  style: TextButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      minimumSize: const Size(0, 30)),
                  icon: const Icon(Icons.delete_outline_rounded, size: 16),
                  label: Text(
                      provider
                          .t('shots.deleteSelected')
                          .replaceFirst('{n}', '${_selected.length}'),
                      style: const TextStyle(fontSize: 11)),
                  onPressed: _deleteSelected,
                ),
              TextButton.icon(
                style: TextButton.styleFrom(
                    foregroundColor: Colors.white54,
                    minimumSize: const Size(0, 30)),
                icon: const Icon(Icons.format_list_numbered_rounded, size: 16),
                label: Text(provider.t('shots.renumber'),
                    style: const TextStyle(fontSize: 11)),
                onPressed: _busy ? null : () => _renumber(List.of(_paths)),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 2, 14, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(provider.t('shots.selectHint'),
                  style:
                      const TextStyle(color: Colors.white24, fontSize: 10)),
            ),
          ),
          SizedBox(
            height: (MediaQuery.of(context).size.height - 250)
                .clamp(360.0, 1200.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── 一覧 (左) ──
                SizedBox(
                  width: 430,
                  child: _paths.isEmpty
                      ? Center(
                          child: Text(provider.t('shots.empty'),
                              style: const TextStyle(
                                  color: Colors.white24, fontSize: 12)),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                          itemCount: _paths.length,
                          itemBuilder: (_, i) => _tile(provider, i),
                        ),
                ),
                const VerticalDivider(width: 1, color: Colors.white12),
                // ── 大きなプレビュー (右) = ユーザー要望 ──
                Expanded(child: _buildPreviewPane(provider)),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white12),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Row(children: [
              Expanded(
                child: Text(_status,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 10.5)),
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(right: 10),
                  child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF43B97F),
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.picture_as_pdf_rounded, size: 18),
                label: Text(_selected.isEmpty
                    ? provider.t('shots.pdfAll')
                    : provider
                        .t('shots.pdfSelected')
                        .replaceFirst('{n}', '${_selected.length}')),
                onPressed: _busy ? null : () => _exportPdf(provider),
              ),
            ]),
          ),
        ]),
      ),
          ),
        ),
      ),
    );
  }
}

/// Ctrl+A / Delete 用の Intent。
class _SelectAllIntent extends Intent {
  const _SelectAllIntent();
}

class _DeleteSelectedIntent extends Intent {
  const _DeleteSelectedIntent();
}

/// 見開き分割のプレビュー線。
class _SplitLinePainter extends CustomPainter {
  final double ratio;
  const _SplitLinePainter(this.ratio);

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width * ratio;
    canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = const Color(0xFFFF5252)
          ..strokeWidth = 2);
    // 掴みやすいようにハンドルも描く
    canvas.drawCircle(Offset(x, size.height / 2), 7,
        Paint()..color = const Color(0xFFFF5252));
  }

  @override
  bool shouldRepaint(_SplitLinePainter old) => old.ratio != ratio;
}
