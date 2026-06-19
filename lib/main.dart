import 'dart:io' show Platform, File;
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
// flutter_quill (リッチテキスト) のUIローカライズ delegate を MaterialApp に追加する。
import 'package:flutter_quill/flutter_quill.dart' show FlutterQuillLocalizations;
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import 'package:fvp/fvp.dart' as fvp;
import 'providers/mind_map_provider.dart';
import 'screens/mind_map_screen.dart';
import 'services/home_shortcut_service.dart';

/// アプリ全体で使うローカル通知プラグインのインスタンス。
/// `mind_map_screen.dart` から参照できるよう、 トップレベル変数として公開。
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

/// 「後で通知」 で使う Android の通知チャンネル ID。
const String kNodeReminderChannelId = 'mokumoku_node_reminders';
const String kNodeReminderChannelName = 'ノード通知';
const String kNodeReminderChannelDescription = '「後で通知」 で予約したノードの通知';

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // ── サブウィンドウ (発表者モードの「聴衆ウィンドウ」) として起動された場合 ──
  // desktop_multi_window はサブウィンドウを同じ実行ファイルで
  //   ['multi_window', '<windowId>', '<arguments>'] という引数で起動する。
  // その場合は通常のアプリ初期化をスキップし、 スライド画像だけを全画面表示
  //   する軽量アプリを起動する (= メモは出さない＝共有してよいクリーン画面)。
  if (!kIsWeb && args.isNotEmpty && args.first == 'multi_window') {
    final windowId = int.tryParse(args.length > 1 ? args[1] : '') ?? 0;
    Map<String, dynamic> argMap = const {};
    try {
      if (args.length > 2 && args[2].isNotEmpty) {
        argMap = jsonDecode(args[2]) as Map<String, dynamic>;
      }
    } catch (_) {/* 引数解析失敗時は空 */}
    runApp(_AudienceWindowApp(windowId: windowId, args: argMap));
    return;
  }
  // ── デスクトップの動画再生バックエンドを登録 (= ビデオエディターの
  //   プレビューが Windows/Linux で真っ黒になる問題の対策) ──
  // fvp(libmdk) を video_player の Platform 実装としてデスクトップに供給。
  // Android/iOS は公式バックエンド (ExoPlayer/AVPlayer) のままにしたいので
  // platforms を windows/linux/macos に限定する。
  try {
    fvp.registerWith(options: {
      'platforms': ['windows', 'linux', 'macos'],
    });
  } catch (_) {/* 登録失敗時は従来通り (モバイルは公式実装で動く) */}
  // ホーム画面/デスクトップのショートカット (--page=<id>) から起動された場合の
  //   ページ ID を記録 (Windows)。 Android は MethodChannel 経由で別途取得する。
  HomeShortcutService.windowsLaunchPageId =
      HomeShortcutService.pageIdFromArgs(args);
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  // ── ローカル通知プラグインの初期化 ──
  // タイムゾーン DB を読み込んで、 端末のローカル TZ を設定。
  // zonedSchedule は TZDateTime で時刻を指定するので必須。
  tz_data.initializeTimeZones();
  try {
    tz.setLocalLocation(tz.getLocation('Asia/Tokyo'));
  } catch (_) {/* TZ 取得失敗時は UTC のままで問題なし */}

  // ── 通知の初期化 + Android 権限リクエストはバックグラウンドで ──
  // ★ 起動ハング対策: これらを runApp の前で await すると、 特に Android で
  //   起動画面が「読み込み中」 のまま固まることがある。 権限ダイアログは
  //   Activity が用意できてからでないと表示できず、 runApp 前に
  //   requestNotificationsPermission() 等を await すると、 ダイアログが出せず
  //   await が返らないまま runApp に到達できない (= 画面が出ない) ため。
  //   そこで await せず fire-and-forget で実行し、 runApp を即座に呼ぶ。
  // ignore: discarded_futures
  _initNotificationsAndPermissions();

  // デスクトップ版のみ window_manager を初期化
  if (!kIsWeb &&
      (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        title: 'MokuMoku',
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );

    // ── デスクトップの OS 通知 (local_notifier) を初期化 ──
    // ユーザー要望「windows 版の通知方法をアプリ内通知ではなく OS 通知に」
    //   への対応。 Windows では shortcutPolicy.requireCreate でスタートメニュー
    //   ショートカット (AUMID 紐付け) を作成し、 MSIX 化していなくても
    //   トーストが表示できるようにする。 macOS / Linux では shortcutPolicy は
    //   無視される。
    try {
      await localNotifier.setup(
        appName: 'Kamispec',
        shortcutPolicy: ShortcutPolicy.requireCreate,
      );
    } catch (e) {
      debugPrint('local_notifier 初期化失敗: $e');
    }
  }

  runApp(const MyApp());
}

