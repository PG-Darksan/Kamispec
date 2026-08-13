// ============================================================================
//  read_aloud.dart ― 音声読み上げ (TTS) 共有コンポーネント
// ============================================================================
//  PDF / テキストファイル / ドキュメントビューア など、 抽出済みテキストを
//  文単位に分割して順番に読み上げるための再利用コンポーネント
//  (= ユーザー要望: 「PDFやテキストファイル等の音声読み上げ機能」)。
//
//  ・`ReadAloudController` … flutter_tts をラップし、 再生/一時停止/停止/
//      前後スキップ/速度変更/言語自動判定を管理する ChangeNotifier。
//  ・`ReadAloudBar` … コントローラを監視する操作バー Widget (再生・速度等)。
//
//  TTS 非対応プラットフォーム (= flutter_tts が初期化できない端末) では
//  すべて try/catch で握りつぶし、 静かに無効化する (クラッシュさせない)。
// ============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// テキストを文単位で順番に読み上げる TTS コントローラ。
///
/// 再生は「文チャンク」を 1 つずつ `speak()` し、 `awaitSpeakCompletion(true)`
/// で読み終わるまで待ってから次へ進む。 一時停止/停止/スキップは世代トークン
/// (`_gen`) で進行中ループを無効化することで、 二重再生を防ぐ。
class ReadAloudController extends ChangeNotifier {
  ReadAloudController({String? language, double rate = 0.5})
      : _language = language,
        _rate = rate.clamp(0.1, 1.5);

  FlutterTts? _tts;
  bool _ttsReady = false;
  String? _language;

  List<String> _chunks = const [];

  /// 各チャンクの元ページ番号 (= PDF のページ追従用、 任意)。 null で未使用。
  List<int>? _chunkPages;
  int _index = 0;
  bool _playing = false;
  bool _paused = false;
  bool _disposed = false;
  double _rate;

  /// 文と文の間に置く沈黙の長さ (ms)。 = ユーザー要望「文の区切れには少し間を
  ///   置いて欲しい」。 1 文を読み終えてから次の文へ進む前に待つ。
  int _sentencePauseMs = 320;

  /// 進行中ループの世代。 pause/stop/skip/start のたびに増やし、 古いループを
  /// 無効化する (= 二重再生防止)。
  int _gen = 0;

  bool get isActive => _playing || _paused;
  bool get isPlaying => _playing;
  bool get isPaused => _paused;
  double get rate => _rate;
  int get currentIndex => _index;
  int get total => _chunks.length;

  /// 現在読み上げ中の文 (UI ハイライト等に使える)。
  String get currentChunk =>
      (_index >= 0 && _index < _chunks.length) ? _chunks[_index] : '';

  /// 現在読み上げ中チャンクの元ページ番号 (= PDF のページ追従用)。 未設定なら null。
  int? get currentSourcePage =>
      (_chunkPages != null && _index >= 0 && _index < _chunkPages!.length)
          ? _chunkPages![_index]
          : null;

  /// テキストを文チャンクに分割する (= PDF をページ毎にチャンク化して
  /// ページ番号を割り当てるために外部から使う)。
  static List<String> chunkText(String text) => _chunkText(text);

  Future<void> _ensureTts() async {
    if (_ttsReady) return;
    try {
      final t = FlutterTts();
      try {
        if (_language != null && _language!.isNotEmpty) {
          await t.setLanguage(_language!.replaceAll('_', '-'));
        }
      } catch (_) {}
      try {
        await t.setSpeechRate(_rate);
      } catch (_) {}
      // ── 音質を整える (= ユーザー要望: 読み上げ音声をもう少し綺麗に) ──
      // ピッチを自然な 1.0、 音量を最大にし、 端末で利用可能なら高品質な
      //   ニューラル/拡張音声を優先選択する (Android の network/enhanced voice 等)。
      try {
        await t.setPitch(1.0);
      } catch (_) {}
      try {
        await t.setVolume(1.0);
      } catch (_) {}
      await _selectBestVoice(t);
      // speak() を読了まで await できるようにする (= 逐次再生の要)。
      try {
        await t.awaitSpeakCompletion(true);
      } catch (_) {}
      _tts = t;
      _ttsReady = true;
    } catch (_) {
      _tts = null;
      _ttsReady = false;
    }
  }

