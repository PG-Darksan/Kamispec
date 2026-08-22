import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'screen_capture.dart' as scap;

/// 画面録画の実体 (= ユーザー要望: 画面録画をビデオエディターの外からも
/// 使えるように / 録る範囲を指定できるように)。
///
/// ★ 画面ごと (State) に持たせると、 その画面を閉じた時に録画が宙に浮く。
///   ビデオエディターのボタンからも、 ヘッダーのカスタムボタンからも
///   同じ 1 つを操るために、 画面の外に置いてある。
///
/// Windows は ffmpeg の gdigrab で画面を取り込む。
/// Android は OS の MediaProjection (ネイティブの ScreenRecService) で録る
/// (= ユーザー要望: モバイル版でも画面録画に対応)。
class ScreenRecorder extends ChangeNotifier {
  ScreenRecorder._();
  static final ScreenRecorder instance = ScreenRecorder._();

  /// Android のネイティブ録画との通信口 (MainActivity 側と対)。
  static const MethodChannel _androidCh = MethodChannel('app/screenrec');

  /// この環境で画面録画ができるか (= ボタンを出してよいか)。
  static bool get supported => Platform.isWindows || Platform.isAndroid;

  /// Android のネイティブ録画で撮っている最中か。
  bool _androidRecording = false;

  Process? _proc;
  String? _dest;
  int _sec = 0;
  Timer? _timer;

  /// ffmpeg が吐いたエラー (失敗した時に何が起きたか出すため)。
  final StringBuffer _err = StringBuffer();

  bool get recording => _proc != null || _androidRecording;
  int get seconds => _sec;
  String? get destPath => _dest;

  String get label {
    final m = (_sec ~/ 60).toString().padLeft(2, '0');
    final s = (_sec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  /// 録画したファイルの置き場所。
  ///
  /// ★ 以前は「ドキュメント」 に置いていたが、 そこは OneDrive に付け替え
  ///   られている事があり (例: C:\Users\…\OneDrive\ドキュメント)、
  ///   同期の途中でファイルが移動 / 実体化待ちになって開けない事があった。
  ///   アプリ専用フォルダー (英数字だけの固定パス) に置く。
  /// 利用者が選んだ保存先 (= ユーザー要望: 保存する場所を指定したい)。
  /// null / 空なら既定 (アプリ専用フォルダー)。
  static String? customDir;

  static Future<Directory> recordingsDir() async {
    final chosen = (customDir ?? '').trim();
    if (chosen.isNotEmpty) {
      try {
        final d = Directory(chosen);
        if (!await d.exists()) await d.create(recursive: true);
        return d;
      } catch (_) {
        // 選んだ場所に書けない時は既定へ落とす (録れないより良い)。
      }
    }
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}screen_rec');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// 取り込みの世代番号。 stop() のたびに進めて、 遅れて届いた
  /// 「落ちたので取り直す」 が止めた後の録画を蘇らせないようにする。
  int _gen = 0;

  /// ffmpeg ごとの ddagrab (Desktop Duplication) が使えるかの覚え。
  static final Map<String, bool> _ddagrabOk = {};

  /// この ffmpeg に ddagrab フィルターが入っているか (1 回だけ調べる)。
  static Future<bool> _supportsDdagrab(String ffmpegPath) async {
    final cached = _ddagrabOk[ffmpegPath];
    if (cached != null) return cached;
    var ok = false;
    try {
      final r = await Process.run(ffmpegPath, ['-hide_banner', '-filters'])
          .timeout(const Duration(seconds: 10));
      ok = '${r.stdout}'.contains('ddagrab');
    } catch (_) {}
    _ddagrabOk[ffmpegPath] = ok;
    return ok;
  }

  /// 録画を始める。 成功したら出力先のパス、 失敗したらエラー文言を投げる。
  ///
  /// [region] を渡すとその範囲だけを録る (画面の物理ピクセル座標)。
  /// null なら画面全体。
  /// Android の画面録画を始める (= OS の MediaProjection)。
  ///
  /// OS の確認ダイアログが出るので、 利用者が拒否した時は
  /// [ScreenRecException] を投げる。 範囲指定は Android では扱えないため
  /// 常に画面全体を録る。
  Future<String> startAndroid({bool withAudio = false}) async {
    if (recording) return _dest!;
    final dir = await recordingsDir();
    final dest = '${dir.path}${Platform.pathSeparator}'
        'screen_${DateTime.now().millisecondsSinceEpoch}.mp4';
    String? got;
    try {
      got = await _androidCh.invokeMethod<String>('start', {
        'path': dest,
        'withAudio': withAudio,
      });
    } on PlatformException catch (e) {
      throw ScreenRecException(e.message ?? '録画を開始できませんでした');
    } catch (e) {
      throw ScreenRecException('$e');
    }
    if (got == null) {
      // 利用者が OS のダイアログで «キャンセル» した。
      throw ScreenRecException('録画の許可が下りませんでした');
    }
    _androidRecording = true;
    _dest = got;
    _sec = 0;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _sec++;
      notifyListeners();
    });
    notifyListeners();
    return got;
  }