/// 通知プラグインの初期化と Android 権限リクエストをバックグラウンドで実行する。
/// (= 起動時に「読み込み中」 画面で固まる不具合の対策。 runApp をブロックしない)
/// 失敗しても通知が出ないだけでアプリ本体は動くので、 すべて try/catch で握る。
Future<void> _initNotificationsAndPermissions() async {
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const initSettings = InitializationSettings(android: androidInit);
  try {
    await flutterLocalNotificationsPlugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (NotificationResponse resp) {
        debugPrint('通知タップ: ${resp.payload}');
      },
    );
  } catch (e) {
    debugPrint('flutter_local_notifications 初期化失敗: $e');
  }

  // Android 13+ の通知 permission をリクエスト (起動時に 1 回だけ)。
  if (!kIsWeb && Platform.isAndroid) {
    try {
      final androidImpl = flutterLocalNotificationsPlugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      await androidImpl?.requestNotificationsPermission();
      await androidImpl?.requestExactAlarmsPermission();
    } catch (e) {
      debugPrint('Android 通知 permission リクエスト失敗: $e');
    }
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => MindMapProvider(),
      child: Consumer<MindMapProvider>(
        builder: (context, provider, _) {
          if (!kIsWeb &&
              (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
            windowManager.setTitle(provider.t('app.title'));
          }
          return MaterialApp(
            title: provider.t('app.title'),
            debugShowCheckedModeBanner: false,
            // flutter_quill (リッチテキスト) のUIローカライズ + Material/Cupertino の
            //   各言語化に必要な delegate。 これが無いと QuillEditor/QuillSimpleToolbar
            //   が実行時に例外を出す。
            localizationsDelegates: const [
              FlutterQuillLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: const [
              Locale('ja'),
              Locale('en'),
            ],
            themeMode: provider.isDarkMode ? ThemeMode.dark : ThemeMode.light,
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xFF6C63FF),
                brightness: Brightness.light,
              ),
              scaffoldBackgroundColor: const Color(0xFFD8D8D4),
              useMaterial3: true,
              fontFamily: 'sans-serif',
              // ── スクロールバー (スライドバー) を常時表示 + 白系で見やすく ──
              // ダイアログ / シートは暗色背景なので、 白系のサムにすると
              // 「スライドバーが見えない」 問題が解消する。 ユーザー要望対応。
              scrollbarTheme: ScrollbarThemeData(
                thumbVisibility: const WidgetStatePropertyAll(true),
                thickness: const WidgetStatePropertyAll(6),
                radius: const Radius.circular(8),
                thumbColor:
                    WidgetStatePropertyAll(Colors.white.withValues(alpha: 0.7)),
              ),
            ),
            darkTheme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xFF6C63FF),
                brightness: Brightness.dark,
              ),
              useMaterial3: true,
              fontFamily: 'sans-serif',
              // ── スクロールバー (スライドバー) を常時表示 + 白系で見やすく ──
              scrollbarTheme: ScrollbarThemeData(
                thumbVisibility: const WidgetStatePropertyAll(true),
                thickness: const WidgetStatePropertyAll(6),
                radius: const Radius.circular(8),
                thumbColor:
                    WidgetStatePropertyAll(Colors.white.withValues(alpha: 0.7)),
              ),
            ),
            home: const MindMapScreen(),
          );
        },
      ),
    );
  }
}

/// 発表者モードの「聴衆ウィンドウ」 (= 別ウィンドウ) のアプリ。
///
/// メインウィンドウ (発表者ビュー) が現在のスライドを PNG にレンダリングして
/// 渡してくるので、 それを黒背景に全画面で表示するだけの軽量アプリ。 メモや
/// 次スライドは含まれないため、 この窓を Meet 等で共有すればメモは相手に
/// 見えない。 更新は `DesktopMultiWindow.invokeMethod(id, 'update', {imagePath})`
/// で受け取る。
class _AudienceWindowApp extends StatefulWidget {
  final int windowId;
  final Map<String, dynamic> args;
  const _AudienceWindowApp({required this.windowId, required this.args});

  @override
  State<_AudienceWindowApp> createState() => _AudienceWindowAppState();
}

class _AudienceWindowAppState extends State<_AudienceWindowApp> {
  String? _imagePath;

  @override
  void initState() {
    super.initState();
    _imagePath = widget.args['imagePath'] as String?;
    // メインウィンドウからの更新 (スライド画像差し替え) を受け取る。
    DesktopMultiWindow.setMethodHandler((call, fromWindowId) async {
      if (call.method == 'update') {
        final m = call.arguments;
        final path = (m is Map) ? m['imagePath'] as String? : null;
        if (path != null && mounted) {
          setState(() => _imagePath = path);
        }
      }
      return null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final path = _imagePath;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: path == null
              ? const Text('スライド待機中…',
                  style: TextStyle(color: Colors.white38, fontSize: 16))
              : Image.file(
                  File(path),
                  key: ValueKey(path),
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
        ),
      ),
    );
  }
}