  /// 端末で利用可能な中から、 指定言語に合う「高品質」 音声を選んで設定する。
  /// = ユーザー要望: 読み上げ音声をもう少し綺麗に。 compact (低品質) を避け、
  ///   neural / enhanced / premium / network など高品質を優先する。 失敗・非対応は無視。
  Future<void> _selectBestVoice(FlutterTts t, [String? langHint]) async {
    try {
      final target = (langHint ?? _language ?? 'ja-JP').toLowerCase();
      final wantLang = target.split(RegExp(r'[-_]')).first; // 'ja' / 'en'
      final voices = await t.getVoices;
      if (voices is! List) return;
      Map? best;
      int bestScore = -1000;
      for (final v in voices) {
        if (v is! Map) continue;
        final name = (v['name'] ?? '').toString().toLowerCase();
        final loc = (v['locale'] ?? '').toString().toLowerCase();
        if (!loc.contains(wantLang)) continue;
        int score = 0;
        for (final kw in const [
          'neural',
          'enhanced',
          'premium',
          'network',
          'wavenet',
          'natural'
        ]) {
          if (name.contains(kw)) score += 3;
        }
        if (name.contains('compact')) score -= 3;
        final quality = (v['quality'] ?? '').toString().toLowerCase();
        if (quality.contains('high') || quality.contains('network')) score += 2;
        if (score > bestScore) {
          bestScore = score;
          best = v;
        }
      }
      if (best != null && best['name'] != null && best['locale'] != null) {
        await t.setVoice({
          'name': best['name'].toString(),
          'locale': best['locale'].toString(),
        });
      }
    } catch (_) {}
  }

  /// 文の区切れに置く間 (ms) を設定する (= ユーザー要望)。
  void setSentencePauseMs(int ms) {
    _sentencePauseMs = ms.clamp(0, 2000);
  }

  /// この端末/プラットフォームで TTS が使えるか。
  Future<bool> get available async {
    await _ensureTts();
    return _tts != null;
  }

  /// テキストを先頭から読み上げ開始する。 既存再生は破棄。
  /// チャンクが空 (テキスト無し) なら false を返す。
  Future<bool> start(String text) async {
    await _ensureTts();
    if (_tts == null) return false;
    final chunks = _chunkText(text);
    if (chunks.isEmpty) return false;
    // 内容から言語を推定して切り替える (日本語テキストを英語音声で読む等を防ぐ)。
    final lang = _guessLanguage(text, _language);
    if (lang != null) {
      try {
        await _tts!.setLanguage(lang);
      } catch (_) {}
      // 検出した言語に合う高品質音声を選び直す (= 音声をもう少し綺麗に)。
      await _selectBestVoice(_tts!, lang);
    }
    _chunks = chunks;
    _chunkPages = null; // フラット読み上げではページ追従なし。
    _index = 0;
    _paused = false;
    _playing = true;
    _gen++;
    if (!_disposed) notifyListeners();
    await _runLoop();
    return true;
  }

  /// 事前にチャンク分割済みのテキストで読み上げ開始する (= PDF のページ追従用)。
  /// [pages] は各チャンクの元ページ番号 (チャンク数と一致したときのみ使用)。
  Future<bool> startChunks(List<String> chunks,
      {List<int>? pages, String? sampleText}) async {
    await _ensureTts();
    if (_tts == null) return false;
    final cleaned = <String>[];
    final cleanedPages = <int>[];
    for (int i = 0; i < chunks.length; i++) {
      final c = chunks[i].trim();
      if (c.isEmpty) continue;
      cleaned.add(c);
      if (pages != null && i < pages.length) cleanedPages.add(pages[i]);
    }
    if (cleaned.isEmpty) return false;
    final lang = _guessLanguage(sampleText ?? cleaned.first, _language);
    if (lang != null) {
      try {
        await _tts!.setLanguage(lang);
      } catch (_) {}
      await _selectBestVoice(_tts!, lang);
    }
    _chunks = cleaned;
    _chunkPages = (cleanedPages.length == cleaned.length) ? cleanedPages : null;
    _index = 0;
    _paused = false;
    _playing = true;
    _gen++;
    if (!_disposed) notifyListeners();
    await _runLoop();
    return true;
  }