  /// Android の録画を止めて、 出来たファイルのパスを返す。
  Future<String> _stopAndroid() async {
    final dest = _dest;
    _androidRecording = false;
    _timer?.cancel();
    _timer = null;
    _dest = null;
    notifyListeners();
    String? path;
    try {
      path = await _androidCh.invokeMethod<String>('stop');
    } catch (_) {}
    final out = path ?? dest;
    if (out == null) throw ScreenRecException('録画していません');
    // MediaRecorder がファイルを閉じ切るまで少し待つ。
    for (var i = 0; i < 20; i++) {
      try {
        final f = File(out);
        if (await f.exists() && await f.length() > 20000) return out;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    String? why;
    try {
      why = await _androidCh.invokeMethod<String>('lastError');
    } catch (_) {}
    throw ScreenRecException(
        (why == null || why.isEmpty) ? '録画ファイルが作られませんでした' : why);
  }

  Future<String> start(String ffmpegPath, {ScreenRecRegion? region}) async {
    if (recording) return _dest!;
    final dir = await recordingsDir();
    final dest = '${dir.path}${Platform.pathSeparator}'
        'screen_${DateTime.now().millisecondsSinceEpoch}.mp4';
    // 幅と高さは偶数でないと libx264 (yuv420p) が受け付けない。
    final r = region?.evened();
    // 出力側の設定は取り込み方によらず同じ。
    final outArgs = <String>[
      '-c:v', 'libx264',
      '-preset', 'veryfast',
      '-pix_fmt', 'yuv420p',
      // ★ 断片化 mp4 で書く。
      //   ffmpeg は「終わる時」 に索引 (moov) を書くので、 普通の mp4 だと
      //   途中で止めた瞬間のファイルは再生できない (中身 48 バイトの殻に
      //   なる)。 実際これが「録画したのに映らない」 の正体だった
      //   (= ユーザー報告)。 停止の合図 'q' は、 標準入力がパイプの時
      //   ffmpeg に届かないため効かず、 最後は強制終了になってしまう。
      //   断片ごとに索引を書いておけば、 どこで止まっても再生できる。
      '-movflags', '+frag_keyframe+empty_moov+default_base_moof',
      '-g', '30',
      dest,
    ];
    final gdigrabArgs = <String>[
      '-y',
      '-f', 'gdigrab',
      '-framerate', '30',
      if (r != null) ...[
        '-offset_x', '${r.x}',
        '-offset_y', '${r.y}',
        '-video_size', '${r.width}x${r.height}',
      ],
      '-i', 'desktop',
      ...outArgs,
    ];
    // ★ カーソルの点滅対策 (= ユーザー報告: 録画中にカーソルが出たり
    //   消えたりする)。 gdigrab は 1 コマ撮るたびに GDI の CAPTUREBLT で
    //   画面を写すため、 その瞬間カーソルが消えて点滅して見える。
    //   Desktop Duplication で撮る ddagrab ならこれが起きないので、
    //   使える時 (ffmpeg に入っていて、 モニターが 1 枚の時) はそちらを使う。
    //   ddagrab は 1 つの出力しか撮れないため、 複数モニターでは今まで通り
    //   gdigrab で全体を撮る。
    List<String>? ddagrabArgs;
    if (scap.monitorCount() == 1 && await _supportsDdagrab(ffmpegPath)) {
      final opts = StringBuffer('ddagrab=framerate=30');
      if (r != null) {
        final ox = r.x < 0 ? 0 : r.x;
        final oy = r.y < 0 ? 0 : r.y;
        opts.write(':video_size=${r.width}x${r.height}'
            ':offset_x=$ox:offset_y=$oy');
      }
      ddagrabArgs = <String>[
        '-y',
        '-filter_complex', '$opts,hwdownload,format=bgra',
        ...outArgs,
      ];
    }
    _err.clear();
    final gen = ++_gen;
    // ddagrab が使えるならまずそれで。 環境によっては起動直後に落ちる事が
    // あるので、 その時は gdigrab で取り直す (下の _launch が面倒を見る)。
    await _launch(ffmpegPath, ddagrabArgs ?? gdigrabArgs, gen,
        fallback: ddagrabArgs != null ? gdigrabArgs : null);
    _dest = dest;
    _sec = 0;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _sec++;
      notifyListeners();
    });
    notifyListeners();
    return dest;
  }

  /// ffmpeg を立ち上げて [_proc] に据える。 起動直後 (数秒以内) に落ちたら
  /// [fallback] の引数で 1 回だけ取り直す (範囲指定が画面外・ddagrab 非対応
  /// など)。 [gen] が進んでいたら「もう止められた後」 なので何もしない。
  Future<void> _launch(String ffmpegPath, List<String> args, int gen,
      {List<String>? fallback}) async {
    final proc = await Process.start(ffmpegPath, args);
    if (gen != _gen) {
      // 立ち上げている間に stop() された。 孤児にしない。
      try {
        proc.kill();
      } catch (_) {}
      return;
    }
    // ffmpeg は進捗もエラーも stderr に出す。 失敗した時に理由を出せるよう
    //   末尾だけ控える (全部ためると長時間の録画で膨らむ)。
    proc.stderr.transform(const SystemEncoding().decoder).listen((chunk) {
      _err.write(chunk);
      if (_err.length > 4000) {
        final tail = _err.toString();
        _err
          ..clear()
          ..write(tail.substring(tail.length - 2000));
      }
    }, onError: (_) {});
    _proc = proc;
    final startedAt = DateTime.now();
    // 起動直後に落ちる (範囲指定が画面外など) 場合をここで捕まえる。
    unawaited(proc.exitCode.then((code) async {
      if (gen != _gen || !identical(_proc, proc)) return;
      if (fallback != null &&
          DateTime.now().difference(startedAt) <
              const Duration(seconds: 4)) {
        try {
          await _launch(ffmpegPath, fallback, gen);
          return;
        } catch (_) {}
      }
      _timer?.cancel();
      _timer = null;
      _proc = null;
      notifyListeners();
    }));
  }

  /// 録画を止めて、 出来たファイルのパスを返す。
  /// 失敗した (ファイルが出来ていない) 時は [ScreenRecException] を投げる。
  Future<String> stop() async {
    if (_androidRecording) return _stopAndroid();
    _gen++; // 遅れて届く「取り直し」 を無効にする。
    final proc = _proc;
    final dest = _dest;
    _timer?.cancel();
    _timer = null;
    _proc = null;
    _dest = null;
    notifyListeners();
    if (proc == null || dest == null) {
      throw ScreenRecException('録画していません');
    }
    try {
      // 一応 'q' も送る (コンソール付きで動いている時はこれで綺麗に閉じる)。
      // ただし標準入力がパイプの時は届かないので、 これだけには頼らない。
      proc.stdin.write('q');
      await proc.stdin.flush();
    } catch (_) {}
    try {
      await proc.exitCode.timeout(const Duration(milliseconds: 1200));
    } catch (_) {
      // 'q' が効かない時はここへ来る。 断片化 mp4 で書いているので、
      // 強制終了しても最後の断片までは再生できる形で残る。
      try {
        proc.kill();
      } catch (_) {}
      try {
        await proc.exitCode.timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    // 書き込みが終わるまで少し待つ。
    for (var i = 0; i < 20; i++) {
      try {
        final f = File(dest);
        if (await f.exists() && await f.length() > 20000) return dest;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    // ★ ここまで来たら録れていない。 以前は中身の無いファイルをそのまま
    //   タイムラインに載せていたので、 画面には出ないのに項目だけ増えて
    //   「録画が表示されない」 状態になっていた (= ユーザー報告)。
    final why = _lastErrorLine();
    throw ScreenRecException(
        why.isEmpty ? '録画ファイルが作られませんでした' : why);
  }

  String _lastErrorLine() {
    final lines = _err
        .toString()
        .split(RegExp(r'[\r\n]+'))
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) return '';
    // それらしい行 (Error / Invalid / failed) を優先。
    for (final l in lines.reversed) {
      final t = l.toLowerCase();
      if (t.contains('error') ||
          t.contains('invalid') ||
          t.contains('failed') ||
          t.contains('no such')) {
        return l.trim();
      }
    }
    return lines.last.trim();
  }
}

class ScreenRecException implements Exception {
  final String message;
  ScreenRecException(this.message);
  @override
  String toString() => message;
}

/// 録る範囲 (画面の物理ピクセル)。
class ScreenRecRegion {
  final int x;
  final int y;
  final int width;
  final int height;
  const ScreenRecRegion(this.x, this.y, this.width, this.height);

  /// libx264 (yuv420p) は偶数の幅・高さしか受け付けないので丸める。
  ScreenRecRegion evened() => ScreenRecRegion(
        x,
        y,
        width - (width % 2),
        height - (height % 2),
      );

  Map<String, int> toJson() => {'x': x, 'y': y, 'w': width, 'h': height};

  static ScreenRecRegion? fromJson(Map<dynamic, dynamic>? m) {
    if (m == null) return null;
    final x = (m['x'] as num?)?.toInt();
    final y = (m['y'] as num?)?.toInt();
    final w = (m['w'] as num?)?.toInt();
    final h = (m['h'] as num?)?.toInt();
    if (x == null || y == null || w == null || h == null) return null;
    if (w < 16 || h < 16) return null;
    return ScreenRecRegion(x, y, w, h);
  }

  @override
  String toString() => '${width}x$height (+$x,+$y)';
}