  Future<void> _runLoop() async {
    final myGen = _gen;
    while (_playing &&
        !_disposed &&
        myGen == _gen &&
        _index >= 0 &&
        _index < _chunks.length) {
      if (!_disposed) notifyListeners(); // 進捗/ハイライト更新
      try {
        await _tts!.speak(_chunks[_index]);
      } catch (_) {
        // 1 チャンク失敗しても止めず次へ。
      }
      if (!_playing || _disposed || myGen != _gen) return;
      _index++;
      // ── 文の区切れに少し間を置く (= ユーザー要望) ──
      // 最後の文の後ろには入れない。 一時停止/停止/スキップが入ったら中断する。
      if (_sentencePauseMs > 0 && _index < _chunks.length) {
        await Future<void>.delayed(Duration(milliseconds: _sentencePauseMs));
        if (!_playing || _disposed || myGen != _gen) return;
      }
    }
    // 最後まで読了。
    if (myGen == _gen && _playing && _index >= _chunks.length) {
      _playing = false;
      _paused = false;
      _index = 0;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> pause() async {
    if (!_playing) return;
    _gen++; // 進行中ループを無効化
    _playing = false;
    _paused = true;
    try {
      await _tts?.stop();
    } catch (_) {}
    if (!_disposed) notifyListeners();
  }

  Future<void> resume() async {
    if (!_paused) return;
    _paused = false;
    _playing = true;
    _gen++;
    if (!_disposed) notifyListeners();
    await _runLoop();
  }

  Future<void> toggle() async {
    if (_playing) {
      await pause();
    } else if (_paused) {
      await resume();
    }
  }

  Future<void> stop() async {
    _gen++;
    _playing = false;
    _paused = false;
    _index = 0;
    try {
      await _tts?.stop();
    } catch (_) {}
    if (!_disposed) notifyListeners();
  }

  /// 前/次の文へ (delta = -1 / +1)。 再生中なら移動先から読み続ける。
  Future<void> skip(int delta) async {
    if (_chunks.isEmpty) return;
    final wasPlaying = _playing;
    _gen++;
    _playing = false;
    try {
      await _tts?.stop();
    } catch (_) {}
    _index = (_index + delta).clamp(0, _chunks.length - 1);
    if (wasPlaying) {
      _playing = true;
      _gen++;
      if (!_disposed) notifyListeners();
      await _runLoop();
    } else {
      if (!_disposed) notifyListeners();
    }
  }

  /// 読み上げ速度を変更 (0.1〜1.5)。 次のチャンクから反映される。
  /// flutter_tts の rate は Android で ×2 倍 (rate 0.5=等速、 1.0=×2.0、
  /// 1.5=×3.0) に対応する。 = ユーザー要望: もっと速くできるように上限を上げる。
  Future<void> setRate(double r) async {
    _rate = r.clamp(0.1, 1.5);
    try {
      await _tts?.setSpeechRate(_rate);
    } catch (_) {}
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _gen++;
    _playing = false;
    _paused = false;
    try {
      _tts?.stop();
    } catch (_) {}
    super.dispose();
  }

  // ── テキスト → 文チャンク ──
  static List<String> _chunkText(String text) {
    final normalized =
        text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
    if (normalized.isEmpty) return const [];
    // 文末記号 (。．！？!?) または改行の直後で分割。
    final sentences = normalized.split(RegExp(r'(?<=[。．！？!?\n])'));
    final out = <String>[];
    final buf = StringBuffer();
    void flush() {
      final s = buf.toString().trim();
      if (s.isNotEmpty) out.add(s);
      buf.clear();
    }

    for (var sentence in sentences) {
      var s = sentence.trim();
      if (s.isEmpty) continue;
      // 1 文が極端に長い場合は空白で粗く分割 (TTS 一発上限/応答性のため)。
      while (s.length > 240) {
        var at = s.lastIndexOf(' ', 240);
        if (at < 80) at = 240;
        final head = s.substring(0, at).trim();
        if (head.isNotEmpty) out.add(head);
        s = s.substring(at).trim();
      }
      // ── 原則 1 文 = 1 チャンク (= 文の区切れで間が入るように) ──
      // 極端に短い断片 (箇条書き記号・見出しの分割など) だけは直前にまとめて
      //   ブツ切り感を抑える (合計 ~40 文字まで)。 これより長い文は単独チャンクにし、
      //   _runLoop の文間ポーズが各文末で効くようにする。
      if (buf.isNotEmpty && buf.length + s.length > 40) flush();
      if (buf.isNotEmpty) buf.write(' ');
      buf.write(s);
    }
    flush();
    return out;
  }

  // ── 内容から言語を推定 ──
  static String? _guessLanguage(String text, String? fallback) {
    // ひらがな/カタカナ/漢字を含めば日本語。
    if (RegExp(r'[぀-ヿ一-鿿]').hasMatch(text)) {
      return 'ja-JP';
    }
    // ラテン文字主体なら英語。
    if (RegExp(r'[A-Za-z]').hasMatch(text)) {
      return 'en-US';
    }
    return fallback;
  }
}

/// 速度プリセット (ラベル, flutter_tts のレート値)。
/// = ユーザー要望: 「速い」 等では速さが分かりにくいので ×2.0 のような倍率表記に。
///   倍率は等速 (rate 0.5) を ×1.0 とした表記 (Android の rate→×2 換算に一致)。
///   上限を ×3.0 まで引き上げ、 もっと速く読めるようにする。
const List<({String label, double rate})> kReadAloudSpeeds = [
  (label: '×0.75', rate: 0.375),
  (label: '×1.0', rate: 0.5),
  (label: '×1.25', rate: 0.625),
  (label: '×1.5', rate: 0.75),
  (label: '×2.0', rate: 1.0),
  (label: '×2.5', rate: 1.25),
  (label: '×3.0', rate: 1.5),
];

/// 読み上げ操作バー。 [controller] を監視して再生/一時停止/停止/前後/速度を出す。
/// [onClose] は停止ボタン押下時 (= バーを閉じる) に呼ばれる。
class ReadAloudBar extends StatelessWidget {
  const ReadAloudBar({
    super.key,
    required this.controller,
    required this.onClose,
  });

  final ReadAloudController controller;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final playing = controller.isPlaying;
        final total = controller.total;
        final pos =
            total == 0 ? 0 : (controller.currentIndex + 1).clamp(1, total);
        return Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF252535),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white12),
              boxShadow: const [
                BoxShadow(
                    color: Colors.black54,
                    blurRadius: 14,
                    offset: Offset(0, 4)),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.record_voice_over_rounded,
                    color: Color(0xFF4FC3F7), size: 20),
                const SizedBox(width: 6),
                _iconBtn(Icons.skip_previous_rounded, '前の文',
                    () => controller.skip(-1)),
                _iconBtn(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  playing ? '一時停止' : '再生',
                  () => playing ? controller.pause() : controller.resume(),
                  big: true,
                ),
                _iconBtn(
                    Icons.skip_next_rounded, '次の文', () => controller.skip(1)),
                _iconBtn(Icons.stop_rounded, '停止', onClose,
                    color: const Color(0xFFFF6B6B)),
                const SizedBox(width: 4),
                _speedSelector(),
                const SizedBox(width: 8),
                Text('$pos/$total',
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 11)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _iconBtn(IconData icon, String tip, VoidCallback onTap,
      {bool big = false, Color color = Colors.white}) {
    return IconButton(
      tooltip: tip,
      onPressed: onTap,
      iconSize: big ? 30 : 22,
      padding: EdgeInsets.all(big ? 4 : 2),
      constraints: const BoxConstraints(),
      icon: Icon(icon, color: color),
      splashRadius: big ? 24 : 18,
    );
  }

  Widget _speedSelector() {
    final cur = kReadAloudSpeeds.reduce((a, b) =>
        (controller.rate - a.rate).abs() < (controller.rate - b.rate).abs()
            ? a
            : b);
    return PopupMenuButton<double>(
      tooltip: '読み上げ速度',
      color: const Color(0xFF252535),
      onSelected: (r) => controller.setRate(r),
      itemBuilder: (_) => [
        for (final s in kReadAloudSpeeds)
          PopupMenuItem<double>(
            value: s.rate,
            child: Row(children: [
              Icon(
                (controller.rate - s.rate).abs() < 0.001
                    ? Icons.check_rounded
                    : Icons.speed_rounded,
                size: 16,
                color: const Color(0xFF4FC3F7),
              ),
              const SizedBox(width: 8),
              Text(s.label,
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
            ]),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.speed_rounded, size: 14, color: Colors.white70),
          const SizedBox(width: 4),
          Text(cur.label,
              style: const TextStyle(color: Colors.white, fontSize: 12)),
        ]),
      ),
    );
  }
}
