import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';

// 自動操作へ渡す合図 (= ユーザー要望: アシスタントから PC を操作)。
import '../main.dart'
    show
        automationRequestFromAssistant,
        automationRunForAssistant,
        automationCancelRequest,
        automationForceResetRequest,
        AutomationRunState;
import '../providers/mind_map_provider.dart';
import '../utils/build_flags.dart';
// ★ 絵の拡張子の共通一覧 (jpe / jfif 対応)。
import '../utils/image_file_types.dart';

/// アプリ内蔵の MCP サーバー (= ユーザー要望: アプリ内蔵型で MCP サーバーを
/// 実装して Claude から指示を出してマップを編集できるように)。
///
/// - トランスポート: Streamable HTTP (JSON-RPC 2.0 を POST で受ける最小実装。
///   SSE ストリームは提供せず、 各リクエストに JSON で即応答する)。
/// - 待ち受け: 127.0.0.1 のみ (LAN へは公開しない)。 ポートは 8765 から空きを探す。
/// - 接続例 (Claude Code):
///   `claude mcp add --transport http kamispec http://127.0.0.1:8765/mcp`
///
/// ツール: list_pages / read_page / create_page / add_node / update_node /
/// delete_node / connect_nodes / add_image_node。 すべて Provider の公開
/// facade (mcp*) 経由で、 変更は既存の保存経路 (_saveToStorage) に乗り、
/// 起動中の画面へ即時反映される。
class McpServer {
  McpServer(this._provider);

  /// 外部のアプリから HTTP で呼ばれた時に、 危ない道具を伸ばすか
  /// (= ユーザーが「パソコンの操作も許す」 を選んだ時だけ true)。
  ///
  /// アプリ内の AI チャットは HTTP を通らず直接 [callTool] を呼ぶので、
  /// この限定の外側にいる (今までどおり全部使える)。
  bool allowPowerfulTools = false;

  /// 外部からは伸ばさない道具 (危険度順)。
  ///
  /// ・ run_automation … パソコンそのものを動かす。
  /// ・ read_device_file / pick_user_file … 端末のファイルを読む。
  /// ・ create_document_file … ディスクへ書き出す (時に上書きする)。
  /// ・ run_app_command … アプリのボタンを任意に押せる。
  static const Set<String> kPowerfulTools = {
    'run_automation',
    // ★ 実行枠の初期化。 走っている自動操作を捨てるので、 外のプログラムから
    //   勝手には出さない (中止と同じ側の道具)。
    'force_reset_automation',
    'read_device_file',
    'pick_user_file',
    'create_document_file',
    'run_app_command',
    // ★ 開いているファイルの中身を全文返したり上書きする道具もこちら側。
    //   (= 点検で発見: 「ファイルの読み書きは許さない」 と言いながら
    //   この 2 つが抜け道になっていた)。
    'text_file_read',
    'text_file_edit',
    'text_file_status',
    // ★ 前払いの AI クレジットを使う = お金が減る。 外部からは既定で出さない。
    'generate_page_background',
    // ★ 利用者のクラウドの枠を使う (月の上限が減る)。 外部からは既定で出さない。
    'cloud_sync',
    // ★ Jev の入切。 入れると利用者の文の断片が外 (代行 → Jev) へ出て、
    //   AI クレジットも減る。 読む方 (get_jev_settings) は素通しでよいが、
    //   切り替えは外部のプログラムから勝手にさせない。
    'set_jev_settings',
    // ★ 開発者モードの上限いじり。 中身を試すための物なので、 外の
    //   プログラムからは既定で見せない (開発者モードでない時は、 呼んでも
    //   断られる)。
    'get_dev_limits',
    'set_dev_limits',
  };

  /// 開発者モードの間だけ使える道具。 中身を試すための物なので、 ふだんは
  /// 一覧にも出さない (= ユーザー要望: 開発者モードであれば設定してテスト
  /// できるように)。
  static const Set<String> kDevOnlyTools = {
    'get_dev_limits',
    'set_dev_limits',
  };

  final MindMapProvider _provider;
  HttpServer? _http;

  /// 稼働中の MCP エンドポイント URL (停止中は null)。
  String? url;

  /// 外部アプリからの接続に必要な合言葉 (= ユーザー要望: 別のプログラムから
  /// 勝手に操作されないように)。 これを知らないプログラムは 401 で弾かれる。
  ///
  /// ★ 中身は MindMapProvider が prefs (`mcp_token_v1`) に持っていて、
  ///   ここは start() で預かるだけ。 **起動のたびには作り直さない**
  ///   (作り直すと、 相手側の設定に書いた URL が次の起動で必ず 401 になり、
  ///   外部接続が使い物にならない)。 失効させる道は
  ///   MindMapProvider.regenerateMcpToken だけ。
  String? _token;
  String? get token => _token;

  bool get running => _http != null;

  /// [token] を渡すと、 その合言葉を持つ相手だけ受け付ける。
  Future<String?> start({String? token}) async {
    if (_http != null) return url;
    _token = token;
    for (var port = 8765; port < 8775; port++) {
      try {
        _http = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
        url = token == null
            ? 'http://127.0.0.1:$port/mcp'
            : 'http://127.0.0.1:$port/mcp?token=$token';
        _http!.listen(_handle, onError: (_) {});
        // ★ 合言葉はログへ出さない (= 点検: ?token= 付きで印字していた)。
        debugLog('MCP サーバー起動: http://127.0.0.1:$port/mcp');
        return url;
      } on SocketException {
        continue; // ポートが塞がっていたら次を試す
      }
    }
    return null;
  }

  Future<void> stop() async {
    final s = _http;
    _http = null;
    url = null;
    _token = null;
    await s?.close(force: true);
  }

  /// 合言葉が合っているか。 ヘッダ (Authorization: Bearer xxx) でも
  /// URL の ?token=xxx でも受け付ける。
  bool _authorized(HttpRequest req) {
    final t = _token;
    // ★ 合言葉無しの待ち受けは認めない。
    //   127.0.0.1 だから安全、 とは言えない (同じ PC で動く別の
    //   プログラムは誰でも叩ける)。 合言葉が無いなら入れない。
    if (t == null || t.isEmpty) return false;
    final q = req.uri.queryParameters['token'];
    if (q != null && q == t) return true;
    final h = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
    if (h.startsWith('Bearer ') && h.substring(7).trim() == t) return true;
    return false;
  }

  void debugLog(String msg) {
    // ignore: avoid_print
    print('[MCP] $msg');
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      if (req.uri.path != '/mcp') {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      // ── ブラウザ経由のなりすましを塞ぐ ──
      //
      //   ・ Host 検査: 攻撃者のページが自分のドメインを 127.0.0.1 へ
      //     向け直す (DNS リバインディング) と、 同じ出所扱いになって
      //     応答まで読まれる。 本物のクライアントは必ず 127.0.0.1 を名乗る。
      //   ・ Origin 検査: 正規の MCP クライアントは Origin を送らない。
      //     付いている = ブラウザからの要求なので断る。
      //   ・ CORS の許可ヘッダは**付けない**。 OPTIONS も受けない。
      // ★ dart:io の headers.host はポートを切り離して返す (ポートは
      //   headers.port)。 以前は startsWith('127.0.0.1:') も見ていたが、
      //   それは絶対に成立しない死にコードだった (= 点検で判明)。
      final host = (req.headers.host ?? '').toLowerCase();
      if (!const {'127.0.0.1', 'localhost', '::1', '[::1]'}.contains(host)) {
        req.response.statusCode = HttpStatus.forbidden;
        req.response.write('bad host');
        await req.response.close();
        return;
      }
      // Origin が付いている = ブラウザからの要求。 自分自身を名乗る
      //   場合だけ通す (Electron の画面から叩く実装もあるため)。
      final origin = (req.headers.value('origin') ?? '').toLowerCase();
      if (origin.isNotEmpty &&
          origin != 'null' &&
          !origin.startsWith('http://127.0.0.1') &&
          !origin.startsWith('http://localhost')) {
        req.response.statusCode = HttpStatus.forbidden;
        req.response.write('browser origin not allowed');
        await req.response.close();
        return;
      }
      // 合言葉が合わない相手は入れない (= ユーザー要望)。
      if (!_authorized(req)) {
        req.response.statusCode = HttpStatus.unauthorized;
        req.response.write('unauthorized');
        await req.response.close();
        return;
      }
      // SSE ストリーム (GET) は未提供。 セッション終了 (DELETE) は受理のみ。
      if (req.method == 'GET') {
        req.response.statusCode = HttpStatus.methodNotAllowed;
        await req.response.close();
        return;
      }
      if (req.method == 'DELETE') {
        req.response.statusCode = HttpStatus.ok;
        await req.response.close();
        return;
      }
      if (req.method != 'POST') {
        req.response.statusCode = HttpStatus.methodNotAllowed;
        await req.response.close();
        return;
      }
      final body = await utf8.decoder.bind(req).join();
      final dynamic msg = body.isEmpty ? null : jsonDecode(body);
      if (msg is! Map<String, dynamic>) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      final method = msg['method'] as String? ?? '';
      final Object? id = msg['id'];
      // id 無し = notification (notifications/initialized 等) は受理のみ。
      if (id == null) {
        req.response.statusCode = HttpStatus.accepted;
        await req.response.close();
        return;
      }
      Map<String, dynamic> resp;
      try {
        final params =
            (msg['params'] as Map?)?.cast<String, dynamic>() ?? const {};
        final result = await _dispatch(method, params);
        resp = {'jsonrpc': '2.0', 'id': id, 'result': result};
      } on _McpMethodNotFound {
        resp = {
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32601, 'message': 'Method not found: $method'},
        };
      } catch (e) {
        resp = {
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32603, 'message': '$e'},
        };
      }
      req.response.headers.contentType =
          ContentType('application', 'json', charset: 'utf-8');
      req.response.write(jsonEncode(resp));
      await req.response.close();
    } catch (e) {
      debugLog('リクエスト処理失敗: $e');
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<Map<String, dynamic>> _dispatch(
      String method, Map<String, dynamic> params) async {
    switch (method) {
      case 'initialize':
        {
          // ★ = 調査報告 BUG-22「相手の protocolVersion をそのまま返すので、
          //   対応していない版でも対応済みに見えてしまう」。 こちらが本当に
          //   話せる版の中から選んで返す。 知らない版を言われた時は、 既定の
          //   版を返した上で**話せる版の一覧**を添える (JSON-RPC の決まりでは
          //   こうして相手に選び直させる)。
          const supported = <String>['2025-06-18', '2025-03-26', '2024-11-05'];
          final asked = (params['protocolVersion'] as String?)?.trim() ?? '';
          final agreed = supported.contains(asked) ? asked : supported.first;
          return {
            'protocolVersion': agreed,
            'capabilities': {
              'tools': {'listChanged': false},
            },
            'serverInfo': {'name': 'kamispec-mcp', 'version': '1.0.0'},
            if (asked.isNotEmpty && agreed != asked) ...{
              'supportedProtocolVersions': supported,
              'note': 'this server does not speak "$asked"; it answered with '
                  '"$agreed". Use one of supportedProtocolVersions.',
            },
          };
        }
      case 'ping':
        return {};
      case 'tools/list':
        // 外部へは、 許していない道具をそもそも見せない
        //   (見えると AI が使おうとして失敗し続ける)。
        // ★ 開発者モードの上限いじりも同じ理由で、 開発者モードでない間は
        //   出さない (= ユーザー要望: 開発者モードの時だけ試せるように)。
        return {
          'tools': [
            for (final t in toolDefs)
              if ((allowPowerfulTools || !kPowerfulTools.contains(t['name'])) &&
                  (_provider.developerMode ||
                      !kDevOnlyTools.contains(t['name'])))
                t,
          ],
        };
      case 'tools/call':
        final name = params['name'] as String? ?? '';
        if (!allowPowerfulTools && kPowerfulTools.contains(name)) {
          return {
            'content': [
              {
                'type': 'text',
                'text': 'This tool is turned off for external apps. '
                    'The user can allow it in the app '
                    '(AI assistant → external access → '
                    '"also allow operating the PC and files").',
              }
            ],
            'isError': true,
          };
        }
        return callTool(
          name,
          (params['arguments'] as Map?)?.cast<String, dynamic>() ?? const {},
        );
      default:
        throw _McpMethodNotFound();
    }
  }

  // ─── ツール定義 ───────────────────────────────────────────────────────

  /// 読むだけの道具 (= ページや設定を一切書き換えない)。
  ///
  /// ★ = ユーザー報告「読み取りが承認ポリシーで拒否された」。
  ///   道具に注記 (annotations) が無いと、 codex などの相手は
  ///   安全側に倒して「壊す道具」と見なし、 承認を求める。
  ///   読むだけだと名乗っておけば、 どの相手でもそのまま通る。
  static const Set<String> _readOnlyTools = {
    // 探すだけ (何も書き換えない)。
    'search_pages',
    'search_folder_files',
    'list_pages',
    'read_page',
    'list_folders',
    'list_app_docs',
    'read_app_doc',
    'list_app_commands',
    'list_paint_tabs',
    'read_device_file',
    // ★ ページ本文の読み返し (= 動作検証レポート 改善案 2)。 何も変えない。
    'read_markdown',
    'read_document',
    'read_paint_items',
    'get_automation_status',
    'read_automation_page',
    'list_video_editor_items',
    'list_orphan_files',
    'get_dev_limits',
    // ★ = 機能追加案 継続検証190。 今の画面の様子を読むだけ。
    'describe_screen',
    // ★ Jev の入切を読むだけ (= ユーザー要望: MCP が Jev に対応していない)。
    'get_jev_settings',
  };

  static Map<String, dynamic> _tool(
          String name, String description, Map<String, dynamic> props,
          [List<String> required = const []]) =>
      {
        'name': name,
        'description': description,
        'inputSchema': {
          'type': 'object',
          'properties': props,
          if (required.isNotEmpty) 'required': required,
        },
        // この道具が何をする物かを名乗る (上の説明)。
        // どれもこのパソコンの中のアプリを触るだけなので、
        // 外の世界へは出ない (openWorldHint: false)。
        'annotations': <String, dynamic>{
          'title': name,
          'readOnlyHint': _readOnlyTools.contains(name),
          'destructiveHint': false,
          'idempotentHint': _readOnlyTools.contains(name),
          'openWorldHint': false,
        },
      };

  /// ツール定義 (アプリ内 AI チャットからも共用するため公開)。
  static final List<Map<String, dynamic>> toolDefs = [
    // ── パソコンの操作は「自動操作」 に委ねる (= ユーザー要望: アシスタント
    //    に chrome を起動させて何かやってと言ったら自律的に動くように) ──
    //    ここで OS を直に叩かないのは、 許可の仕組みを 1 箇所に集めるため。
    _tool(
        'run_automation',
        'Run a task on the PC itself (launch and drive real apps such as '
        'Chrome, click, type, press keys) by handing the instruction to the '
        'built-in Web/PC automation. Use this whenever the user asks to '
        'start or operate an application outside this app. The automation '
        'panel opens, the AI there plans the steps and runs them while the '
        'user watches. It obeys the user\'s permission setting (off / ask '
        'every time / allow all), so it may pause for confirmation or refuse. '
        'Desktop only. Returns a "runId" straight away, BEFORE the task has '
        'run: poll get_automation_status with that runId to learn whether it '
        'is still going, waiting for the user, finished or failed, and use '
        'cancel_automation to stop it. NEVER tell the user the task is done '
        'from this reply alone.',
        {
          'instruction': {
            'type': 'string',
            'description':
                'What to do, in the user\'s own words. Example: "PC の Chrome '
                'を起動して example.com を開いて".'
          }
        },
        ['instruction']),
    // ★ = 動作検証の機能修正案「自動操作の完了状態を MCP から確認・中止できる
    //   ようにする」。 run_automation は受け付けた所で返るので、 呼んだ側は
    //   終わったのか / 確認待ちなのかを知る道が無かった。
    _tool(
        'get_automation_status',
        'Check how the PC automation started by run_automation is going. '
        'Pass the "runId" it returned, or nothing for the latest run. '
        'Returns {runId, state, finished, awaitingUser, status, steps, '
        'ranSteps, startedAt, finishedAt, error} plus "busyRunId" and '
        '"workerState" (which run actually holds the single run slot right '
        'now, which is NOT always the most recent runId). state is one of: '
        '"accepted" (handed over, the panel has not picked it up yet), '
        '"running", "awaitingUser" (it is waiting for the user to confirm '
        'or to sign in - tell them to look at the panel), "cancelling" (a '
        'stop was asked for but the run has not let go of the slot yet - keep '
        'polling), "done", "failed", "cancelled", "refused" (another run '
        'was still going, so nothing started). Earlier runs stay readable, so '
        'a run you started is still answerable after a later request was '
        'refused. Poll this every few seconds rather than assuming success, '
        'and report the state you actually read. "done" means every planned '
        'step ran; a step that failed (a command exiting non-zero, or a file '
        'it had to make missing) gives "failed" with the reason.',
        {
          'runId': {'type': 'string'},
        }),
    _tool(
        'cancel_automation',
        'Stop the PC automation started by run_automation. Pass the "runId" '
        'it returned, or nothing for the run that holds the slot. This is the '
        'same stop the user can press in the panel. Returns {cancelled, '
        'state}: cancelled is false when the run had already finished (state '
        'says which) - say so instead of claiming you stopped it. The state '
        'goes "cancelling" first and becomes "cancelled" only once the run '
        'has really let go of the slot, so keep polling '
        'get_automation_status. If it stays "cancelling", '
        'force_reset_automation frees the slot.',
        {
          'runId': {'type': 'string'},
        }),
    // ★ = 不具合報告 2026-09-30「cancel 済みの長時間待機が実行枠を占有し
    //   続けて再停止もできない」。 ふつうの中止で空かない時の最後の手段。
    _tool(
        'force_reset_automation',
        'Free the PC automation run slot when a normal cancel did not. It '
        'drops whatever is still waiting (a long wait, a browser connection, '
        'the run lock) and marks the run cancelled, so the next '
        'run_automation can start. It does NOT touch saved steps, open pages '
        'or any unsaved editing - only the running job. Use it after '
        'cancel_automation has left the state at "cancelling" or a run keeps '
        'refusing with "another automation run is still going". Returns what '
        'the slot looked like before and after.',
        {}),
    // ★ = 不具合報告 2026-09-30「automation ページの read_page が必ず失敗する
    //   read_document を案内する」。 automation ページの中身 (手順) を読む道。
    _tool(
        'read_automation_page',
        'Read the steps saved on an automation ("自動操作") page - the thing '
        'the user actually sees on that page. read_page only reports the '
        'page\'s hidden mind-map layer, and read_document cannot open this '
        'kind at all, so use this one. Pass "pageId" (from list_pages) or '
        'nothing for the page being shown. Returns {pageId, name, stepCount, '
        'steps} where each step has its kind and the values that matter '
        '(text, selector, durationMs, count, breakpoint, expectFile) and a '
        'loop carries its "children". An empty list means the page really has '
        'no steps yet. This is read-only: run_automation drives the shared '
        'automation panel, not this page.',
        {
          'pageId': {'type': 'string'},
        }),
    // ★ isCurrent を必ず説明に書く (= ユーザー報告: 「このページ消して」 で
    //   全ページを消しにいった)。 どれが「今のページ」 かを知る手立てが
    //   説明に無いと、 AI は当てずっぽうで全部に手を出す。
    // ── 開発者モードの上限いじり (= ユーザー要望: MCP で開発者モードなら
    //    ファイルの上げられる量や AI の呼び出し上限を決めて試せるように) ──
    _tool(
        'get_dev_limits',
        'Read the developer-mode test limits and how much has been used: '
        'the self-imposed upload cap (MB) with the MB uploaded this month, '
        'and the self-imposed AI caps (US dollars spent, and number of AI '
        'calls made). Also returns developerMode and the acting plan. These '
        'caps exist so the developer can see what a normal user sees when a '
        'limit is hit - a developer account is otherwise effectively '
        'unlimited. Read-only.',
        {}),
    _tool(
        'set_dev_limits',
        'Set the developer-mode test limits, so you can check what happens '
        'when a limit is reached. Only works while developer mode is on; '
        'otherwise it refuses and changes nothing. Pass only the ones you '
        'want to change - anything you leave out stays as it is, and 0 means '
        '"no cap". uploadMb caps how much can be uploaded to the cloud this '
        'month. aiUsd caps how many US dollars of AI the app will spend. '
        'aiCalls caps how many AI calls can be made. Use resetUploadUsage / '
        'resetAiUsage to put the used amounts back to 0 so the same limit can '
        'be tested again. Call get_dev_limits afterwards to confirm.',
        {
          'uploadMb': {
            'type': 'number',
            'description': 'Upload cap in MB for this month. 0 = no cap.'
          },
          'aiUsd': {
            'type': 'number',
            'description': 'AI spending cap in US dollars. 0 = no cap.'
          },
          'aiCalls': {
            'type': 'integer',
            'description': 'How many AI calls are allowed. 0 = no cap.'
          },
          'resetUploadUsage': {
            'type': 'boolean',
            'description': 'Put the amount uploaded this month back to 0.'
          },
          'resetAiUsage': {
            'type': 'boolean',
            'description': 'Put the spent dollars and call count back to 0.'
          },
        }),
    _tool('list_pages',
        'List all pages (id, name, type: normal/bookshelf/paint/..., node '
        'count, isCurrent, orderIndex, lastModified), plus foregroundContext. '
        'The array is sorted with the current map FIRST, so it is NOT the '
        'real page order - "orderIndex" is. To back up the order before '
        'calling reorder_pages, sort the entries by orderIndex and keep those '
        'ids; passing that same list back to reorder_pages restores exactly '
        'what the user had. '
        'ALWAYS read foregroundContext first: it is the single answer to '
        '"what does an instruction with no named target mean". '
        'kind:"file" means a FILE is open on top of the map and THAT file is '
        'the target (its pageId is only the map behind it); kind:"page" means '
        'the page named there is the target. isCurrent in the page list says '
        'only which MAP is current - it does NOT mean the user is looking at '
        'that page rather than a file on top of it. The FIRST page entry is '
        'the current map. Never guess a target from a page name, and never '
        'act on other pages. Do NOT call this tool just to find out where to '
        'work: start from the open page (read_page with no pageId) and only '
        'list pages when the user names a different one. lastModified is the last EDIT time, NOT the creation '
        'time, so it cannot decide which of two same-named pages is "the old '
        'one" - show the times and let the user pick.',
        {}),
    // ── 探す道具 (= ユーザー要望: フォルダー内検索でトークンを抑える) ──
    //    ★ 説明文は毎回の会話に載るので短く。 「一覧 + 丸読み」 より
    //      こちらを先に使わせるのが目的。
    _tool(
        'search_pages',
        'Search node titles, memos, captions, table cells, PDF memos and the '
        'body of markdown / notepad / free-note pages and video-editor '
        'captions, across pages. Free-note hits cover every binder and every '
        'tab (the hit title names them). A hit with "hiddenInPageType" is '
        'text kept in another page type body of that page: it is really '
        'there, but it is NOT on screen until the page type is switched back '
        '- say that, never claim it is visible. '
        'Full-width and half-width letters and '
        'digits match each other, and any run of spaces, tabs or line breaks '
        'matches any other. '
        'Use this INSTEAD OF list_pages + read_page when you are looking for '
        'something: it returns only short snippets (pageId, pageName, nodeId, '
        'title, snippet, matchCount), never whole pages, so it costs a '
        'fraction of the tokens. scope: "all" (default), "folder" (the open '
        'page folder) or "page" (the open page). verdict tells you whether '
        'the answer looks present ("found"), partly ("partial"), absent '
        '("absent") or unknown - when it says absent, do NOT start reading '
        'pages one by one; say you could not find it. "scope" must be exactly '
        'page / folder / all - a typo is refused, never widened to all. '
        '"maxHits" must be a whole number from 1 to 40 (0, negatives and '
        'fractions are refused). The reply carries totalMatches / returned / '
        'truncated, so you can tell "that is every match" from "that is the '
        'first few".',
        {
          'query': {'type': 'string'},
          'scope': {'type': 'string'},
          'maxHits': {'type': 'integer'},
        },
        ['query']),
    _tool(
        'search_folder_files',
        'Search INSIDE the files attached to pages (pdf, docx, xlsx, txt, '
        'csv...) and in the folder linked directory. Returns only short '
        'snippets (fileName, filePath, pageId, nodeId, snippet, matchCount) '
        'plus a verdict, never whole documents - read_device_file only after '
        'this points at a file. Omit folderId to search EVERY folder AND the '
        'pages outside any folder (slower: a verdict of "unknown" means not '
        'every file could be read - too many, or it ran out of time - so '
        'narrow it with a folderId from list_folders and search again). An '
        'unknown folderId is refused with folder_not_found, never answered as '
        '"nothing matched". '
        'This reads files from disk, so it is slower than search_pages: try '
        'search_pages first.',
        {
          'query': {'type': 'string'},
          'folderId': {'type': 'string'},
          'maxHits': {'type': 'integer'},
        },
        ['query']),
    _tool(
        'read_page',
        'Read one page. Returns nodeCount and connectionCount FIRST (they '
        'survive even if the rest is long), then the full page JSON (nodes, '
        'connections, decorations). Use it to check what really got made '
        'before you report it. '
        'Each node also carries "visualHeight": the height it is actually '
        'DRAWN at. Use visualHeight, never "height", when you work out where '
        'to put the next node - a table or chart node stores height:14 (just '
        'its drag strip at the top) while its visualHeight is the whole '
        'table. The same applies to image, video and long-memo nodes. '
        'pageId may be omitted: it then reads the page the user has open '
        '(start there for any instruction that does not name a page).',
        {'pageId': {'type': 'string'}}),
    _tool(
        'undo_page',
        'Undo ONE step of edits on a map page, and wait until it is saved '
        'before answering. Use this instead of run_app_command(id:"undo"): '
        'that one only presses the app button, so it may cancel an AI run, '
        'restore a deleted page or undo calendar events instead, it targets '
        'whatever page the user has on screen, and it saves 350ms LATER - so '
        'the undo can land on top of whatever you did next. '
        'pageId may be omitted (the open page). The answer says what was '
        'undone and whether more steps remain (canUndoMore), and by then '
        'read_page already shows the restored state. '
        'Only normal / bookshelf pages have this history: for paint, '
        'document and videoEditor pages the history lives in the editor '
        'window, so this reports no_history instead of pretending.',
        {'pageId': {'type': 'string'}}),
    _tool(
        'delete_page',
        'Delete a page permanently. Use this when the user explicitly asks to '
        'delete/remove a page. Cannot delete the last remaining page. '
        'Call list_pages first and use a real pageId from it - never make up '
        'an id. SCOPE: delete only the pages the user actually named. '
        '"this page" is the single page with isCurrent:true - delete that one '
        'and stop. There is no cap on how many pages you may delete: when the '
        'user asks for several pages (or for a whole named set), delete every '
        'one of them in the same turn without stopping to ask again. Just do '
        'not delete pages that were not asked for, and do not retry with '
        'another id when a delete fails. '
        'When the page is named clearly, just delete it - do not ask again. '
        'When it is NOT clear which page (two pages share a name, or the user '
        'says "the ones I do not need"), list the candidates and get an OK '
        'first. There is no restore tool: only the single most recently '
        'deleted page can be brought back, and only by the user pressing '
        'Ctrl+Z (undo) in the app. '
        'Files attached to the page are kept by default, which leaves them '
        'with no tile: pass deleteFile:"generated" to also send the files THIS '
        'APP created to the recycle bin (never permanent deletion), or '
        'deleteFile:"yes" for any of its files. The reply says what happened '
        'to each one, including "undoRestoresFile" - when that is false, '
        'Ctrl+Z brings the page and its tiles back but the file stays in the '
        'recycle bin, so warn the user instead of calling the undo complete.',
        {
          'pageId': {'type': 'string'},
          'deleteFile': {
            'type': 'string',
            'enum': ['no', 'generated', 'yes'],
          },
        },
        ['pageId']),
    _tool(
        'set_page_type',
        'Change an existing page to another type without losing its nodes. '
        'type: "normal" (mind map), "bookshelf" (gallery), "paint" (free '
        'note), "document" (notepad), "markdown" (markdown + mermaid)' +
        (kStoreBuild ? '. ' : ', "videoEditor". ') +
        'Use this when the user asks to convert/turn a page '
        'into another kind - the nodes stay, so never rebuild the page with '
        'delete_page + create_page. What a free note / notepad / markdown / '
        'video page holds is stored beside the page rather than inside it, so '
        'it survives a round trip too (switch the kind back and it is there '
        'again). The one exception: cloud sync only carries a free-note '
        '("paint") body, so a page converted away from "paint" does not take '
        'that drawing to another device. '
        'Converting a note page ("paint" / "document" / "markdown") to '
        '"normal" does NOT turn its text into nodes: the text is kept aside '
        'and simply stops being displayed, so the mind map looks empty. Read '
        'the old body back FIRST - read_markdown / read_document / '
        'read_paint_items, or list_video_editor_items for a video page - and '
        'create the nodes yourself with add_node. (read_page still returns '
        'nodes / connections / decorations only, never the body.) A page '
        'turned into "markdown" can be filled in with write_markdown. '
        '${kStoreBuild ? 'These five' : 'These six'} are the only page '
        'kinds the app has; if the user names '
        'something else, say so instead of picking the closest one.',
        {
          'pageId': {'type': 'string'},
          'type': {
            'type': 'string',
            'enum': [
              'normal',
              'bookshelf',
              'paint',
              'document',
              'markdown',
              if (!kStoreBuild) 'videoEditor'
            ]
          },
        },
        ['pageId', 'type']),
    _tool(
        'clear_chat_history',
        'Clear this AI assistant conversation history. Use it when the user '
        'asks to clear/reset the chat. The current request stays. '
        'It is ALL or nothing - single messages or "just the last exchange" '
        'cannot be removed, so say that and ask before wiping everything. '
        'Once cleared the earlier turns are gone for good, including from '
        'your own context: do not claim to remember what was in them.',
        {}),
    _tool(
        'set_header_buttons',
        'Put buttons on the app header bar. ids are command ids from '
        'list_app_commands. replace=true swaps the whole row, false (default) '
        'appends. Use this when the user asks to place buttons in the header. '
        'replace=true OVERWRITES the previous row permanently - there is no '
        'undo and no way to read it back afterwards, so call this once with '
        'ids:[] first (that changes nothing and returns the current row) '
        'and show the user what is there before you replace it. '
        'Returns {header, ignored, blocked}: "ignored" are ids that do not '
        'exist on this device, and "blocked" are real ids the app refuses to '
        'place. "blocked" is EMPTY today - every id list_app_commands returns '
        'can be placed, cloud sync ("sync") included, so never refuse it as '
        'user-only. Ids in either list were NOT placed, so say so plainly '
        'instead of reporting them as added. Use the exact ids from '
        'list_app_commands; guessing a spelling such as "cloudSync" just '
        'comes back as ignored. '
        'This tool can only fill the HEADER; it '
        'cannot move buttons to the bottom bar. If the user wants them at the '
        'bottom, tell them to do it in the button-customize screen.',
        {
          'ids': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'replace': {'type': 'boolean'},
        },
        ['ids']),
    _tool(
        'create_page',
        'Create a new page. type: "normal" (mind map), "bookshelf" (gallery), '
        '"paint" (free note), "document" (notepad - write prose with '
        'append_document_text), "markdown" (markdown + mermaid - write the '
        'body with write_markdown right after creating it, otherwise the '
        'user just gets an empty page)' +
        (kStoreBuild ? '. ' : ', "videoEditor" (video timeline). ') +
        '"automation" (自動操作 - a page that holds PC/Web automation '
        'steps; desktop + Pro only, and its steps are read with '
        'read_automation_page, not read_page). '
        'Returns {pageId, type, name, folderId, folderName}: "type" is what '
        'was really created (an unknown type falls back to "normal", so check '
        'it before telling the user what you made), and "folderId" is where '
        'it actually went. '
        'By default the page goes into the folder the user currently has '
        'open; if none is open the app picks one. A new page is NEVER '
        'created outside every folder - pages sitting outside folders are '
        'only old data kept for compatibility. Pass "folderId" (from '
        'list_folders) to choose the folder.',
        {
          'type': {
            'type': 'string',
            'enum': [
              'normal',
              'bookshelf',
              'paint',
              'document',
              'markdown',
              'automation',
              if (!kStoreBuild) 'videoEditor'
            ]
          },
          'name': {'type': 'string'},
          'folderId': {'type': 'string'},
        },
        ['type']),
    _tool(
        'add_node',
        'Add node(s) to a mind-map page. PREFER the batch form: pass "nodes" '
        'as an array of {title, memo?, url?, color?, parentIndex?, parentId?} '
        'and every node is created in ONE call. "parentIndex" is the 0-based '
        'index of an earlier node in the same array and also draws the '
        'connection, so a whole map (centre + children) is one call. '
        'An entry may also be a bare title string. '
        'Nodes created without x/y are laid out clear of each other and of '
        'what is already on the page; call tidy_page only when you want the '
        'WHOLE page rearranged. '
        'Nodes only SHOW on a "normal" mind-map page: on a "document" / '
        '"markdown" / "videoEditor" page they are saved to that page\'s '
        'hidden map layer and the reply carries a "pageTypeNote" saying so - '
        'use append_document_text / write_markdown / add_video_editor_item to '
        'put something on those screens instead. '
        'Returns nodeIds in the same order, plus '
        '"asked" / "created" and a "failed" list giving the input index and '
        'reason for every entry that made no node - report those numbers, not '
        'the number you asked for. '
        'ALWAYS put links in "url", never as bare text inside "memo": a node '
        'with "url" becomes a real clickable link, and a YouTube WATCH url '
        '(https://www.youtube.com/watch?v=VIDEOID or https://youtu.be/VIDEOID) '
        'becomes an embedded video node with a thumbnail that plays in the '
        'app. Search urls (/results?search_query=...) are NOT videos, so give '
        'the actual watch url when you know the video. "memo" and "url" can '
        'be used together on the same node. A url the app cannot open '
        '(javascript:, data:, file:, plain text) is never made clickable: an '
        'entry whose ONLY content was such a url creates NO node (it comes '
        'back in "failed", or as an error for a single add), and on an entry '
        'that also has a title / memo the address is kept as plain TEXT and '
        'listed in "ignored" - report that, never as a working link. '
        '"title" is a SHORT LABEL, not a body: a new node is 160x40 px and '
        'draws its title on about two lines, ellipsising the rest, so put '
        'anything longer than a short phrase in "memo" - the node grows to '
        'fit a long memo, but never to fit a long title. A "\\n" inside '
        '"title" is kept and really does become a second line. '
        '"color" is a 32-bit ARGB integer 0xAARRGGBB (e.g. 0xFF4CAF50 for '
        'green); a 6-digit RGB value like 0xFF0000 is treated as opaque, and '
        'a value outside 0..0xFFFFFFFF is ignored so the default colour is '
        'used. Calling this with an empty "nodes" array, or with no title / '
        'memo / url at all, is an error - it never creates a placeholder. '
        '"parentId" may be an existing node\'s id OR its EXACT title - a '
        'partial match is refused rather than guessed, so a typo never '
        'attaches the child to some other node, and a title carried by TWO '
        'OR MORE nodes is refused with the candidate ids instead of picking '
        'the first one. Every child that WAS linked comes back in "linked" '
        'as {index, nodeId, parentId} - report that id, not the title you '
        'passed. Any '
        'entry whose parent could not be linked comes back in "unlinked" as '
        '{index, nodeId, title, parent, reason} - link those with '
        'connect_nodes and never report them as connected.',
        {
          'pageId': {'type': 'string'},
          'nodes': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'title': {'type': 'string'},
                'memo': {'type': 'string'},
                'url': {'type': 'string'},
                'color': {'type': 'integer'},
                'x': {'type': 'number'},
                'y': {'type': 'number'},
                'parentIndex': {'type': 'integer'},
                'parentId': {'type': 'string'},
              },
            },
          },
          'title': {'type': 'string'},
          'x': {'type': 'number'},
          'y': {'type': 'number'},
          'memo': {'type': 'string'},
          'url': {'type': 'string'},
          'color': {'type': 'integer'},
        },
        ['pageId']),
    _tool(
        'update_node',
        'Update a node title / memo / position. "node" accepts EITHER the '
        'node id OR its current TITLE (e.g. {"node":"春","title":"春（はる）"}) '
        '- using the title means you do not have to look up ids. A title '
          'carried by TWO OR MORE nodes on the page is REFUSED with the '
          'candidate ids instead of resolving to the first one, so pass the '
          '"id" when titles repeat. '
        '("nodeId" is accepted as an alias.) "title" is a short label: long '
        'text is ellipsised to about two lines on the canvas, so put long '
        'text in "memo". A blank / whitespace-only title is accepted, but the '
        'node can then only be addressed by its id. x/y may be negative. '
        'This tool CAN also recolour a node and give it a link after it was '
        'placed: "color" takes 32-bit ARGB (a 6-digit RGB value is made '
        'opaque; a value outside 0..0xFFFFFFFF is refused and comes back '
        'under "ignored" with its reason, so the colour is left as it was - '
        'that is NOT the same as the colour already matching), "url" makes '
        'the node a '
        'clickable link - a YouTube watch url becomes an embedded video node '
        'instead - and "clearUrl":true removes an existing link/video. '
        'Setting one kind of url clears the other, so a node is never both a '
        'link and a video. A url the app cannot open (javascript:, data:, '
        'file:, plain text) is REFUSED here and the existing link is kept; '
        'the reply lists it under "ignored". On a gallery (bookshelf) page x/y '
        'are refused too - tiles sit on a fixed grid (use tidy_page). '
        'Whitespace-only "memo" is stored as an empty memo. '
        'The result echoes back what was actually applied ("changed" + '
        '"applied"); report that, not what you asked for. When every value '
        'already matched the node the reply is updated:false / '
        'unchanged:true and no undo step is used.',
        {
          'pageId': {'type': 'string'},
          'node': {'type': 'string'},
          'nodeId': {'type': 'string'},
          'title': {'type': 'string'},
          'memo': {'type': 'string'},
          'x': {'type': 'number'},
          'y': {'type': 'number'},
          'color': {'type': 'integer'},
          'url': {'type': 'string'},
          'clearUrl': {'type': 'boolean'},
        },
        ['pageId']),
    // ─── 既にある物を直す (= 動作検証レポート: 画面では直せるのに MCP には
    //     追加と削除しか無く、 AI に頼むと作り直しになる) ─────────────────
    _tool(
        'update_decoration',
        'Change a shape that is ALREADY on the page - its kind, colour, line '
        'thickness, label, fill or layer. "color" is RGB and the alpha byte '
        'is ignored, the same as add_decoration (node colours are ARGB). '
        'Get the id from read_page '
        '("decorations"), or from what add_decoration returned. Only the '
        'fields you pass change; everything else stays. When every value you '
        'pass already matches the shape - or you pass no value at all - the '
        'reply is updated:false / unchanged:true: nothing is written and no '
        'undo step is used (the line width is rounded into 0.5-40 first, so '
        '-1 and 0 both mean 0.5). This does NOT move or '
        'resize the shape (dragging is the user\'s job) - to reposition one, '
        'delete it and add it again with new coordinates. Use this instead of '
        'deleting and re-adding just to recolour something.',
        {
          'pageId': {'type': 'string'},
          'decorationId': {'type': 'string'},
          'kind': {'type': 'string'},
          'color': {'type': 'integer'},
          'strokeWidth': {'type': 'number'},
          'text': {'type': 'string'},
          'filled': {'type': 'boolean'},
          'layer': {'type': 'integer'},
        },
        ['pageId', 'decorationId']),
    _tool(
        'update_video_editor_item',
        'Change or remove ONE item already on a video timeline - its lane '
        '(layer), start time, length, caption text, text size or colour. Get '
        'itemId from list_video_editor_items, which reads those same values '
        'back. Only the fields you pass change. Set '
        '"remove": true to delete the item instead - the update fields are '
        'then ignored, so a leftover value cannot make the delete fail. Times '
        'are whole milliseconds (1.5 seconds = 1500) and startMs + durationMs '
        'must stay inside 24 hours. Blank / whitespace-only "text" is refused '
        '(it would leave an invisible caption holding a slot) - use '
        'remove:true to get rid of one. The reply echoes every value that is '
        'now stored. This is the only way to fix a '
        'caption you placed at the wrong moment - do not add a second one on '
        'top of it.',
        {
          'pageId': {'type': 'string'},
          'itemId': {'type': 'string'},
          'layer': {'type': 'integer'},
          'startMs': {'type': 'integer'},
          'durationMs': {'type': 'integer'},
          'text': {'type': 'string'},
          'fontSize': {'type': 'number'},
          'color': {'type': 'integer'},
          'remove': {'type': 'boolean'},
        },
        ['pageId', 'itemId']),
    _tool(
        'list_orphan_files',
        'List files this app created that no tile uses any more - the '
        'leftovers from deleting a tile without its file. Read-only: it '
        'changes nothing. Show the list to the user and ask before removing '
        'anything; files the app did not create are never listed, so this is '
        'not a full audit of their folder.',
        {}),
    _tool(
        'delete_node',
        'Delete a node (and its connections) from a page. "node" accepts '
        'EITHER the node id OR its EXACT title (case and spacing are ignored, '
        'but an approximate title is REJECTED, never guessed). To remove '
        'several at once pass "nodes" (array of ids or titles) in ONE call. '
        'One entry deletes ONE node. A title carried by TWO OR MORE nodes is '
        'REFUSED with the candidate ids - it is NEVER resolved to the first '
        'one - so when several nodes share a title call read_page and pass '
        'every matching "id" as its own entry. The result lists the '
        'TITLES actually removed - report those, not what you meant to '
        'remove. When the user names a partial match ("the nodes with TEST in '
        'the title"), read_page first, list the exact titles you matched, and '
        'get an OK before deleting - a partial match usually catches nodes '
        'they did not mean. '
        '"deleteFile" decides what happens to the FILE on disk behind an '
        'attachment tile: "no" (the default) removes only the tile; '
        '"generated" also sends the file to the recycle bin, but ONLY when '
        'this app created it; "yes" recycles it even if the user brought the '
        'file themselves - ASK THEM FIRST. A file another tile still uses is '
        'never touched and nothing is ever deleted permanently. The reply '
        'carries "fileRecycled" or "fileKept" with a reason - report that, do '
        'not claim the file is gone. When a file was recycled the reply also '
        'carries "undoRestoresFile": true means undo_page (or the user '
        'pressing Ctrl+Z) puts the FILE back together with the tile; false '
        'means undo would bring back a tile that cannot open, so say so '
        'before undoing and tell the user the file has to come back from the '
        'recycle bin. Use list_orphan_files to find leftovers from earlier '
        'tile-only deletions. '
        'AFTER THE DELETE THE GAP IS CLOSED: by default the siblings that are '
        'left move up into the space the deleted node held, exactly like '
        'deleting from the screen (nothing moves when the node was not '
        'connected to anything). Pass "compact": false to leave every other '
        'node where it is.',
        {
          'pageId': {'type': 'string'},
          'node': {'type': 'string'},
          'nodeId': {'type': 'string'},
          'nodes': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'deleteFile': {
            'type': 'string',
            'enum': ['no', 'generated', 'yes'],
          },
          // ★ = 継続検証 257。 既定の後始末をはっきり書いておく。
          'compact': {
            'type': 'boolean',
            'description':
                'Default true: the remaining siblings are pulled up to close '
                'the gap the deleted node leaves, the same way the app does '
                'it when the user deletes from the screen. Pass false to '
                'leave every other node exactly where it is.',
          },
        },
        ['pageId']),
    // ★ 並べ直しはアプリ側にあったのに道具として出していなかったため、
    //   「マップがぐちゃぐちゃ」 と頼まれても断るしかなかった (= 動作確認)。
    _tool(
        'tidy_page',
        'Re-arrange a mind map page into a tidy tree - the same automatic '
        'layout the app applies after AI edits. Use it when the user says the '
        'map is messy / overlapping / wants it lined up. Nodes keep their '
        'titles and connections; only positions change, and the user can put '
        'it back with Ctrl+Z. Also works on a "bookshelf" (gallery) page: '
        'scattered tiles are packed into the grid from the top-left, keeping '
        'their visual order, and their tiles are squared to the one gallery '
        'size — use it when gallery items are strewn about. '
        'Other page types arrange themselves. If nothing needs moving the '
        'reply is tidied:false / unchanged:true - nothing is saved and no undo '
        'step is used, so there is no point calling it twice to make sure.',
        {
          'pageId': {'type': 'string'},
        },
        ['pageId']),
    _tool(
        'generate_page_background',
        'Draw a NEW background image with AI and set it as the page '
        'background. On a FREE NOTE / notepad page ("paint" / "document") the '
        'picture is NOT a fixed background: it is placed on the CURRENT SHEET '
        'as a normal image element on the back-most layer, sized to the paper, '
        'so the user can later select, move, resize or delete it with the '
        'select tool. '
        // ★ 絵そのものを頼まれた時は generate_image を使う (= ユーザー要望:
        //   場所を言わずに「〜の絵を描いて」 と頼んだら、 開いている
        //   ページの上に置く)。 この道具は「背景」 の時だけ。
        'EVEN ON A FREE NOTE, prefer generate_image when the user simply '
        'says "draw me a picture" - use THIS tool only when they actually '
        'said background / wallpaper / 背景 / 壁紙. '
        'This is the preferred way to change a background: '
        'describe the picture you want in "prompt" (English works best, be '
        'concrete about subject, colours and mood) and an image is generated '
        'and applied. When the setting says to draw, it costs a flat ~0.047 '
        'USD of prepaid credit per picture (fetching from the web is free), '
        'whatever the prompt length - one charge PER PAGE, so "give every '
        'page the same background" costs that much times the number of '
        'pages. Because it costs money, do '
        'not run it on a vague request ("make the background nice"): settle '
        'which page, what kind of picture, and whether a built-in template '
        '(free, via set_page_background) would do, then generate. '
        'Optionally set opacityPercent (0-100, default 70) and '
        'fit (cover/contain/tile, default cover). '
        'SET "placeOnSheet": true ONLY when the user asked for a BACKGROUND '
        'on an open free note but wants it in front of what is already '
        'drawn. For a plain "draw me a picture" ("このノートに猫を描いて" / '
        '"draw a cat here") use generate_image instead - it places the '
        'picture on the same sheet, and that is the tool for pictures. '
        'The picture is then placed on the sheet at a normal size IN FRONT '
        'of what is already drawn, instead of covering the whole paper from '
        'behind - which is what someone asking for a drawing expects. '
        'Leave it out for an actual BACKGROUND. It is ignored on mind map, '
        'gallery and other page types. '
        'WHICH PAGE: unless the user named another one, this means the page '
        'they are looking at RIGHT NOW - the one list_pages marks '
        'isCurrent:true - NOT a page you happened to create earlier in this '
        'conversation. Leave pageId out and the current page is used. '
        'Markdown and video-editor pages have no background at all; asking '
        'for one there is refused - ask the user which page they meant '
        'instead of picking one yourself. Say which page you changed. '
        'ALWAYS tell the user where the picture came from: the result carries '
        '"imageSource" (and "imageSourceUrl" when it was fetched from the '
        'web) - the app either draws it with AI or fetches it from an image '
        'search, depending on the user setting. Put that in your reply, e.g. '
        '"AI が描き起こしました" or "Wikimedia Commons から取得しました <url>". '
        'Never claim it was drawn if it was fetched, or the other way round.',
        {
          'pageId': {'type': 'string'},
          'prompt': {'type': 'string'},
          'opacityPercent': {'type': 'integer'},
          'fit': {
            'type': 'string',
            'enum': ['cover', 'contain', 'tile']
          },
          // ★ フリーノートの紙の**上**に普通の大きさで置く。
          'placeOnSheet': {'type': 'boolean'},
        },
        // pageId は省ける (= 省いたら「今開いているページ」)。
        ['prompt']),
    // ★ 絵を描いて「ページの上」 に置く (= ユーザー要望:「〜の絵を描いて」
    //   「画像を生成して」 と置き場所を言わずに頼んだら、 今開いている
    //   ページに配置してほしい)。 これまでは絵を作れる道具が背景用の
    //   generate_page_background しか無く、 add_image_node は画像そのものを
    //   渡さないと必ず断られていた (文章のモデルは絵を作れない)。
    _tool(
        'generate_image',
        'Draw a NEW picture with AI and PLACE IT ON A PAGE as a normal '
        'element the user can move, resize or delete. '
        'THIS IS THE TOOL FOR "draw me a picture of X" / "generate an '
        'image" ("〜の絵を描いて" / "画像を生成して"). Do NOT use '
        'generate_page_background for that: a background is the WALLPAPER '
        'behind the page, which is not what someone asking for a picture '
        'wants. Use generate_page_background only when the user actually '
        'says background / wallpaper / 背景 / 壁紙. '
        'WHICH PAGE: leave "pageId" out and the picture goes onto the page '
        'the user is looking at RIGHT NOW (the one list_pages marks '
        'isCurrent:true). That is the default whenever the user did not name '
        'a destination - do NOT create a new page for the picture and do NOT '
        'reuse a page you happened to make earlier in this conversation. '
        'The picture is placed the way that page type holds pictures: an '
        'image node on a mind map, a tile on a gallery (bookshelf), an image '
        'element on the sheet of a free note / notepad (paint / document), an '
        'image line appended to the body of a markdown page, and an image '
        'clip on a video-editor timeline. The result says which in '
        '"placedOn" - report the PAGE NAME, not the id. '
        'Describe the picture in "prompt" (English works best: be concrete '
        'about subject, colours and mood). Optional "title" names the '
        'element. Do not pass x/y unless the user asked for a position. '
        'It costs a flat ~0.047 USD of prepaid credit per picture when the '
        'setting says to draw (fetching from the web is free), so draw ONE '
        'picture per request unless the user asked for several. '
        'ALWAYS tell the user where the picture came from: the result carries '
        '"imageSource" (and "imageSourceUrl" when it was fetched from the '
        'web). Never claim it was drawn if it was fetched, or the other way '
        'round.',
        {
          'pageId': {'type': 'string'},
          'prompt': {'type': 'string'},
          'title': {'type': 'string'},
          'x': {'type': 'number'},
          'y': {'type': 'number'},
        },
        // ★ pageId は省ける (= 省いたら「今開いているページ」)。
        ['prompt']),
    _tool(
        'set_page_background',
        'Set the page background from an existing picture, or remove it. '
        '"Remove / get rid of / I do not like this background" means '
        '"clear": true - run it straight away, do not ask again and do not '
        'generate a replacement (disliking a background is not a request for '
        'a new one). Prefer generate_page_background only when the user '
        'describes a look they DO want. Use "imagePath" for an absolute path '
        'to an image file already on this device, "clear": true to remove, '
        'or "template" for one of the built-in ones (blueprint, appWallpaper, '
        'starryLake, fireworks, gems, ocean, autumn, castle, watercolor, '
        'greenery, sumie). '
        'Optionally adjust opacityPercent (0-100), fit (cover/contain/tile) '
        'and the tone (hueDegrees -180..180, saturationPercent 0-200, '
        'brightnessPercent 50-150). A value outside its range is clamped, not '
        'rejected - the result echoes back what was actually applied, so '
        'report those numbers rather than the ones you asked for. '
        'WHICH PAGE: unless the user named another one, this means the page '
        'they are looking at RIGHT NOW - the one list_pages marks '
        'isCurrent:true - NOT a page you happened to create earlier in this '
        'conversation. Leave pageId out and the current page is used. '
        'Markdown and video-editor pages have no background at all; asking '
        'for one there is refused - ask the user which page they meant '
        'instead of picking one yourself. The result carries pageName: say '
        'which page you changed.',
        {
          'pageId': {'type': 'string'},
          'template': {'type': 'string'},
          'imagePath': {'type': 'string'},
          'clear': {'type': 'boolean'},
          'opacityPercent': {'type': 'integer'},
          'fit': {
            'type': 'string',
            'enum': ['cover', 'contain', 'tile']
          },
          'hueDegrees': {'type': 'integer'},
          'saturationPercent': {'type': 'integer'},
          'brightnessPercent': {'type': 'integer'},
        },
        // pageId は省ける (= 省いたら「今開いているページ」)。
        const []),
    _tool(
        'connect_nodes',
        'Connect nodes with arrow lines. PREFER the batch form: pass '
        '"connections" as an array of {from, to, label?} to make every '
        'link in ONE call. '
        'IMPORTANT: "from"/"to" accept EITHER the node id OR the node '
        'TITLE exactly as shown on the map (e.g. {"from":"春","to":"夏",'
        '"label":"次の季節へ"}). Using titles is recommended - you do not '
        'need to look up ids. ("fromId"/"toId" are accepted as aliases.) '
        'Connecting the same pair twice just updates the label; naming the '
        'SAME pair in the opposite order flips the stored arrow direction '
        'and the result echoes the direction that was actually saved. To take '
        'a label off an existing line, pass clearLabel:true (an empty "label" '
        'string means "not given", so it cannot clear one). Passing the label '
        'it already has reports "unchanged" and uses no undo step. MATCHING IS EXACT: a partial title is refused as node_not_found and the near titles come back in "candidates" (a typo must never draw the line between the wrong nodes), and when two nodes on a page share the same title the pair is refused too instead of guessing. So when titles repeat, or the user names a node by position ("the lower one"), call read_page first and pass the node id - read_page gives x/y, and a larger y is lower on the canvas. The result echoes fromId/toId: check them.',
        {
          'pageId': {'type': 'string'},
          'connections': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'from': {'type': 'string'},
                'to': {'type': 'string'},
                'fromId': {'type': 'string'},
                'toId': {'type': 'string'},
                'label': {'type': 'string'},
                'clearLabel': {'type': 'boolean'},
              },
            },
          },
          'from': {'type': 'string'},
          'to': {'type': 'string'},
          'fromId': {'type': 'string'},
          'toId': {'type': 'string'},
          'label': {'type': 'string'},
          'clearLabel': {'type': 'boolean'},
        },
        ['pageId']),
    _tool(
        'add_image_node',
        'Add ONE image node to a page. Provide the image either as base64 '
        '(imageBase64 + fileName like "chart.png") or as an absolute local '
        'file path (imagePath). Returns nodeId. '
        'This is the ONE tool with no batch form: for several images call it '
        'once per image. An array in "imagePath" / "imageBase64" is rejected '
        'outright, and an invented key such as "images" is ignored entirely - '
        'either way nothing is attached, so never bundle images into one '
        'call. The path is also checked before anything is created: a '
        'missing file, a non-image extension or a file that cannot be '
        'decoded comes back as an error and no node is made. '
        'NO PICTURE YET? Then pass "prompt" (an English description) instead '
        'of imagePath / imageBase64: the picture is drawn with AI and placed '
        'on the page, exactly like generate_image - which is the tool to '
        'prefer when the user says "draw me a picture". '
        'WHICH PAGE: leave "pageId" out and the node goes onto the page the '
        'user is looking at right now.',
        {
          'pageId': {'type': 'string'},
          'imageBase64': {'type': 'string'},
          'fileName': {'type': 'string'},
          'imagePath': {'type': 'string'},
          // ★ 絵がまだ無い時は、 ここに描く指示を書けば AI が描いて置く
          //   (= ユーザー要望: 場所を言わずに「絵を描いて」 と頼まれた時)。
          'prompt': {'type': 'string'},
          'title': {'type': 'string'},
          'x': {'type': 'number'},
          'y': {'type': 'number'},
        },
        // ★ pageId は省ける (= 省いたら「今開いているページ」)。
        const []),
    _tool(
        'add_table_node',
        'Add a table (grid) node to a page. Use this to present researched '
        'facts, comparisons or figures as a table. "rows" is an array of '
        'arrays of strings; the first row is treated as the header by '
        'default - pass headerRow:false for a table with no header. Optional '
        '"title" is written as a caption line above the table, not as the '
        'node title. Returns nodeId.',
        {
          'pageId': {'type': 'string'},
          'rows': {
            'type': 'array',
            'items': {
              'type': 'array',
              'items': {'type': 'string'}
            },
          },
          'headerRow': {'type': 'boolean'},
          'title': {'type': 'string'},
          'x': {'type': 'number'},
          'y': {'type': 'number'},
        },
        ['pageId', 'rows']),
    // ─── マインドマップ以外のページ (= ユーザー要望) ───────────────────
    _tool(
        'add_gallery_item',
        'Add tiles to a GALLERY page (pageType "bookshelf"). Use this '
        'instead of add_node for gallery pages: tiles are placed into the '
        'shelf grid automatically, so do not pass coordinates. '
        'IMPORTANT: to add several tiles, pass them ALL AT ONCE in "texts" '
        'in a SINGLE call - do not call this tool once per tile. Each entry '
        'of "texts" may be a plain title string OR an object '
        '{text, memo?, url?}, so a whole list of links becomes tiles in one '
        'go. Use "text" + "memo" for a single tile with a body, or '
        '"imagePath" (absolute local path) for a picture tile - a picture '
        'tile KEEPS its memo, so the description / source / review note '
        'lives on the same tile and is found by search_pages. '
        'Pass "url" to make a CLICKABLE tile: a YouTube watch / youtu.be / '
        'shorts url becomes a video tile with a thumbnail, any other '
        'http(s) url becomes a link tile (search and channel urls are link '
        'tiles, not videos). Only http and https are accepted - anything '
        'else is kept as plain text and the reply says so under '
        '"requestedUrl" / "storedAs". You no longer need to create a text '
        'tile and then call update_node.',
        {
          'pageId': {'type': 'string'},
          'texts': {
            'type': 'array',
            'items': {
              'anyOf': [
                {'type': 'string'},
                {
                  'type': 'object',
                  'properties': {
                    'text': {'type': 'string'},
                    'memo': {'type': 'string'},
                    'url': {'type': 'string'},
                  },
                },
              ],
            },
          },
          'text': {'type': 'string'},
          'memo': {'type': 'string'},
          'url': {'type': 'string'},
          'imagePath': {'type': 'string'},
        },
        ['pageId']),
    _tool(
        'add_paint_text',
        'Write text onto a FREE NOTE page (pageType "paint"). '
        'Text is placed on the currently selected sheet; if x/y are omitted '
        'lines are stacked top-to-bottom automatically. size is the font '
        'size in points, color is ARGB int (e.g. 0xFF000000). '
        'IMPORTANT: to write several lines, pass them ALL AT ONCE in '
        '"texts" (array of strings) in a SINGLE call - one string per '
        'paragraph, and put the WHOLE document in one call so the layout is '
        'computed in one go. When x/y are omitted the layout is done for you: '
        'each string is wrapped to the width of the paper, advanced by its '
        'real number of lines, and started BELOW whatever is already on the '
        'sheet - so it never overlaps. When the sheet is full the rest '
        'continues on the next tab (a new tab named "<tab> (2)" is added if '
        'needed); the tabs used come back in "sheets". '
        'Do NOT write a rough version first and tidy it up afterwards, and do '
        'NOT make a scratch / draft tab: the user sees every write '
        'immediately. Blank or whitespace-only strings are discarded - empty '
        'lines cannot be written with this tool (use a paragraph per string '
        'instead). Because the text is wrapped to the paper, what '
        'read_paint_items gives back may contain extra line breaks - that is '
        'not a mistake, do not rewrite it. '
        'RANGES: x / y / size are CLAMPED into the sheet instead of being '
        'rejected - x to 0..(paperWidth-120), y to 0..(paperHeight-lineHeight) '
        'and size to 6..200 points (an A4 portrait sheet is 794x1123). The '
        'reply always tells you where the text really landed ("x", "y", '
        '"size"); when a value had to be moved you also get "requestedX" / '
        '"requestedY" / "requestedSize" and "clamped": true - tell the user '
        'those real numbers, never the ones you asked for. Also note the line '
        'is wrapped to (paperWidth - x - 56), so a large x together with a '
        'large size leaves room for only a character or two per line.',
        {
          'pageId': {'type': 'string'},
          'texts': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'text': {'type': 'string'},
          'x': {'type': 'number'},
          'y': {'type': 'number'},
          'size': {'type': 'number'},
          'color': {'type': 'integer'},
        },
        ['pageId']),
    // ── フリーノートの入れ物 (バインダー / タブ) を扱う
    //    (= ユーザー要望: ノートの切り替えやタブの追加を AI からも) ──
    _tool(
        'list_paint_tabs',
        'List the structure of a FREE NOTE page (pageType "paint"). A free '
        'note holds BINDERS (バインダー), and each binder holds TABS (タブ) - '
        'a tab is one sheet of paper. Everything you write with '
        'add_paint_text goes onto the tab that is SELECTED right now, so '
        'call this first whenever the user talks about a particular tab or '
        'binder. Returns {binderSel, binders:[{index, name, selected, '
        'tabs:[{index, name, selected, items}]}]} where "items" is how many '
        'things are drawn on that tab.',
        {
          'pageId': {'type': 'string'},
        },
        ['pageId']),
    _tool(
        'add_paint_tabs',
        'Add one or more TABS (sheets of paper) to a FREE NOTE page. Pass '
        'ALL the names at once in "names" - do not call this once per tab. '
        'Leave "binder" out to add them to the binder that is open now. '
        'Returns the indexes of the tabs that were added.',
        {
          'pageId': {'type': 'string'},
          'names': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'binder': {
            'type': 'integer',
            'description': 'Binder index from list_paint_tabs. Omit for the '
                'binder that is currently open.',
          },
        },
        ['pageId', 'names']),
    _tool(
        'add_paint_binders',
        'Add one or more BINDERS to a FREE NOTE page. A binder is the '
        'container that holds tabs; each new binder starts with one empty '
        'tab. Pass ALL the names at once in "names". Returns the indexes of '
        'the binders that were added.',
        {
          'pageId': {'type': 'string'},
          'names': {
            'type': 'array',
            'items': {'type': 'string'},
          },
        },
        ['pageId', 'names']),
    _tool(
        'select_paint_tab',
        'Switch which BINDER and/or TAB of a FREE NOTE page is shown - and '
        'therefore which tab add_paint_text writes on. Indexes come from '
        'list_paint_tabs. Give "binder", "tab", or both. If the page is open '
        'on screen the view changes immediately; otherwise it opens there '
        'next time.',
        {
          'pageId': {'type': 'string'},
          'binder': {'type': 'integer'},
          'tab': {'type': 'integer'},
        },
        ['pageId']),
    _tool(
        'rename_paint_item',
        'Rename a BINDER or a TAB of a FREE NOTE page. Give "binder" alone '
        'to rename that binder; give "tab" as well to rename a tab inside '
        'it. Indexes come from list_paint_tabs.',
        {
          'pageId': {'type': 'string'},
          'binder': {'type': 'integer'},
          'tab': {'type': 'integer'},
          'name': {'type': 'string'},
        },
        ['pageId', 'name']),
    _tool(
        'delete_paint_item',
        'Delete a TAB (one sheet of paper) or a whole BINDER of a FREE NOTE '
        'page. Give "binder" and "tab" to delete that tab; give "binder" '
        'alone to delete the binder with everything in it. Indexes come from '
        'list_paint_tabs (call it again right before deleting - indexes shift '
        'when tabs are added or removed). The last remaining tab of a binder, '
        'and the last remaining binder, cannot be deleted. Everything drawn '
        'on that tab is lost and there is no undo, so only delete a tab the '
        'user asked you to remove, or a working tab YOU made yourself during '
        'this task - tidy those up before you report back, never leave a '
        'half-finished sheet behind. Returns the name of what was deleted.',
        {
          'pageId': {'type': 'string'},
          'binder': {'type': 'integer'},
          'tab': {'type': 'integer'},
        },
        ['pageId']),
    _tool(
        'write_markdown',
        'Write the body of a MARKDOWN page (pageType "markdown"). This is '
        'how you fill in a page made with create_page type:"markdown" - '
        'append_document_text does NOT work on markdown pages. Pass the '
        'WHOLE document in "text" in a SINGLE call (headings, lists, tables, '
        'code fences and ```mermaid diagrams all render). PUT REAL LINE '
        'BREAKS IN "text" - a plain newline inside the JSON string is exactly '
        'right. Do NOT write the two characters backslash + n in place of a '
        'line break: markdown only sees a heading, a list item, a table row '
        'or a code fence at the START of a real line, so an escaped body '
        'lands as one long paragraph with "\\n" printed all through it. '
        'By default the '
        'text REPLACES the body; pass "append":true to add to the end of '
        'what is already there. Writing switches the current MAP to this '
        'page, but a FILE that is open on top of the map stays on top - so '
        'the user may not see it yet. Check foregroundContext in list_pages '
        'before you report that the page is on screen. '
        'A markdown page holds several TABS, and a long document should be '
        'laid out over several of them: start each part with a line '
        '"<<<PAGE: tab name>>>" and everything after that line becomes that '
        'tab (the first part goes into the tab that is open now, the rest '
        'are added after it). Text you write BEFORE the first marker line is '
        'kept as well: it becomes the first part and lands in the tab that is '
        'open now. Make the first part the overview / table of '
        'contents and link to the others with "[tab name](tab:tab name)". '
        'Even without those marker lines a long document is split at its '
        'headings on its own; pass "split":"single" to force one single tab, '
        'or "split":"tabs" to split a short one too. "append" never splits. '
        'A "<<<PAGE: …>>>" line inside a ```code fence``` is left as text and '
        'does NOT start a tab. '
        '"split":"single" writes into the tab that is open now and LEAVES any '
        'other tabs on the page alone: the reply gives "tabs" (the page total '
        'afterwards), "wroteTabs" (what this call wrote) and '
        '"otherTabsKept" - report those, not "the page is one tab now". Use '
        '"split":"tabs" with the whole document, or "clear":true first, to '
        'end up with only the new tabs. "clear":true TOGETHER WITH text '
        'throws away every existing tab first and then writes the new body, '
        'so the page ends up holding only what this call wrote. '
        '"clear":true with empty text makes '
        'the page deliberately empty (and stops the app from seeding its '
        'getting-started sample). NEITHER form of "clear" works while a WEB '
        'tab is the one open on the page: a web tab holds no body, so the '
        'call is refused and nothing is written or cleared - report that and '
        'ask the user to switch to a text tab first.',
        {
          'pageId': {'type': 'string'},
          'text': {'type': 'string'},
          'append': {'type': 'boolean'},
          'clear': {'type': 'boolean'},
          'split': {
            'type': 'string',
            'enum': ['auto', 'tabs', 'single'],
          },
        },
        ['pageId', 'text']),
    _tool(
        'append_document_text',
        'Append text to the end of a free note used as a notepad '
        '(pageType "paint", or an existing "document" page). '
        'Plain text only (no markup). '
        'ON A FREE NOTE ("paint") the text goes into the document layer of '
        'the tab that is OPEN RIGHT NOW - each tab keeps its own text. Call '
        'list_paint_tabs / select_paint_tab first to choose the binder / tab, '
        'and read_document to read EVERY binder and EVERY tab back. The reply '
        'says which binder / tab it landed in. '
        'IMPORTANT: to write several paragraphs, pass them ALL AT ONCE in '
        '"texts" (array of strings) in a SINGLE call. Blank or whitespace-only '
        'strings are discarded - empty lines cannot be written with this '
        'tool.',
        {
          'pageId': {'type': 'string'},
          'texts': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'text': {'type': 'string'},
        },
        ['pageId']),
    // ★ ストア提出版では道具ごと出さない (アプリ内 AI チャットも
    //   この toolDefs を共用している)。
    if (!kStoreBuild)
      _tool(
          'add_video_editor_item',
        'Add items to the timeline of a VIDEO EDITOR page (pageType '
        '"videoEditor"). kind: "text" (caption; requires text), "video" or '
        '"image" (requires an absolute local path). startMs and durationMs '
        'are whole MILLISECONDS (1.5 seconds = 1500, not 1.5). startMs '
        'defaults to the end of that layer; with "texts" it is the start of '
        'the FIRST caption and the rest follow one after another, each one '
        '"durationMs" later (it is NOT ignored). durationMs defaults to 4000, '
        'and startMs + durationMs must stay inside 24 hours (86400000 ms) - '
        'the same limit update_video_editor_item enforces. fontSize is '
        'clamped to 6 - 200 (the range this editor can draw) and the reply '
        'tells you the size that was actually stored. layer 0 is the '
        'back-most and the timeline has only 6 lanes (0-5); captions usually '
        'go on layer 1. '
        'IMPORTANT: to add several captions, pass them ALL AT ONCE in '
        '"texts" (array of strings) in a SINGLE call - do not call this '
        'tool once per caption. Returns itemId(s). '
        'To CHANGE or DELETE something already on the timeline use '
        'update_video_editor_item (it can move, re-layer, re-time, re-word '
        'and delete) - never add a second copy on another layer and call it '
        'moved. read_page cannot show the timeline (it lives outside the page '
        'JSON); use list_video_editor_items to see what is there.',
        {
          'pageId': {'type': 'string'},
          'texts': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'kind': {'type': 'string', 'enum': ['text', 'video', 'image']},
          'text': {'type': 'string'},
          'path': {'type': 'string'},
          'startMs': {'type': 'integer'},
          'durationMs': {'type': 'integer'},
          'layer': {'type': 'integer'},
          'fontSize': {'type': 'number'},
          'color': {'type': 'integer'},
        },
        ['pageId']),
    // ─── アプリの機能ボタン (= ユーザー要望: フラッシュカードや無音カメラ
    //     のようなカスタムボタン機能も操れるように) ───────────────────
    // ─── 文書ファイルの作成 (= ユーザー要望) ─────────────────────────
    _tool(
        'create_document_file',
        'Create a real document FILE (Excel, CSV, Word, PowerPoint, PDF or '
        'plain text) with the given content, save it, and attach it to a '
        'page so the user can open it in the built-in viewer. '
        'THIS IS ALSO HOW YOU EDIT A FILE YOU ALREADY MADE: calling it '
        'again with a "fileName" you used before REWRITES that same file IN '
        'PLACE and reuses its existing tile - no second file and no second '
        'tile are created. So when the user says "make '
        'the file you just made 100 lines" or "fix that file", call this '
        'tool AGAIN with the SAME pageId and the SAME fileName. Never '
        'invent a new name to avoid touching the old file, and never leave '
        'the old one behind as a duplicate. '
        'THIS INCLUDES RESTYLING: "make it prettier" / "おしゃれな資料にして" '
        '/ "use a different design" after you just made a deck means REDO '
        'THAT SAME FILE, not make a second one. Read it back first '
        '(read_page -> attachmentPath -> read_device_file) so you keep the '
        'content and only change the look. If you leave "fileName" empty and '
        'the page holds exactly one file of that kind, that one is rewritten. '
        'It always writes the WHOLE file, so pass the complete new content: '
        'anything you leave out is gone. To see what is there now, get the '
        'file from read_page (an attachment node has attachmentName and '
        'attachmentPath) and read it with read_device_file on that '
        'attachmentPath (files this tool created during this run are '
        'pre-allowed; after a restart the user may be asked once). '
        'Choose "kind": '
        '"xlsx"/"csv" -> pass "rows" (array of arrays of strings; first row '
        'is the header). Cells are kept EXACTLY as written unless they are '
        'already a plain number, so "00123", "09012345678" and 20-digit ids '
        'survive; in xlsx a cell starting with "=" becomes a real formula. '
        '"docx"/"txt"/"md"/"pdf" -> pass "title" and "paragraphs" (array of '
        'strings, one per paragraph); "pdf" may ALSO take "rows" to append a '
        'table. '
        '"pptx" -> pass "slides" (array of objects: '
        '{"title": "...", "bullets": ["...", "..."]}). '
        'THE DECK IS ALWAYS DESIGNED FOR YOU: a full-bleed coloured '
        'background from the theme, the FIRST slide rendered as a cover '
        '(big title + accent rule; its bullets become the sub-title, so give '
        'it a title and ONE short line), and every later slide with a thin '
        'accent band, the title on the background and an accent rule fitted '
        'to it. Do not add shapes just to fake a background, do not ask for '
        'a white deck, and do not ask the user to choose colours. '
        'A pptx slide may ALSO carry "imagePrompt" (an ENGLISH description '
        'of a picture to draw with AI and place on that slide - be concrete '
        'about subject, colours and mood, and never ask for text or logos), '
        '"imagePos" ("right" / "left" / "full", default "right"), '
        '"imageQuery" (2-4 ENGLISH keywords for a web photo search - ALWAYS '
        'give it, because the user may have set the app to fetch photos '
        'from the web instead of drawing them), '
        '"imageShape" ("rect" default / "roundRect" / "ellipse" = the '
        'picture is cropped to a circle, which looks stylish for people, '
        'products or food on a cover or section slide), and '
        '"shapes" (up to 3 decorations per slide, each '
        '{"kind":"rect|roundRect|ellipse|line|arrow","x":..,"y":..,"w":..,'
        '"h":..,"fill":"RRGGBB","line":"RRGGBB","lineWidth":..} where '
        'x/y/w/h are PERCENTAGES of the slide). '
        'USE THEM when the user asks for a deck that should LOOK good ("a '
        'stylish cafe PowerPoint", "make it pretty") - a text-only deck is '
        'not what they asked for. When the app is set to draw pictures with '
        'AI, each picture costs about 0.047 USD of the '
        'user\'s prepaid credit and takes a while (fetching from the web '
        'is free), so put one on the cover '
        'and 2-3 key slides, not on every slide (at most 4 per call are '
        'drawn; the rest of the slides are still made, without a picture). '
        'Because it costs money, say up front that you will add N pictures. '
        'WHERE IT GOES: if the user did NOT say where to put it, LEAVE '
        '"pageId" OUT (or empty) - the file is then pinned to the page they '
        'currently have open, which is what they expect. Do NOT create a new '
        'page just to hold a file, and do not ask which page; only pass a '
        'pageId when the user named a specific page or you just made one for '
        'this task. It must be a MIND MAP or GALLERY page (free-note / video '
        'pages cannot hold file tiles): when you DO pass such a pageId the '
        'call FAILS and nothing at all is created, so check the page type '
        'first (list_pages). Only when you leave "pageId" out is the page '
        'the user has open used. '
        'Returns {path, nodeId, fileReplaced, tileCreated, attachedToPageId} '
        '("replaced" is still returned as an alias of "fileReplaced"). When '
        '"fileReplaced" is true the file that was already there was updated '
        '- say updated, not created. "tileCreated" says whether a NEW tile '
        'was placed on the page: it is true for a brand new file and also '
        'when the old tile had been deleted, so do not tell the user the '
        'same tile was reused unless it is false. "nodeId" is the tile the '
        'file sits on - address that tile by this id, and when "tileCreated" '
        'is true give the user the NEW id rather than one from an earlier '
        'call. REWRITING IS PERMANENT: undo_page and Ctrl+Z CANNOT bring the '
        'old contents back (they only put the page and its tiles back, never '
        'a file on disk). A copy of the version from just before the call is '
        'kept for 7 days and comes back as "previousVersionPath" when one '
        'could be made, but rewriting the file from that copy is only exact '
        'for txt, md and csv. So say that you are about to rewrite the file '
        'BEFORE you overwrite something the user may still want.',
        {
          'pageId': {
            'type': 'string',
            'description':
                'Leave this out to use the page the user has open. Only set '
                'it when a specific page was named.',
          },
          'kind': {
            'type': 'string',
            'enum': ['xlsx', 'csv', 'docx', 'pptx', 'pdf', 'txt', 'md']
          },
          'fileName': {'type': 'string'},
          // 後ろへ足すだけ (= ユーザー要望: 前のスライドを変えずに追記)。
          'append': {
            'type': 'boolean',
            'description':
                'pptx only. true = keep the slides that are already in the '
                'file and add these ones AFTER them. Use it whenever the '
                'user asks to add slides to a deck that already exists '
                '("add a slide about X", "追記して"), so their earlier '
                'slides are not rewritten. Pass the same fileName as the '
                'existing deck, and put ONLY the new slides in "slides".',
          },
          'title': {'type': 'string'},
          'paragraphs': {
            'type': 'array',
            'items': {'type': 'string'},
            // ★ = 継続検証 283。 字下げと空段落が残る事を書いておく。
            'description':
                'One entry per paragraph, kept EXACTLY as you write it: '
                'leading and trailing spaces (half- or full-width) are NOT '
                'trimmed, and an empty string makes a BLANK paragraph, so '
                'you can lay the text out yourself.',
          },
          'rows': {
            'type': 'array',
            'items': {
              'type': 'array',
              'items': {'type': 'string'}
            },
            // ★ = 動作検証 2026-09-30「郵便番号 00123 が 123、 20 桁 ID が
            //   丸められて保存される」/「=SUM(...) が数式にならない」。
            //   直した振る舞いを道具の説明にも書く (AI が「文字のまま保つ
            //   には」 と聞かれた時に答えられるように)。
            'description':
                'One entry per row; the first row is the header. Every cell '
                'is a string and is written EXACTLY as you give it unless it '
                'is already a plain number: "00123", "09012345678", "+81", '
                '"1.2300", "1e3" and long ids keep every character (they are '
                'stored as text), while "123" / "-8" / "1.5" become real '
                'numbers you can sum. In xlsx a cell starting with "=" '
                'becomes a REAL FORMULA ("=SUM(B2:B9)", "=B2*C2", "=IF(...)") '
                '- in csv it stays the literal text.',
          },
          // 配色 (= ユーザー要望: 白地に文字だけの資料にしない)。
          'theme': {
            'type': 'string',
            // ★ 名前は _kPptxThemes と 1 文字違わず合わせる (画面側は名前で
            //   引くので、 違う名前を書かれると黙って別の配色になる)。
            'enum': [
              'ミッドナイト',
              'モダンブルー',
              'サンセット',
              'フォレスト',
              'モノクロ',
              'パステル',
            ],
            'description':
                'Colour theme for the deck. Every deck is built with a '
                'full-bleed coloured background, a cover slide, a thin accent '
                'band and an accent rule under each title - the same look the '
                'in-app slide editor produces. Leave it out and one is chosen '
                'from the title. ミッドナイト = dark slate + gold (default look), '
                'モダンブルー / サンセット / フォレスト / モノクロ are dark, パステル is '
                'light. Never ask the user to pick one unless they bring it up.',
          },
          'slides': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'title': {'type': 'string'},
                'bullets': {
                  'type': 'array',
                  'items': {'type': 'string'}
                },
                // 絵と飾りの図形 (= ユーザー要望: 味気ない資料にしない)。
                'imagePrompt': {'type': 'string'},
                'imagePos': {
                  'type': 'string',
                  'enum': ['right', 'left', 'full']
                },
                // ── 動き (= ユーザー要望: アニメーション付きの資料を
                //    AI に作らせたい) ──
                'animation': {
                  'type': 'string',
                  'description':
                      'Entrance animation for this slide. The title, the '
                      'body and the picture appear one per click, with this '
                      'effect. Leave it out for no animation. One of: '
                      'appear, fadeIn, flyInLeft, flyInRight, flyInTop, '
                      'flyInBottom, wipeLeft, wipeRight, wipeTop, '
                      'wipeBottom, zoomIn, floatUp, wheel. '
                      'It is written into the .pptx as a real PowerPoint '
                      'effect, so it plays in PowerPoint too.',
                },
                'imageQuery': {'type': 'string'},
                'imageShape': {
                  'type': 'string',
                  'enum': ['rect', 'roundRect', 'ellipse']
                },
                // 飾りの図形 (= 味気ない資料にしない)。
                'shapes': {
                  'type': 'array',
                  'items': {'type': 'object'},
                  'description':
                      'Decorations for this slide, up to 3. Each is '
                      '{kind: rect|roundRect|ellipse|line|arrow, x, y, w, h '
                      '(percent of the slide), fill: "RRGGBB", '
                      'line: "RRGGBB", lineWidth: pt}. Use them like the '
                      'in-app slide editor does: a colour band down one '
                      'side, a big soft circle behind the title, a thin '
                      'rule. Do not cover the text.',
                },
              },
            },
          },
        },
        // pageId は任意 (= ユーザー要望: 場所を明示しない時は
        //   開いているページに置く)。
        ['kind']),
    // ─── ページ本文の読み返し (= 動作検証レポート 改善案 2「AI が書いた
    //     結果を事後検証できず、 重ねて足したり丸ごと上書きしてしまう」)。
    //     本文はページ JSON の外にあるので read_page では取れない ─────────
    _tool(
        'read_markdown',
        'Read back a markdown page. read_page does NOT return the body - it '
        'lives outside the page JSON, so this is the only way to see what is '
        'actually written. Returns {selected, tabs:[{index, name, url?, '
        'text}]}. write_markdown replaces the SELECTED tab, so read this '
        'first before overwriting, and before appending, so you do not repeat '
        'text that is already there. A tab with a "url" is a web tab: never '
        'write into it, you would wipe the page it shows.',
        {
          'pageId': {'type': 'string'},
        },
        ['pageId']),
    _tool(
        'read_document',
        'Read back a notepad ("document") page, or the document layer of a '
        'free note ("paint"). read_page does NOT return the body. Returns '
        '{scope, papers:[{index, name, text}], appendsTo}. For a "document" '
        'page scope is "document", there is one paper per sheet and '
        'append_document_text adds to the LAST paper. For a "paint" page '
        'scope is "sheet": one paper PER TAB of EVERY BINDER - each paper '
        'also carries binderIndex / binderName / selected, and "binders" '
        'lists the binders (same indexes as list_paint_tabs). Nothing is '
        'left out and reading does not change which tab is open. Pass '
        '"binder" to narrow the reply to one binder. append_document_text '
        'writes to the OPEN tab only - that is binder "binder" + tab '
        '"appendsTo", so call select_paint_tab first to write elsewhere. '
        'Read this first to see what is already written instead of '
        'repeating it.',
        {
          'pageId': {'type': 'string'},
          'binder': {
            'type': 'integer',
            'description': 'Free note only: read just this binder (index '
                'from list_paint_tabs). Omit to get every binder.',
          },
        },
        ['pageId']),
    _tool(
        'read_paint_items',
        'Read back what is on the CURRENT sheet of a free-note ("paint") '
        'page - the same sheet add_paint_text writes to. Returns the text '
        'items with their positions, plus how many strokes / shapes / images '
        'are on the sheet and whether it has a background picture. Use it to '
        'check what you already placed before adding more, so captions do '
        'not pile up on top of each other. To see the other sheets call '
        'list_paint_tabs, and select_paint_tab to move between them. '
        '"documentLayerScope" is "sheet" when this tab has text written by '
        'append_document_text (read it with read_document), or "none".',
        {
          'pageId': {'type': 'string'},
        },
        ['pageId']),
    _tool(
        'list_video_editor_items',
        'Read back the timeline of a "videoEditor" page. Returns '
        '{items:[{index, itemId, kind, layer, startMs, durationMs, text?, '
        'path?, missingFile?}]} - the same field names add_video_editor_item '
        'takes, so you can read one and rebuild it. Call this before adding '
        'captions so you do not stack two on the same moment, and check '
        '"missingFile": that clip will export as black.',
        {
          'pageId': {'type': 'string'},
        },
        ['pageId']),
    // ─── クラウド同期 (= ユーザー要望「クラウド同期も MCP から行える
    //     ように」)。 ヘッダーの sync ボタンは窓を開くだけなので、
    //     本当に転送する道をここに用意する ───────────────────────────
    _tool(
        'cloud_sync',
        'Actually transfer pages to or from the cloud - this really runs, it '
        'does not just open a window (run_app_command "sync" only opens the '
        'window). action: "upload" sends pages up, "download" brings them '
        'down, "list" shows what the cloud holds without changing anything. '
        'Upload with no pageIds sends ONLY the page the user is looking at - '
        'never pass every page unless they asked for that, because uploads '
        'count against their monthly allowance. Download with no pageIds '
        'takes everything in the cloud. The reply is {ok, ...}: when ok is '
        'false, read "reason" and tell the user - do NOT retry in a loop. '
        'Needs the Max plan and a sync group; the user may also have set an '
        'upload cap, and hitting it comes back as a reason. After an upload, '
        'report monthlyUploadBytes vs monthlyUploadLimit if the user asks '
        'how much is left.',
        {
          'action': {
            'type': 'string',
            'enum': ['upload', 'download', 'list'],
          },
          'pageIds': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'folderId': {'type': 'string'},
        },
        ['action']),
    _tool(
        'list_app_commands',
        'List the app features that can be launched (flashcards, silent '
        'camera, calendar, QR reader, timer, cloud sync, and so on). Returns '
        'id + label pairs. Call this first when the user asks to open or '
        'start a feature you are not sure about. The list is the whole truth '
        'FOR THIS DEVICE: anything not in it does not exist or does not work '
        'here (the app lock and the focus lock are mobile-only, so they are '
        'absent on a PC), and everything in it can be run with '
        'run_app_command and placed with set_header_buttons - cloud sync '
        '("sync") included, so never refuse it as user-only. An entry marked '
        '"needsUser": true does start, but it only OPENS a window the user '
        'must then finish (choosing which pages to sync, choosing a lock '
        'duration). Report those as "the window is open", never as '
        '"synced" / "locked" / "done". To actually transfer pages yourself, '
        'use cloud_sync instead.',
        {}),
    _tool(
        'run_app_command',
        'Launch one app feature by its id (see list_app_commands). Example '
        'ids: "flashcards" (flash cards), "silentCamera" (silent camera), '
        '"calendar", "qrReader", "sync" (cloud sync). The feature opens on '
        'screen for the user. Just run it when asked - do not ask for '
        'confirmation first. READ THE REPLY: "launched" means it ran; '
        '"opened" means a window is now on screen and the user has to finish '
        'it there (cloud sync and the locks all behave this way, and a plan '
        'upgrade prompt may appear instead) - say the window is open, never '
        'that you synced or locked anything. To transfer pages yourself '
        'without a window, use cloud_sync. '
        'This only OPENS features; it never edits data: deleting a page is '
        'delete_page, changing a page kind is set_page_type, and header '
        'buttons are set_header_buttons. '
        'The reply carries "screenId" and "closeable". Pass that screenId to '
        'close_app_command ONLY when "closeable" is true; when it is false '
        'the reply carries "cannotClose" and "tracked": false - that screen '
        'is not tracked from here, so do NOT call close_app_command for it, '
        'tell the user to close it themselves. '
        'Commands that finish on the spot and open nothing (undo, redo, the '
        'zoom buttons, the axis and scale locks, cut mode, range select, '
        'select all, and the bottom-bar toggle on a phone) answer '
        '"launched": true with "opensScreen": false and NO screenId - never '
        'call close_app_command for those. undo and redo also report what was '
        'restored, and the zoom buttons return the new "scalePercent".',
        {
          'id': {'type': 'string'},
        },
        ['id']),
    // ★ = 機能追加案 継続検証190「アプリ自身を安全に検証できるように」の
    //   **読む側だけ**。 合成クリックは入れない (run_automation が断って
    //   いるとおり、 このアプリ自身を叩くと利用者の本物のページを壊す)。
    _tool(
        'describe_screen',
        'Report what is on screen RIGHT NOW. Read-only: it changes nothing. '
        'Returns the foreground target (the same answer as list_pages), the '
        'current page, the split layout and what each cell shows, whether '
        'the page-list drawer is open, which floating windows and pane tools '
        'are open, which full-screen screens the assistant opened, the text '
        'editor state, and the last few notices the app showed the user. '
        'Use it to CHECK what a run_app_command / set_split_view call '
        'actually did, and to read back the wording the app displayed. '
        'TWO HONEST LIMITS, and you must respect them: (1) this reports the '
        'app own registries, NOT a widget tree - ordinary confirmation '
        'dialogs, context menus and the contents of a screen are invisible '
        'here; (2) "fullScreenScreens" lists only dialogs that '
        'run_app_command opened, not ones the user opened. When the user '
        'asks about something this does not cover, say you cannot see it - '
        'never report it as "nothing is open". There is no way to click or '
        'type into this app from a tool: do it with the tools instead '
        '(run_app_command / close_app_command / set_split_view / the page '
        'and node tools).',
        {}),
    // ★ = 動作検証の機能修正案「MCP から開いた機能画面を閉じる操作」。
    //   開きっぱなしだと、 続けて検証した時に画面が積み上がっていった。
    _tool(
        'close_app_command',
        'Close a feature screen that run_app_command opened. Pass the '
        '"screenId" it returned; pass nothing to close everything opened from '
        'here and put the view back as it was. '
        'Returns {closed:[ids], notOpen:[{id, reason}]}. Floating windows, '
        'tools embedded in a split pane, the floating tools kept on their own '
        '(calculator, stopwatch, pomodoro), the separate tool '
        'windows those open on a PC, the calendar view AND full-screen '
        'screens that run_app_command opened can all be closed this way. A '
        'screen the app cannot close from code (it was opened by the user, or '
        'it is already gone) comes back in notOpen with reason '
        '"fullScreenDialog" / "notCurrentlyOpen" / "alreadyClosed" - read the '
        'reason and say that, rather than claiming it is closed. When '
        'run_app_command answered "closeable": false for a screen, do not '
        'call this for it at all.',
        {
          'id': {'type': 'string'},
        }),
    // ★ = 継続検証 412 / 機能追加案「前面のファイル閲覧画面を MCP から
    //   閉じられない」。 close_app_command は run_app_command で開いた物だけ
    //   が相手なので、 利用者が開いたエディタには閉じる道が無かった。
    _tool(
        'close_foreground_file',
        'Close the file editor that is open ON TOP of the map - the one '
        'list_pages and describe_screen report as the foreground target '
        '(xlsx / csv, pptx, docx and text files). Takes no arguments: it '
        'always acts on that one screen. '
        'READ THE REPLY: "closed": true means it is gone, and "pageBehind" '
        'names the page now in front. "closed": false means it is STILL '
        'OPEN - reason "unsavedEditsKept" (the file had unsaved edits, so '
        'the user was asked and kept it) or "notClosableFromHere" (it is '
        'embedded in a split pane, so change the pane with set_split_view '
        'instead). Never say you closed it unless "closed" is true. '
        'This does NOT close feature screens opened with run_app_command - '
        'use close_app_command for those.',
        {}),
    // ─── 画面分割 (= ユーザー報告: 「4 画面分割にして」 と頼んだのに
    //     「2 画面分割しかできない」 と断られた。 2x2 は前からある) ───────
    _tool(
        'set_split_view',
        'Arrange the app window into split panes. '
        'layout: "quad" = 2x2, FOUR panes at once (desktop only; on a phone '
        'it falls back to a 2-pane split), "leftRight" = two panes side by '
        'side, "topBottom" = two panes stacked, "off" = back to one pane. '
        'A 2x2 four-way split IS supported - never tell the user the app can '
        'only do 2 panes. There is no 3-pane layout. '
        'TO MAKE ONE PANE FULL SCREEN ("make the bottom-right pane full '
        'screen", "右下の画面を全画面にして"): call this with layout "off" '
        'AND "cell" set to that pane (0=top-left, 1=top-right, 2=bottom-left, '
        '3=bottom-right). The split closes and the page that was in that pane '
        'fills the window. DO IT - do not explain how the user could do it '
        'by hand. '
        'TO MAKE A NAMED PAGE FULL SCREEN, even one that is not in any pane: '
        'call layout "off" with that ONE page as the only entry of "pageIds" '
        '(id or name). The split closes and that page fills the window. This '
        'works for EVERY page kind, including the document / videoEditor / '
        'automation pages that cannot go in a pane, so it is also the way to '
        'simply open such a page; the reply gives "currentPageId", "pageType" '
        'and "foreground" so you can check it really switched. Use '
        '"cell" when you mean "whatever that pane is showing" and "pageIds" '
        'when you mean a particular page - sending both is refused. '
        'Optionally pass pageIds to fill the cells, in the order '
        '0 = top-left, 1 = top-right, 2 = bottom-left, 3 = bottom-right. '
        'Each entry may be an id from list_pages OR a page name, as long as '
        'only one page has that name. The SAME page may fill several cells '
        '(handy for comparing two distant parts of one big map): both cells '
        'show the same document and edits appear in both at once, while '
        'scroll position and zoom stay independent per cell. '
        'document / videoEditor / automation pages cannot go in a PANE '
        '(they can still be opened full screen with layout "off" as '
        'above), and '
        'a page the plan cannot open is refused. Cells you leave out are '
        'filled with other pages automatically. Calling it twice with the '
        'same layout is safe - it does not toggle the split back off; use '
        '"off" to close it. '
        'CHECK "couldNotPlace": every entry carries a "reason" (notFound / '
        'ambiguousName / pageType / lockedByPlan / '
        'noCell / couldNotOpen / substituted). "substituted" means the app '
        'put a DIFFERENT page in that cell - report that instead of claiming '
        'the requested page is open. The reply also returns "pageIds" (what '
        'each visible cell really shows) and "editorCell". '
        'ALWAYS read the returned "layout" / "cells" and report THAT, not '
        'what you asked for.',
        {
          'layout': {
            'type': 'string',
            'enum': ['off', 'leftRight', 'topBottom', 'quad']
          },
          'pageIds': {
            'type': 'array',
            'items': {'type': 'string'}
          },
          // 全画面にするセル (layout='off' の時だけ意味を持つ)。
          'cell': {'type': 'integer'},
        },
        ['layout']),
    // ─── アプリの説明書 (= ユーザー要望: skills のように、 必要な時だけ
    //     詳しい仕様を読ませる。 常時渡す要約は AGENTS.md 側) ────────────
    _tool(
        'list_app_docs',
        'List the built-in documentation about this app that you can read. '
        'Returns {name, title} pairs. Read one with read_app_doc when you '
        'need the exact behaviour of a feature (billing, MCP tools, sync, '
        'node layout, known bugs) instead of guessing.',
        {}),
    _tool(
        'read_app_doc',
        'Read one built-in app document by name (see list_app_docs). '
        'Names: "billing" (payments / subscription / AI credit), '
        '"mcp" (MCP tools and the agent loop), '
        '"features" (startup, saving, cloud sync, notifications, shortcuts), '
        '"layout" (how nodes are placed, pushed aside and auto-arranged), '
        '"qa" (a developer pre-release checklist of defects seen in the PAST '
        'and how to re-check them - NOT a list of bugs open today; do not '
        'present it to the user as current known issues). '
        'The text is Markdown with Mermaid diagrams.',
        {
          'name': {'type': 'string'},
        },
        ['name']),
    // ─── 開いているテキストファイル (= ユーザー要望: テキストエディタの
    //     中身を MCP / AI から編集できるように) ─────────────────────────
    _tool(
        'text_file_status',
        'Check the text file currently open in the app TEXT EDITOR window. '
        'Returns {textEditorOpen, fileName, lineCount, foregroundFile?}. '
        'textEditorOpen tells you whether the TEXT EDITOR has a file - it is '
        'NOT "is anything on screen": foregroundFile (fileName, path, '
        'editorKind) is present whenever some file is on top, editor or '
        'viewer. So textEditorOpen:false + foregroundFile:{editorKind:"pptx"} '
        'means a PPTX is on screen that these tools cannot touch. '
        '("open" is kept as the old name for textEditorOpen.) '
        'The other text_file_* tools work ONLY on the text editor file - they '
        'cannot touch a file that is merely attached to a page. If '
        'textEditorOpen is false, do '
        'NOT create a new file, and do NOT ask the user to open something '
        'just so you can edit a document that is attached to a page. '
        'Instead find it with read_page (attachmentName / attachmentPath), '
        'read it with read_device_file on that attachmentPath, and rewrite '
        'it with create_document_file using the SAME pageId and the SAME '
        'fileName - that replaces it in place.',
        {}),
    _tool(
        'text_file_read',
        'Read the text file currently open in the app text editor as '
        'numbered lines. Optionally pass startLine/endLine (1-based, '
        'inclusive) to read only part of a long file. Out-of-range or reversed '
        'values are clamped to the file, so check the returned lineCount / '
        'startLine / endLine (and "note") before quoting the result, and '
        'tell the user when the lines they asked for do not exist. '
        'This reads ONLY the file open in the editor; to read a file '
        'attached to a page use read_device_file with the attachmentPath '
        'from read_page.',
        {
          'startLine': {'type': 'integer'},
          'endLine': {'type': 'integer'},
        }),
    _tool(
        'text_file_edit',
        'Edit the text file currently open in the app text editor. Pass '
        'ALL edits in ONE call as the "edits" array - do not call this '
        'tool once per line. Each edit is {"action": "replace" | "insert" '
        '| "delete" | "set_all", "start": int, "end": int, "text": "..."}. '
        'Line numbers are 1-based and refer to the file BEFORE this call '
        '(edits are applied bottom-up, so earlier line numbers stay '
        'valid). "replace" rewrites lines start..end with text (may '
        'contain newlines). "insert" inserts text before line start '
        '(start = lineCount+1 appends at the end). "delete" removes lines '
        'start..end. "set_all" replaces the whole file with text and must '
        'be the only edit in the call. The change appears in the editor AND '
        'is written to the file straight away - do not tell the user to '
        'press save. '
        'This works ONLY on the file open in the editor. It cannot change a '
        'file that is just attached to a page - rewrite that one with '
        'create_document_file (same pageId + same fileName), which replaces '
        'it in place instead of adding a copy.',
        {
          'edits': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'action': {
                  'type': 'string',
                  'enum': ['replace', 'insert', 'delete', 'set_all']
                },
                'start': {'type': 'integer'},
                'end': {'type': 'integer'},
                'text': {'type': 'string'},
              },
            },
          },
        },
        ['edits']),
    // ── ページ / フォルダーの整理 (= ユーザー要望: 出来ないと断っていた分) ──
    _tool(
        'rename_page',
        'Rename a page. Pass "pageId" + "name", or "pages" (array of '
        '{pageId, name}) to rename several in ONE call. A blank name is '
        'rejected. The result lists what was actually renamed - report that.',
        {
          'pageId': {'type': 'string'},
          'name': {'type': 'string'},
          'pages': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'pageId': {'type': 'string'},
                'name': {'type': 'string'},
              },
            },
          },
        }),
    _tool(
        'reorder_pages',
        'Reorder the page list. Pass "pageIds" = the FULL order you want '
        '(ids from list_pages). Pages you leave out keep their relative order '
        'after the ones you listed, so a short prefix is enough to move a few '
        'pages to the top. The result returns the resulting order.',
        {
          'pageIds': {
            'type': 'array',
            'items': {'type': 'string'}
          },
        },
        ['pageIds']),
    _tool(
        'list_folders',
        'List the folders that group pages, with how many pages each holds. '
        'list_pages reports each page "folderId" (null = outside any folder).',
        {}),
    _tool(
        'create_folder',
        'Create a folder for grouping pages. Returns its id, which '
        'move_page_to_folder takes. Folders are flat - they cannot nest.',
        {
          'name': {'type': 'string'},
        }),
    _tool('rename_folder', 'Rename a folder (ids come from list_folders).', {
      'folderId': {'type': 'string'},
      'name': {'type': 'string'},
    }, [
      'folderId',
      'name'
    ]),
    _tool(
        'delete_folder',
        'Delete a folder. By default the pages inside are KEPT and simply '
        'moved out of the folder. "deletePages":true deletes them too and '
        'CANNOT be undone - only pass it when the user asked for exactly '
        'that, and say so plainly in your reply.',
        {
          'folderId': {'type': 'string'},
          'deletePages': {'type': 'boolean'},
        },
        ['folderId']),
    _tool(
        'move_page_to_folder',
        'Put pages into a folder, or take them out. Pass "folderId" to move '
        'in, or "toRoot":true to move out. Use "pageIds" (array) to move '
        'several in ONE call. Unknown ids are reported in "failed" instead of '
        'being silently ignored. If the destination already holds a page with '
        'the same name, the moved page is numbered ("name (2)") just like '
        'create_page does - the reply reports the name it really got.',
        {
          'pageId': {'type': 'string'},
          'pageIds': {
            'type': 'array',
            'items': {'type': 'string'}
          },
          'folderId': {'type': 'string'},
          'toRoot': {'type': 'boolean'},
        }),
    // ── 線だけを消す ──
    _tool(
        'disconnect_nodes',
        'Remove ONLY the line between two nodes - BOTH nodes stay. Direction '
        'does not matter. "from"/"to" accept a node id OR its exact title '
        '(an approximate title is rejected, never guessed; a title shared by '
          'TWO OR MORE nodes is refused as ambiguous_name with the candidate '
          'ids, so no line is ever cut by guesswork). Pass '
        '"connections" (array of {from, to}) to remove several in ONE call. '
        'If the two were not connected the call reports that instead of a '
        'false success. Undoable with Ctrl+Z.',
        {
          'pageId': {'type': 'string'},
          'from': {'type': 'string'},
          'to': {'type': 'string'},
          'fromId': {'type': 'string'},
          'toId': {'type': 'string'},
          'connections': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'from': {'type': 'string'},
                'to': {'type': 'string'},
                'fromId': {'type': 'string'},
                'toId': {'type': 'string'},
              },
            },
          },
        },
        ['pageId']),
    // ── 図形 (装飾) ──
    _tool(
        'add_decoration',
        'Draw a shape on a mind map page (a decoration: frame, arrow, '
        'underline...). PREFER "aroundNodes" (array of node ids or titles): '
        'the shape is fitted around those nodes with a margin, so you never '
        'have to invent coordinates. An entry in "aroundNodes" whose name '
          'matches TWO OR MORE nodes is skipped instead of guessed and comes '
          'back in "aroundAmbiguous" - the other entries are still enclosed, so '
          'the shape IS drawn (pass the id to include it). '
          'Only fall back to x1/y1/x2/y2 when the '
        'user gave real coordinates. "layer" 1-3 draws under the nodes, 4-5 '
        'above them (a filled shape on 4-5 hides the map). "color" is RGB '
        '(the alpha byte is ignored). Pass "shapes" (array) to add several in '
        'ONE call. Shapes carry no text unless you set "text". Undoable.',
        {
          'pageId': {'type': 'string'},
          'kind': {
            'type': 'string',
            'enum': [
              'line',
              'arrow',
              'rectangle',
              'ellipse',
              'wavyLine',
              'filledRectangle',
              'circle',
              'hollowCircle',
              'hollowTriangle',
              'hollowDiamond',
              'star',
              'pentagon',
              'hexagon',
              'heart',
              'cross',
            ]
          },
          'aroundNodes': {
            'type': 'array',
            'items': {'type': 'string'}
          },
          'x1': {'type': 'number'},
          'y1': {'type': 'number'},
          'x2': {'type': 'number'},
          'y2': {'type': 'number'},
          'color': {'type': 'integer'},
          'strokeWidth': {'type': 'number'},
          'text': {'type': 'string'},
          'filled': {'type': 'boolean'},
          'layer': {'type': 'integer'},
          'shapes': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'kind': {'type': 'string'},
                'aroundNodes': {
                  'type': 'array',
                  'items': {'type': 'string'}
                },
                'x1': {'type': 'number'},
                'y1': {'type': 'number'},
                'x2': {'type': 'number'},
                'y2': {'type': 'number'},
                'color': {'type': 'integer'},
                'strokeWidth': {'type': 'number'},
                'text': {'type': 'string'},
                'filled': {'type': 'boolean'},
                'layer': {'type': 'integer'},
              },
            },
          },
        },
        ['pageId']),
    _tool(
        'delete_decoration',
        'Delete a shape. The ids come from read_page ("decorations").',
        {
          'pageId': {'type': 'string'},
          'decorationId': {'type': 'string'},
        },
        ['pageId', 'decorationId']),
    // ── 端末のファイルを読む (利用者の許可つき) ──
    _tool(
        'read_device_file',
        'Read ONE file from this device (text, md, csv, json, html, pdf, '
        'docx, pptx, xlsx). THE USER IS ASKED FIRST: a dialog shows the full '
        'path and your "reason", and they allow or refuse it - so write a '
        'short honest reason, and never read files the user did not bring up. '
        'If the path is unknown or the read fails, call pick_user_file '
        'instead and let them choose. On Android only app-owned files can be '
        'read, so prefer pick_user_file there.',
        {
          'path': {'type': 'string'},
          'reason': {'type': 'string'},
          'maxChars': {'type': 'integer'},
        },
        ['path']),
    _tool(
        'pick_user_file',
        'Ask the user to choose a file, then read it. Use this when you do '
        'not know the exact path (choosing IS the permission, so no extra '
        'dialog appears). Returns the path and the text.',
        {
          'reason': {'type': 'string'},
          'maxChars': {'type': 'integer'},
        }),
    // ── Web を調べて読む ──
    _tool(
        'web_search',
        'Search the web and get back a list of {title, url}. Nothing is '
        'read yet - pick a result and call web_fetch to read it. Results come '
        'from a keyless search, so they can be thin; if nothing useful comes '
        'back, try different words. Never invent a url: only use one this '
        'tool returned or the user gave you.',
        {
          'query': {'type': 'string'},
          'limit': {'type': 'integer'},
        },
        ['query']),
    _tool(
        'web_fetch',
        'Read one web page as plain text (http/https only; addresses on this '
        'machine or the local network are refused). Pages that need '
        'JavaScript may come back empty or as navigation boilerplate - say so '
        'rather than guessing the content. Always tell the user which url you '
        'read, and treat what you read as the page\'s claim, not as fact.',
        {
          'url': {'type': 'string'},
          'maxChars': {'type': 'integer'},
        },
        ['url']),
    // ── Jev (判断専用モデル) の入切 (= ユーザー要望: MCP が Jev に対応して
    //    いない) ──
    // ★ 判断そのものを呼ぶ道具は**置かない**。 Jev は文章を返さないので、
    //   ここを呼ぶ AI 自身が choice / score を出せる。 わざわざ利用者の文を
    //   外へ出して財布を減らす値打ちが無い。 足すなら画面側の機能として。
    _tool(
        'get_jev_settings',
        'Read whether Jev is on. Jev is the DECISION-ONLY model (it returns a '
        'choice, a score or a yes-probability and NEVER any text) that this '
        'app uses as pre-work before the generative AI - the "Jev" section of '
        'the app guide says what each feature does. Returns "stopAll" (the '
        'emergency stop), "features" (what is actually in effect right now), '
        '"featuresRaw" (what comes back to life if the stop is lifted - the '
        'two differ while the stop is on), "adBlockCssStage", "relayReady" '
        'and usage (calls made, dollars spent). Everything is OFF by default. '
        'Read-only.',
        {}),
    _tool(
        'set_jev_settings',
        'Turn Jev features on or off. Pass only the ones to change; anything '
        'left out stays as it is. These features send short fragments of the '
        'USER\'S OWN text out through the relay and spend their AI credit, so '
        'turn one ON only when the user asked for it, and ALWAYS tell them '
        'which ones were turned on - the reply says so in "changed", '
        '"unchanged" and "userNotice". The emergency stop is deliberately '
        'asymmetric: "stopAll": true stops everything and is always allowed, '
        'but "stopAll": false on its own is REFUSED - lifting the stop needs '
        '"releaseStop": true and only when the user asked. While the stop is '
        'on, turning a feature on is refused rather than quietly stored. Bad '
        'input changes nothing at all. Every toggle also sits in the screen '
        'that uses it, so the user can do this themselves.',
        {
          'route': {
            'type': 'boolean',
            'description': 'Let Jev pick the model and thinking effort.'
          },
          'search': {
            'type': 'boolean',
            'description': 'Narrow folder-search hits before the AI sees them.'
          },
          'book': {
            'type': 'boolean',
            'description': 'Reorder book-search results by relevance.'
          },
          'webRank': {
            'type': 'boolean',
            'description': 'Sort web-search results by relevance.'
          },
          'fileFind': {
            'type': 'boolean',
            'description': 'Sort file search by how close the contents are.'
          },
          'docQa': {
            'type': 'boolean',
            'description': 'Send only the part of a long document the '
                'question is about.'
          },
          'cardGrade': {
            'type': 'boolean',
            'description': 'Grade flashcard / quiz answers by meaning instead '
                'of by matching characters.'
          },
          'stopAll': {
            'type': 'boolean',
            'description': 'true = emergency stop: every Jev feature stops at '
                'once (always allowed). false is refused on its own - use '
                'releaseStop.'
          },
          'releaseStop': {
            'type': 'boolean',
            'description': 'Lift the emergency stop. Pass this only when the '
                'user asked to lift it.'
          },
        }),
  ];

  // ─── ツール実行 ───────────────────────────────────────────────────────

  Map<String, dynamic> _ok(Object data) => {
        'content': [
          {'type': 'text', 'text': data is String ? data : jsonEncode(data)}
        ],
        'isError': false,
      };

  /// その種別の「人が見ている中身」 を読む道具の名前。
  ///
  /// ★ = 不具合報告 2026-09-30。 以前は markdown / videoEditor 以外を
  ///   全部 read_document と案内していたので、 automation ページでは
  ///   **必ず失敗する道具**を教えてしまっていた。
  static String _contentReaderFor(String? pageType) {
    switch (pageType) {
      case 'markdown':
        return 'read_markdown';
      case 'videoEditor':
        return 'list_video_editor_items';
      case 'automation':
        return 'read_automation_page';
      case 'bookshelf':
      case 'normal':
        return 'read_page';
      default:
        return 'read_document';
    }
  }

  /// 「そんな id は無い」 と「プランで開けない」 を言い分ける文。
  ///
  /// ★ = 点検で判明 (動作検証の「本当の理由だけを言う」 の続き)。
  ///   [MindMapProvider.mcpPageById] は**開けないページにも null を返す**ので、
  ///   そのまま「そんなページは無い」 と答えると、 実在するページについて
  ///   嘘を言う事になる。 利用者は一覧でそのページを見ているので話が合わない。
  String _noPageMsg(String pageId, {String did = 'Nothing was changed.'}) =>
      _provider.isPageLockedByPlan(pageId)
          ? '"$pageId" is a real page, but it is locked on this plan (only '
              'the first ${MindMapProvider.kFreeOpenPageLimit} pages can be '
              'opened). $did'
          : 'no page has the id "$pageId" - call list_pages. $did';

  /// マップ以外の種別のページに「画面に出ないノード」 を作った時の注意書き。
  ///
  /// ★ = 継続検証 201。 document / markdown / videoEditor のページでも
  ///   ノードは本当に保存される (どのページも裏にマップ層を持っているため) が、
  ///   その画面はノードのタイルを描かない。 成功だけを返すと AI は
  ///   「置きました」 と報告し、 利用者は何も増えていない画面を見る事になる。
  ///   種別を 'normal' へ戻せばそのまま現れる (本文も残る = set_page_type の
  ///   往復で両方保たれる) ので**断らず**、 応答に必ず注意書きを載せる。
  ///   ギャラリー (bookshelf) は別で、 各道具が先に断っている。
  Map<String, Object?>? _hiddenMapLayerNote(String pageId, String tool) {
    final ty = _provider.mcpPageById(pageId)?.pageType ?? 'normal';
    if (ty == 'normal' || ty == 'bookshelf') return null;
    final instead = ty == 'markdown'
        ? 'write_markdown'
        : ty == 'videoEditor'
            ? 'add_video_editor_item'
            : 'append_document_text (or add_paint_text)';
    return {
      'pageType': ty,
      'shownOnThisPage': false,
      'pageTypeNote': 'CAREFUL: "$pageId" is a "$ty" page. Every page keeps a '
          'mind-map layer underneath, so $tool really did save the node(s) '
          'there, but a "$ty" page draws no node tiles - the user will see '
          'NOTHING new on the screen in front of them. Do not report this as '
          'placed on the page: either say it is on the page\'s hidden map '
          'layer and will appear if the page is converted with set_page_type '
          '"normal" (the $ty content is kept, so converting back and forth '
          'loses nothing), or undo it and use $instead to put something on '
          'the screen they are actually looking at.',
    };
  }

  Map<String, dynamic> _err(String message) => {
        'content': [
          {'type': 'text', 'text': message}
        ],
        'isError': true,
      };

  /// 返す JSON の中の `attachmentPath` を Windows の正規形へ揃える。
  ///
  /// = 動作検証レポート 2026-09-25 不具合 6。 `list_pages` /
  /// `list_orphan_files` / `text_file_status` は provider 側で揃えたが、
  /// `read_page` はページ JSON をそのまま返すので、 ここで通す。
  /// **保存側は触らない** (prefs とクラウドへ書かれる本物のデータなので、
  /// 書き換えると差分や容量の勘定まで揺れる)。
  void _normalizeAttachmentPaths(Object? node) {
    if (node is Map) {
      final p = node['attachmentPath'];
      if (p is String && p.isNotEmpty) {
        node['attachmentPath'] = MindMapProvider.mcpNormalizePath(p);
      }
      for (final v in node.values) {
        _normalizeAttachmentPaths(v);
      }
    } else if (node is List) {
      for (final v in node) {
        _normalizeAttachmentPaths(v);
      }
    }
  }

  /// 渡された pageId。 空なら「今開いているページ」。
  ///
  /// = ユーザー要望「現在開いているページに対して適用するか、 適用できない
  ///   なら確認取るようにして欲しい」。 pageId を書き忘れた時に、 前に
  ///   作ったページへ当てずっぽうで書き込むより、 目の前のページを指す方が
  ///   まだ意図に近い。
  String _pageIdOrCurrent(Object? raw) {
    final id = '${raw ?? ''}'.trim();
    if (id.isNotEmpty) return id;
    final pages = _provider.pages;
    return pages.isEmpty ? '' : _provider.currentPage.id;
  }

  /// AI に絵を 1 枚描かせて、 そのページ**の上**に置く。
  ///
  /// = ユーザー要望「『〜の絵を描いて』『画像を生成して』 と置き場所を
  ///   言わずに頼んだら、 開いているページに配置してほしい」。
  ///   呼ぶ側で [pageId] を _pageIdOrCurrent に通しておけば、 AI が場所を
  ///   書き忘れても開いているページへ落ちる (道具の説明頼みにしない)。
  ///
  /// 置き方はページの種類で変える。 どれも「背景」 にはしない。
  ///   normal / その他  … 画像ノード
  ///   bookshelf        … ギャラリーのタイル
  ///   paint / document … 紙の上の画像要素 (後から選んで動かせる)
  ///   markdown         … 本文の末尾に ![…](file:///…) を足す
  ///   videoEditor      … タイムラインの画像
  Future<Map<String, dynamic>> _drawImageOnPage(
    String pageId,
    String prompt, {
    String? title,
    double? x,
    double? y,
  }) async {
    final page = _provider.mcpPageById(pageId);
    if (page == null) {
      return _err(_noPageMsg(pageId, did: 'Nothing was made.'));
    }
    final type = page.pageType;
    // 背景ではなく「絵」 なので薄く描かせない。 文字は入れさせない。
    final full = '$prompt\n\n'
        'A single clear subject on a plain background. '
        'No text, no letters, no watermark, no logo.';
    // 設定に従って AI が描くか Web から取る (出どころは lastImageSource)。
    final bytes = await _provider.makeSlideImage(prompt: full, query: prompt);
    // ★ = ユーザー要望「今開いているフォルダー外に新規ファイルや
    //   フォルダーを作成しない」。 置き場は aiNewFileDir に任せる。
    final dir = await _provider.aiNewFileDir('images');
    final path = '${dir.path}${Platform.pathSeparator}'
        'img_${DateTime.now().millisecondsSinceEpoch}.png';
    await File(path).writeAsBytes(bytes, flush: true);
    final src = _provider.lastImageSource;
    final srcNote = src == null
        ? ''
        : ' The picture came from: ${src.label}'
            '${src.url == null ? '' : ' (${src.url})'}.';
    Map<String, dynamic> done(String placedOn,
            [Map<String, Object?> extra = const <String, Object?>{}]) =>
        _ok(<String, Object?>{
          'pageId': page.id,
          'pageName': page.name,
          'imagePath': path,
          'placedOn': placedOn,
          if (src != null) 'imageSource': src.label,
          if (src?.url != null) 'imageSourceUrl': src!.url,
          'tellTheUser':
              'Say WHICH PAGE you put the picture on, by name.$srcNote',
          ...extra,
        });
    // 紙のページ (フリーノート / 便箋) は紙の上へ。
    if (_provider.mcpPageIsPaintSheet(page.id)) {
      final ok = await _provider.mcpPlacePaintImage(page.id, path);
      return ok
          ? done('free-note sheet')
          : _err('could not place the picture on that free note');
    }
    if (type == 'bookshelf') {
      final gid = _provider.mcpAddGalleryItem(page.id,
          text: title ?? '', imagePath: path);
      return gid == null
          ? _err('could not add the picture to that gallery page')
          : done('gallery tile', {'nodeId': gid});
    }
    if (type == 'markdown') {
      // ★ マークダウンのページには要素 (ノード) が無いので、 本文の末尾へ
      //   絵を足す。 プレビューは file:// で開いているので画像は出る。
      final alt = (title ?? prompt).replaceAll('\n', ' ').replaceAll(']', ' ');
      final ok = await _provider.mcpWriteMarkdown(page.id,
          '![$alt](file:///${path.replaceAll('\\', '/')})',
          append: true);
      return ok > 0
          ? done('markdown body')
          : _err('could not write the picture into that markdown page '
              '(a web tab holds no body).');
    }
    if (type == 'videoEditor') {
      final iid = await _provider.mcpAddVideoEditorItem(page.id,
          kind: 'image', path: path);
      return iid == null
          ? _err('could not add the picture to that video editor page')
          : done('video timeline', {'itemId': iid});
    }
    // マップ (normal) と、 種類の分からないページは画像ノードにする。
    final nid = _provider.mcpAddImageNode(page.id,
        filePath: path, title: title, x: x, y: y);
    return nid == null
        ? _err('page not found: ${page.id}')
        : done('image node', {'nodeId': nid});
  }

  /// 2 次元配列の引数を表に直す。
  static List<List<String>> _rowsOf(Object? v) {
    if (v is! List) return const [];
    return [
      for (final r in v)
        if (r is List) [for (final c in r) '${c ?? ''}'] else ['${r ?? ''}']
    ];
  }

  /// スライドの並びに直す。
  static List<Map<String, dynamic>> _slidesOf(Object? v) {
    if (v is! List) return const [];
    final out = <Map<String, dynamic>>[];
    for (final e in v) {
      if (e is Map) {
        out.add({
          'title': '${e['title'] ?? ''}',
          'bullets': _stringList(e['bullets']),
          // ★ 絵と図形の指定を捨てない (= 以前はここで題名と箇条書きだけに
          //   組み直していたので、 AI が絵を頼んでも画面側まで届かなかった)。
          //   中身の検分は画面側 (_drawShapeFromSpec / buildPptxFromSlides)
          //   がやるので、 ここでは形だけ整える。
          'imagePrompt': '${e['imagePrompt'] ?? ''}',
          'imagePos': '${e['imagePos'] ?? ''}',
          'animation': '${e['animation'] ?? ''}',
          'imageQuery': '${e['imageQuery'] ?? ''}',
          'imageShape': '${e['imageShape'] ?? ''}',
          'shapes': e['shapes'] is List ? e['shapes'] : const [],
        });
      } else {
        out.add({'title': '${e ?? ''}', 'bullets': const <String>[]});
      }
    }
    return out;
  }

  /// その引数に「中身」 があるか。
  ///
  /// ★ = 検証レポート「空白だけのタイトルで内容のないノードを作成できる」
  ///   「空の texts 配列で空のギャラリー項目が作られる」。
  ///   これまでは鍵が**有るかどうか**しか見ていなかったので、
  ///   `{"title":"   "}` や `texts: []` が素通りしていた。
  ///   空白だけ / 空の配列 / 空の入れ物は「無い」 と数える。
  static bool _hasContent(Object? v) {
    if (v == null) return false;
    if (v is String) return v.trim().isNotEmpty;
    if (v is Iterable) return v.any(_hasContent);
    if (v is Map) return v.values.any(_hasContent);
    return true; // 数値 / 真偽など
  }

  /// 絵として貼れる拡張子。 node_widget.dart の isImageAttach と**必ず**
  /// 同じにする (= 広げると、 検査は通るのにタイルに絵が出ない物が増える)。
  /// ★ 共通の一覧 (utils/image_file_types.dart) を見るようにした。
  static const Set<String> _kImageExts = kImageFileExts;

  /// 絵として貼れないパスなら、 その理由 (英語) を返す。 貼れれば null。
  ///
  /// ★ = 動作検証レポート BUG-01「存在しない画像パスでも壊れたタイルが
  ///   出来てしまう」。 双子の add_image_node には存在確認があったのに、
  ///   add_gallery_item には無かった。 二度と離れないよう入口をここへ束ねる。
  static String? _imagePathProblem(String path) {
    final t = FileSystemEntity.typeSync(path, followLinks: true);
    if (t == FileSystemEntityType.notFound) return 'file not found';
    if (t != FileSystemEntityType.file) return 'not a regular file';
    final dot = path.lastIndexOf('.');
    final ext = dot >= 0 ? path.substring(dot + 1).toLowerCase() : '';
    if (!_kImageExts.contains(ext)) {
      return 'unsupported image type ".$ext" '
          '(use ${_kImageExts.join(" / ")})';
    }
    return null;
  }

  /// 上の検査に加えて、 本当に絵として開けるかまで確かめる。
  /// 中身が壊れた png などを、 ノードを作る前に弾くため。
  Future<String?> _imagePathRejection(String path) async {
    final why = _imagePathProblem(path);
    if (why != null) return why;
    final ar = await _provider.mcpImageAspect(path);
    if (ar == null) return 'not a readable image (the file could not be decoded)';
    return null;
  }

  /// その指し方が**1 つに決まらない**時だけ、 断り文を返す。 決まれば null。
  ///
  /// ★ = 動作検証レポート (2026-09-15)「同名タイトルが複数あると作成順の
  ///   先頭が選ばれ、 完全一致が無ければ部分一致で別のノードに当たる」。
  ///   線を引く / 書き換える / 消すのどれも、 当てずっぽうで別の物に当たると
  ///   後から気付けない。 2 件以上当たったら id を聞き返す。
  String? _ambiguous(String pageId, String key, String argName,
      {bool fuzzy = true}) {
    final hits = _provider.mcpMatchingNodeIds(pageId, key, fuzzy: fuzzy);
    if (hits.length < 2) return null;
    final index = {
      for (final e in _provider.mcpNodeIndex(pageId)) e['id']: e['title']
    };
    final titled = [
      for (final id in hits) {'id': id, 'title': index[id] ?? ''}
    ];
    return '"$argName": "$key" matches ${hits.length} nodes on this page, so '
        'picking one would be a guess. Pass the exact "id" instead: '
        '${jsonEncode(titled)}';
  }

  /// `aroundNodes` の 1 件ずつを「1 つに決まった id」 /「無い名前」 /
  /// 「候補が 2 件以上」 に分ける。
  ///
  /// ★ = 継続検証 377 / 381「囲む相手に同名や部分一致の候補が複数あっても、
  ///   黙って 1 件目だけを囲む」。 ただし `aroundNodes` は「1 つでも当たれば
  ///   囲む」 ための複数指定なので、 曖昧だった**その指定だけ**を落とし、
  ///   残りは活かす (全部落とすと、 まともな指定まで無駄になる)。
  /// ★ 物差しは mcpAddDecoration の中の引き当て (部分一致あり) と同じにする。
  ///   ずれると、 ここで通した名前が provider 側で別の物に当たる。
  ({List<String> ids, List<String> missed, List<Map<String, Object?>> amb})
      _aroundSplit(String pageId, List<String> keys) {
    final ids = <String>[];
    final missed = <String>[];
    final amb = <Map<String, Object?>>[];
    for (final k in keys) {
      if (_provider.mcpMatchingNodeIds(pageId, k).isEmpty) {
        missed.add(k);
        continue;
      }
      final why = _ambiguous(pageId, k, 'aroundNodes');
      if (why != null) {
        amb.add({'aroundNode': k, 'reason': why});
        continue;
      }
      final id = _provider.mcpResolveNodeId(pageId, k);
      if (id == null) {
        missed.add(k);
      } else if (!ids.contains(id)) {
        ids.add(id);
      }
    }
    return (ids: ids, missed: missed, amb: amb);
  }

  /// 相手が「改行」 を **文字 2 つ (`\` + `n`)** のまま送ってきた本文を直す。
  ///
  /// ★ = ユーザー報告「CLI に頼んでマークダウンを作らせたら、 本文が 1 行の
  ///   長文になり、 中に \n が字のまま並んで ### も見出しにならない」。
  ///   受け口の JSON-RPC は正しく読めているので、 これは相手 (AI / CLI) が
  ///   **二重にエスケープ**した物。 戻さないと、 マークダウンで**行頭でしか**
  ///   効かない記法 (見出し・箇条書き・表・コードフェンス) が全部死ぬ。
  ///
  /// 本文を壊さないための決め:
  ///   ・**本物の改行が 1 つでもあれば一切触らない**。 本当に \n と書きたい
  ///     場面 (コードフェンスの中、 「改行は \n と書く」 という説明) は
  ///     必ず前後に本物の改行を持つ。 逆に本物の改行が 0 なのに \n が並ぶ
  ///     本文は、 エスケープが解けていない以外に有り得ない。
  ///   ・インラインコード (backquote で囲んだ中) の \n は数えず、 戻さない。
  ///   ・バックスラッシュ 2 つ + n は「本当に \n と書きたい」 印と見て、
  ///     2 文字のまま残す。
  ///   ・[minHits] 個未満なら触らない (既定 2 = 本文。 題名のように短くて
  ///     \n を字として書く事がまず無い所は 1 で呼ぶ)。
  ///
  /// ★ パス・id・ファイル名には**決して通さない事**。 Windows のパス
  ///   (C:\new\note.txt) にはこの 2 文字が普通に入っているので壊れる。
  ///   通してよいのは「本文」 の欄だけ。
  static String _unescapeLiteralNewlines(String s, {int minHits = 2}) {
    if (s.isEmpty || s.contains('\n') || s.contains('\r')) return s;
    if (!s.contains(r'\n')) return s;
    // まずはインラインコードの外にある \n を数える。
    var hits = 0;
    var inCode = false;
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (c == '`') {
        inCode = !inCode;
      } else if (c == r'\' && i + 1 < s.length) {
        if (!inCode && s[i + 1] == 'n') hits++;
        i++; // 次の 1 文字は読み飛ばす (バックスラッシュ 2 つ + n を数えない)
      }
    }
    if (hits < minHits) return s;
    final out = StringBuffer();
    inCode = false;
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (c == '`') {
        inCode = !inCode;
        out.write(c);
        continue;
      }
      if (c != r'\' || i + 1 >= s.length) {
        out.write(c);
        continue;
      }
      final n = s[i + 1];
      if (inCode) {
        out.write(c);
        out.write(n);
      } else if (n == 'n') {
        out.write('\n');
      } else if (n == 't') {
        out.write('\t');
      } else if (n == 'r') {
        // \r\n は 1 つの改行に畳む。 単独の \r は 2 文字のまま残す。
        if (i + 3 < s.length && s[i + 2] == r'\' && s[i + 3] == 'n') {
          out.write('\n');
          i += 2;
        } else {
          out.write(c);
          out.write(n);
        }
      } else if (n == '"' || n == "'") {
        out.write(n);
      } else {
        // その他 (バックスラッシュ 2 つを含む) は 2 文字そのまま残す。
        out.write(c);
        out.write(n);
      }
      i++;
    }
    return out.toString();
  }

  /// 配列の引数を文字列の並びに直す (空文字は捨てる)。
  ///
  /// ★ = 動作検証 継続検証 238「append_document_text の配列形式だけ前後空白を
  ///   失う」。 採否を trim で決めるのはそのままだが、 **値まで** trim した物を
  ///   返していたので、 単一形式 (`text`) では残る字下げが配列形式 (`texts`)
  ///   では消えていた (内部の改行と空行は残るので、 空白落ちだけが起きる)。
  ///   本文を書く道具は [keepSpaces] を立てて**原文**を受け取る。
  ///   id / 題名のように前後の空白が邪魔な所は既定 (trim) のまま。
  /// ★ = 動作検証 継続検証 283「添付文書の複数段落作成で字下げと空の
  ///   段落が消える」。 本物のファイル (docx / txt / md / pdf) は空行を
  ///   書けるので、 [keepEmpty] を立てた呼び出しでは空白だけの要素も
  ///   **段落として**残す。 ページの本文 (空行を入れられない) は
  ///   既定のまま捨てる。
  static List<String> _stringList(Object? v,
      {bool keepSpaces = false, bool keepEmpty = false}) {
    if (v is! List) return const [];
    final out = <String>[];
    for (final e in v) {
      final s = '${e ?? ''}';
      // 空白だけの要素は今までどおり捨てる (この app は空行を入れられない)。
      if (!keepEmpty && s.trim().isEmpty) continue;
      out.add(keepSpaces ? s : s.trim());
    }
    return out;
  }

  /// 色の指定を 32bit ARGB に直す。 読めない値は null (= 既定色に倒す)。
  ///
  /// ★ 素通しだと事故になる (= 動作確認で判明):
  ///   ・`Color(int)` は各成分を 8bit に切り落とすので、 範囲外の値
  ///     (999999999999) が誰も頼んでいない色になっていた。
  ///   ・「赤 = 0xFF0000」 のような 6 桁 RGB は α=0 と解釈され、
  ///     ノードが透明で見えなくなっていた。 6 桁は不透明に直す。
  ///   ・文字列 ('#FF0000' や '"16711680"') は `as num?` が例外を投げ、
  ///     AI には意味の分からない型エラーだけが返っていた。
  static int? _argbOf(Object? v) {
    final int? n = v is num
        ? v.toInt()
        : (v is String
            ? int.tryParse(v.trim().replaceFirst('#', '0x'))
            : null);
    if (n == null) return null;
    if (n >= 0 && n <= 0xFFFFFF) return n | 0xFF000000; // 6 桁 RGB は不透明に
    if (n >= 0 && n <= 0xFFFFFFFF) return n;
    return null; // 範囲外は既定色
  }

  /// 色の指定を捨てた理由 (英語) を返す。 ちゃんと読めた時と、 そもそも
  /// 渡されていない時は null。
  ///
  /// ★ = 動作検証 継続検証 241「範囲外の色を無視した更新が『既に同じ値』 と
  ///   誤説明」。 [_argbOf] は範囲外 (-1 / 0x100000000) と読めない値を
  ///   どちらも null に倒すので、 provider へは「色は渡されていない」 と
  ///   しか伝わらない。 provider の ignored にも載らないため、
  ///   update_node が「every value passed already matched the node」 =
  ///   「指定値が現在色と一致していた」 と嘘の説明をしていた。 捨てた事と
  ///   理由はここでしか作れないので、 ここで作って ignored へ回す。
  static String? _argbIgnoreReason(Object? v) {
    if (v == null) return null; // 渡されていない (= 色は変えない)
    final int? n = v is num
        ? v.toInt()
        : (v is String
            ? int.tryParse(v.trim().replaceFirst('#', '0x'))
            : null);
    if (n == null) {
      return 'not a colour value - pass a number, or a hex string such as '
          '"0xFF4CAF50" / "#FF4CAF50". The colour was left exactly as it '
          'was.';
    }
    if (n < 0 || n > 0xFFFFFFFF) {
      return 'outside 0..0xFFFFFFFF, so it is not a 32bit ARGB colour '
          '(0xAARRGGBB). The colour was left exactly as it was - it was NOT '
          'already this value.';
    }
    return null; // 読めた (6 桁 RGB は _argbOf が不透明に直す)
  }

  /// 数の引数を読む。 文字列で来ても受ける。
  ///
  /// ★ `as num?` の素通しだと、 AI が "12" のように文字列で書いた時に
  ///   型エラーで落ちる。 20 個まとめて置く途中で落ちると、 作った分の
  ///   id すら返せない (= 動作確認で判明)。
  static double? _numOf(Object? v) => v is num
      ? v.toDouble()
      : (v is String ? double.tryParse(v.trim()) : null);

  /// 番号 / 個数の引数を読む。 整数でなければ理由 (英語) を返す。
  ///
  /// ★ = 動作検証レポート 不具合 3「整数であるべき引数が黙って切り捨てられ、
  ///   別の要素に当たる」。 `(a['x'] as num?)?.toInt()` は 0.9 を 0、
  ///   1.9 を 1、 -0.9 を 0 にするので、 AI が小数を書いた時に**隣の**
  ///   ノード / タブ / 行へ書き込んでおきながら成功と返していた。
  ///   丸めずに突き返す (= 丸めた番号は必ず別の物を指すため)。
  ///   文字列の "3" は受ける (= _numOf と同じ理由: AI は数を文字列で
  ///   書きがちで、 `as num?` だと意味の分からない型エラーで落ちる)。
  static ({int? value, String? error}) _intOf(
    Object? v,
    String name, {
    int min = 0,
    int? max,
  }) {
    if (v == null) return (value: null, error: null);
    final num? n =
        v is num ? v : (v is String ? num.tryParse(v.trim()) : null);
    // ★ 値を文面に入れる時は jsonEncode を使わない。 Infinity / NaN を
    //   渡されると jsonEncode 自身が例外を投げ、 道具の呼び出しごと落ちる
    //   (= 粗探しで発見。 実際に dart run で再現した)。
    final shown = v is String ? '"$v"' : '$v';
    if (n == null || (n is double && !n.isFinite)) {
      return (
        value: null,
        error: '"$name" must be a whole number - got $shown'
      );
    }
    if (n % 1 != 0) {
      return (
        value: null,
        error: '"$name" must be a WHOLE number, not $n. Fractions are '
            'rejected, never rounded - a rounded index would hit a '
            'different item.'
      );
    }
    // ★ 桁が大き過ぎる値は toInt() で頭打ちになり、 やはり**別の物**を
    //   指してしまう。 丸めと同じ理由で突き返す (= 粗探しで発見)。
    if (n.abs() > 9007199254740991) {
      return (
        value: null,
        error: '"$name" is too large to be a real index or count - got $shown'
      );
    }
    final i = n.toInt();
    if (i < min || (max != null && i > max)) {
      return (
        value: null,
        error: max == null
            ? '"$name" must be $min or greater - got $i'
            : '"$name" must be between $min and $max - got $i'
      );
    }
    return (value: i, error: null);
  }

  /// 配列でまとめて渡す道具の共通の入口。
  /// 「その鍵を渡したのに中身が空」 だった時だけ、 短い断り文を返す。
  /// 鍵そのものが無ければ null (= 1 件用の書き方なので、 そちらへ通す)。
  ///
  /// ★ = 動作検証レポート 不具合 5「空配列が 1 件用の道に落ちる」。
  ///   `batch is List && batch.isNotEmpty` は「渡されたが空」 を
  ///   「渡されていない」 と同じ扱いにするので、 中身の無い 1 件として
  ///   失敗し、 見当違いの理由 (「そんなノードは無い」) と、 そのページの
  ///   ノード一覧まで添えて返っていた。
  /// ★ ここではノードの一覧を**絶対に添えない**。 0 件は「名前が違う」 では
  ///   無いので、 選択肢を見せても直しようが無く、 返事の丈を食うだけ。
  /// [usable] は _stringList などで空白を捨てた後の件数。 渡すと
  ///   `["", "  "]` (空では無いが使える物が無い) も同じ道で断れる。
  Map<String, dynamic>? _emptyBatch(
    Map<String, dynamic> a,
    String key,
    String hint, {
    int? usable,
  }) {
    if (!a.containsKey(key)) return null;
    final v = a[key];
    if (v is! List) return null; // 配列以外は今までどおり 1 件用へ
    if ((usable ?? v.length) > 0) return null;
    return _err(v.isEmpty
        ? '"$key" was an empty array - 0 processed, nothing was changed. $hint'
        : '"$key" had ${v.length} entries but none were usable (every one was '
            'blank) - 0 processed, nothing was changed. $hint');
  }

  /// まとめて処理した道具の共通の戻り値。
  ///
  /// ★ = 動作検証レポート 改善案 4「数だけ返るので、 何がどうなったのか
  ///   AI が分からない」。「新しく出来た」「既にあって中身が変わった」
  ///   「既にその状態だった」「出来なかった」 を混ぜない。
  ///   要素の形は add_gallery_item の failed に揃える
  ///   ({index, 相手を指す鍵, reason?})。 三つ目の書き方を増やさない事。
  /// まとめて処理した結果の一覧を、 返事に収まる長さへ抑える上限。
  ///
  /// ★ = 動作検証 継続検証 86「1,001 件のギャラリー追加で、 作成 ID を
  ///   列挙した返却本文が約 122,000 文字になり、 呼び出し完了の確認に数分
  ///   かかった」。 件数と失敗理由は必ず返し、 1 件ずつの明細だけ端を残して
  ///   畳む (全部の id は read_page で引ける)。
  static const int kBatchDetailCap = 50;

  /// 長すぎる明細を「頭と尾だけ」 に畳む。 上限内なら素通し。
  static Object _capDetail(List<Map<String, Object?>> items) {
    if (items.length <= kBatchDetailCap) return items;
    const edge = 10;
    return {
      'count': items.length,
      'listed': edge * 2,
      'first': items.take(edge).toList(),
      'last': items.skip(items.length - edge).toList(),
      'note': 'the middle ${items.length - edge * 2} entries were left out to '
          'keep this reply short. Call read_page for the full list.',
    };
  }

  static Map<String, Object?> _batchResult({
    required List<Map<String, Object?>> created,
    List<Map<String, Object?>> updated = const [],
    List<Map<String, Object?>> unchanged = const [],
    List<Map<String, Object?>> failed = const [],
    Map<String, Object?> extra = const {},
  }) =>
      {
        // AI がそのまま利用者へ読み上げられる 1 行 (= 頼まれた数では無く、
        //   実際に変わった数を報告させるため)。
        // ★ 数を**先頭**に置く (= 明細が長い時に途中で切られても、 件数だけは
        //   必ず届くように。 read_page の件数と同じ考え方)。
        'summary': 'created ${created.length}, updated ${updated.length}, '
            'unchanged ${unchanged.length}, failed ${failed.length}',
        'createdCount': created.length,
        if (failed.isNotEmpty) 'failedCount': failed.length,
        ...extra,
        'created': _capDetail(created),
        if (updated.isNotEmpty) 'updated': _capDetail(updated),
        if (unchanged.isNotEmpty) 'unchanged': _capDetail(unchanged),
        if (failed.isNotEmpty) 'failed': _capDetail(failed),
      };

  /// 動画タイムラインへ足した直後の 1 件を読み返して、 **保存された**値を返す。
  ///
  /// ★ = 動作検証 継続検証 240「字幕の文字サイズが 6〜200 へ丸められるのに、
  ///   追加の返事は itemId だけで、 呼ぶ側は頼んだ大きさで入ったと信じる
  ///   (更新側は丸めた後の値を返している)」。 更新とそろえて、 保存された値を
  ///   そのまま返す。 丸めが起きた時は clamped も立てる。
  Future<Map<String, Object?>> _videoItemEcho(
      String pageId, String itemId, Map<String, dynamic> a) async {
    try {
      final r = await _provider.mcpListVideoEditorItems(pageId);
      final it = ((r?['items'] as List?) ?? const [])
          .whereType<Map>()
          .firstWhere((e) => '${e['itemId'] ?? ''}' == itemId,
              orElse: () => const <String, Object?>{});
      if (it.isEmpty) return const {};
      final asked = _numOf(a['fontSize']);
      final got = (it['fontSize'] as num?)?.toDouble();
      final clamped = asked != null && got != null && asked != got;
      return {
        if (it['layer'] != null) 'layer': it['layer'],
        if (it['startMs'] != null) 'startMs': it['startMs'],
        if (it['durationMs'] != null) 'durationMs': it['durationMs'],
        if (it['text'] != null) 'text': it['text'],
        if (it['fontSize'] != null) 'fontSize': it['fontSize'],
        if (it['color'] != null) 'color': it['color'],
        if (clamped) ...{
          'clamped': true,
          'clampedNote': 'fontSize $asked is outside the range this editor '
              'can draw (${MindMapProvider.kVideoCaptionMinFont} - '
              '${MindMapProvider.kVideoCaptionMaxFont}); $got was stored '
              'instead. Report the stored size, not the one you asked for.',
        },
      };
    } catch (_) {
      // 読み返せなくても追加そのものは成功しているので、 黙って id だけ返す。
      return const {};
    }
  }

  /// ツール実行 (HTTP 経由と、 アプリ内 AI チャット [MCP チャット] の両方
  /// から呼ばれる)。
  // ─── 自動操作の走りの控え ────────────────────────────────────────────
  //
  // ★ = 不具合報告 2026-09-30「run_automation の同時依頼が accepted を返して
  //   先行 runId を追跡不能にする」。 走りは 1 本だけしか覚えていなかったので、
  //   後から来た (そして断られた) 依頼が、 **まだ動いている走り**を控えから
  //   追い出していた。 その結果、 先の走りは状態確認も中止も出来なくなった。
  //   ここで新しい順に何本か覚えておき、 runId で必ず引けるようにする。
  static const int _kAutoRunKeep = 10;
  static final List<AutomationRunState> _autoRuns = <AutomationRunState>[];

  /// 今の走りを控えへ写す (同じ runId は最新の様子で上書き)。
  static void _rememberAutoRun() {
    final cur = automationRunForAssistant.value;
    if (cur == null) return;
    final at = _autoRuns.indexWhere((e) => e.runId == cur.runId);
    if (at >= 0) {
      _autoRuns[at] = cur;
    } else {
      _autoRuns.insert(0, cur);
      while (_autoRuns.length > _kAutoRunKeep) {
        _autoRuns.removeLast();
      }
    }
  }

  /// runId で引く (控えから)。
  static AutomationRunState? _autoRunById(String runId) {
    _rememberAutoRun();
    for (final r in _autoRuns) {
      if (r.runId == runId) return r;
    }
    return null;
  }

  /// 今**実行枠を握っている**走り (終わっていない物)。 無ければ null。
  ///
  /// ★ 最新の runId とは別物。 後から来た依頼が断られた時、 最新は
  ///   「断られた走り」 だが、 枠を握っているのは前の走りのままになる。
  static AutomationRunState? _autoRunBusy() {
    _rememberAutoRun();
    for (final r in _autoRuns) {
      if (!r.isFinished) return r;
    }
    return null;
  }

  /// 覚えている走りを「"番号" (様子)」 の並びで言う (エラー文へ添える)。
  static String _autoRunListText() {
    _rememberAutoRun();
    if (_autoRuns.isEmpty) return 'none';
    final parts = <String>[];
    for (final r in _autoRuns) {
      parts.add('"${r.runId}" (${r.phase})');
    }
    return parts.join(', ');
  }

  /// 枠の様子 (応答へ添える)。
  static Map<String, Object?> _autoSlotInfo() {
    final busy = _autoRunBusy();
    return {
      'busyRunId': busy?.runId,
      'workerState': busy == null
          ? 'idle'
          : (busy.isCancelling ? 'cancelling' : busy.phase),
      'knownRunIds': [for (final r in _autoRuns) r.runId],
    };
  }

  Future<Map<String, dynamic>> callTool(
      String name, Map<String, dynamic> a) async {
    double? numOf(String key) => _numOf(a[key]); // ★ 文字列の "12" も受ける
    // 整数の引数はここを通す。 1 つでも駄目なら、 何もせずに理由を返す
    // (= 半分だけ実行して「成功」 と返すのが一番たちが悪いため)。
    String? intErr;
    // ★ = 動作検証 継続検証 240「レーンの範囲エラーに『ミリ秒は整数』 という
    //   無関係な補足が付く」。 どの引数で転けたかも覚えて、 補足を足す側が
    //   時刻の引数だけに付けられるようにする。
    String? intErrKey;
    int? intOf(String key, {int min = 0, int? max}) {
      final r = _intOf(a[key], key, min: min, max: max);
      if (r.error != null) {
        intErr ??= r.error;
        intErrKey ??= key;
      }
      return r.value;
    }

    switch (name) {
      // ── パソコンの操作は自動操作へ委ねる (= ユーザー要望) ──
      case 'run_automation':
        {
          final text = (a['instruction'] as String? ?? '').trim();
          if (text.isEmpty) return _err('instruction is required');
          if (kIsWeb || !(Platform.isWindows || Platform.isMacOS ||
              Platform.isLinux)) {
            return _err('PC の操作はパソコン版だけです');
          }
          // ★ = 動作検証 継続検証 85 / 143「この app 自身を自動操作させると、
          //   3 手ほどで cancelled になり、 項目別の結果も返らない」。
          //   合成クリックでこのアプリ自身を触るのは対象外 (利用者の本物の
          //   ページを壊す恐れがある) なので、 始める前に理由を返す。
          //   画面の中の事は MCP の道具で直に出来るので、 そちらへ案内する。
          final selfWords = [
            'hisatornotebook',
            'hisator notebook',
            'カミスペ',
            'kamispec',
            'mokumoku',
            'このアプリ',
            'この app',
            '本アプリ',
            '自分自身',
          ];
          final lower = text.toLowerCase();
          if (selfWords.any(lower.contains)) {
            return _err('PC automation does not drive THIS app: clicking and '
                'typing into HisatorNotebook itself could change the user\'s '
                'real pages, so it is refused before anything runs. Nothing '
                'was started. Do it with the tools instead - run_app_command '
                '/ close_app_command open and close feature screens, '
                'set_split_view arranges panes, and read_page / list_pages '
                'report what is there. run_automation is for OTHER apps and '
                'web pages.');
          }
          // ★ = 動作検証の機能修正案。 走りに番号を付けてから渡す。
          //   番号を**先に**置くのが大事: 画面側は拾った直後に
          //   automationRunForAssistant を読んで走りを名乗る。 また、 パネルが
          //   まだ開いていない時は画面側が同じ文を何度も出し直すので
          //   (mind_map_screen の _onAssistantAutomationRequested)、 番号は
          //   その間も**同じまま**でなければならない。
          // ★ = 不具合報告 2026-09-30「同時依頼が accepted を返して先行
          //   runId を追跳不能にする」。 走れるのは 1 本だけなので、 枠が
          //   埋まっている間は**番号を作らずに**その場で断る。 前の走りの
          //   样子はそのまま残るので、 状態確認も中止も続けられる。
          final busy = _autoRunBusy();
          if (busy != null) {
            return _ok({
              'state': 'refused',
              'started': false,
              'busyRunId': busy.runId,
              'busyState': busy.phase,
              ..._autoSlotInfo(),
              'error': 'another automation run is still going - nothing was '
                  'started.',
              'note': 'Nothing was handed over and no new runId was made. '
                  'Poll get_automation_status with "${busy.runId}" until it '
                  'finishes, or stop it with cancel_automation '
                  '("${busy.runId}"). If it will not let go, '
                  'force_reset_automation frees the slot.',
            });
          }
          final runId = 'auto-'
              '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
          automationRunForAssistant.value = AutomationRunState(
            runId: runId,
            phase: 'accepted',
            instruction: text,
          );
          _rememberAutoRun();
          // 画面側 (自動操作パネル) がこの合図を拾って動かす。
          automationRequestFromAssistant.value = text;
          return _ok({
            'runId': runId,
            'state': 'accepted',
            'handedOver': text,
            'note': 'It has NOT run yet. Poll get_automation_status with this '
                'runId until "finished" is true, then report the real state. '
                'cancel_automation stops it. The panel obeys the user\'s '
                'permission setting, so it may ask for confirmation '
                '(state "awaitingUser") or refuse (state "refused").',
          });
        }
      // ── 自動操作の様子を訊く / 止める (= 動作検証の機能修正案) ──
      case 'get_automation_status':
        {
          final want = (a['runId'] as String? ?? '').trim();
          _rememberAutoRun();
          if (_autoRuns.isEmpty) {
            return _err('no PC automation has been started from here yet - '
                'call run_automation first.');
          }
          // 番号の指定が無ければ、 枠を握っている走り → 無ければ一番新しい物。
          final cur = want.isEmpty
              ? (_autoRunBusy() ?? _autoRuns.first)
              : _autoRunById(want);
          if (cur == null) {
            return _err('runId "$want" is not a run this app knows about. '
                'The runs it still remembers are: ${_autoRunListText()}. '
                'Ask for one of those, or start a new run.');
          }
          return _ok({
            ...cur.toJson(),
            ..._autoSlotInfo(),
          });
        }
      case 'cancel_automation':
        {
          final want = (a['runId'] as String? ?? '').trim();
          _rememberAutoRun();
          if (_autoRuns.isEmpty) {
            return _err('there is no PC automation to stop.');
          }
          // ★ 番号を省かれた時は「枠を握っている走り」を止める (最新の
          //   runId は、 断られた依頼の番号である事がある = 不具合報告)。
          final cur = want.isEmpty
              ? (_autoRunBusy() ?? _autoRuns.first)
              : _autoRunById(want);
          if (cur == null) {
            return _err('runId "$want" is not a run this app knows about. '
                'The runs it still remembers are: ${_autoRunListText()}.');
          }
          if (cur.isFinished) {
            return _ok({
              'cancelled': false,
              'runId': cur.runId,
              'state': cur.phase,
              'note': 'it had already finished - nothing was stopped.',
              ..._autoSlotInfo(),
            });
          }
          // 止めるのは自動操作の画面。 ここから直に OS を触らない
          //   (許可の仕組みを 1 箇所に集める = main.dart の注記のとおり)。
          automationCancelRequest.value = cur.runId;
          return _ok({
            'cancelled': true,
            'runId': cur.runId,
            'state': 'cancelling',
            'note': 'the stop was handed to the automation panel. Poll '
                'get_automation_status to see it reach "cancelled" - that is '
                'when the run slot is really free. If it stays '
                '"cancelling", call force_reset_automation.',
          });
        }
      // ★ = 不具合報告 2026-09-30「cancel 済みの長時間待機が実行枠を占有し
      //   続けて再停止もできない」。 枠だけを初期化する最後の手段。
      case 'force_reset_automation':
        {
          _rememberAutoRun();
          final before = _autoRunBusy();
          automationForceResetRequest.value =
              DateTime.now().millisecondsSinceEpoch;
          // 画面 (自動操作パネル) が拾って枠を手放すのを少し待つ。
          for (var i = 0; i < 12; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            _rememberAutoRun();
            if (_autoRunBusy() == null) break;
          }
          var freedBy = 'the automation panel';
          final still = _autoRunBusy();
          if (still != null) {
            // パネルが開いていない (listener が居ない) 時はここで終わりに
            //   する。 走っている物が無いのに枠だけ埋まって見える状態を
            //   残さない。
            automationRunForAssistant.value = still.copyWith(
              phase: 'cancelled',
              status: 'the run slot was reset from the assistant. The '
                  'automation panel did not answer, so nothing was running '
                  'any more.',
              finishedAtMs: DateTime.now().millisecondsSinceEpoch,
            );
            _rememberAutoRun();
            freedBy = 'the assistant (the panel did not answer)';
          }
          return _ok({
            'reset': true,
            'freedBy': freedBy,
            if (before != null) 'wasBusyWith': before.runId,
            if (before != null) 'wasState': before.phase,
            ..._autoSlotInfo(),
            'note': 'Only the running job was dropped. Saved steps, open '
                'pages and unsaved editing were not touched. A new '
                'run_automation can start now.',
          });
        }
      // ── 開発者モードの上限いじり (= ユーザー要望) ──
      case 'get_dev_limits':
      case 'set_dev_limits':
        {
          // 一覧に出していなくても名前さえ知っていれば呼べるので、 ここでも見る。
          if (!_provider.developerMode) {
            return _err('developer mode is off - these test limits can only '
                'be read or changed while developer mode is on.');
          }
          if (name == 'get_dev_limits') return _ok(_provider.mcpDevLimits());
          final uploadMb = numOf('uploadMb');
          final aiUsd = numOf('aiUsd');
          final aiCalls = intOf('aiCalls');
          if (intErr != null) return _err(intErr!);
          final err = await _provider.mcpSetDevLimits(
            uploadMb: uploadMb,
            aiUsd: aiUsd,
            aiCalls: aiCalls,
            resetUploadUsage: a['resetUploadUsage'] == true,
            resetAiUsage: a['resetAiUsage'] == true,
          );
          if (err != null) return _err(err);
          return _ok(_provider.mcpDevLimits());
        }
      // ── Jev (判断専用モデル) の入切 (= ユーザー要望: MCP が Jev に
      //    対応していない) ──
      case 'get_jev_settings':
        return _ok(_provider.mcpJevSettings());
      case 'set_jev_settings':
        {
          // ★ = 不具合報告 2026-09-30「知らない旗名を含む要求を原子的に
          //   拒否しない」 / 「未知キー単独時に原因と異なるエラーを返す」。
          //   原因はここ。 既知の鍵だけを拾って provider へ渡していたので、
          //   知らない鍵は**その手前で落ち**、 provider の検査 (未知の名前を
          //   断る) に届かなかった。 混ざっていれば既知の方だけが当たり、
          //   単独なら「何も指定されていない」 に化けていた。
          //   受けた鍵の全部をここで検分し、 1 つでも知らない物があれば
          //   既知の鍵も含めて**何も変えずに**断る。
          const wellKnown = {'stopAll', 'releaseStop'};
          final unknownKeys = [
            for (final k in a.keys)
              if (!MindMapProvider.kJevFeatureFlagKeys.containsKey(k) &&
                  !wellKnown.contains(k))
                k
          ];
          if (unknownKeys.isNotEmpty) {
            return _err('unknown Jev flag(s): ${unknownKeys.join(', ')}. The '
                'names are '
                '${MindMapProvider.kJevFeatureFlagKeys.keys.join(' / ')} '
                '(plus stopAll / releaseStop). Nothing was changed - not even '
                'the flags spelled correctly in the same call. Note that the '
                'Google-search ad hider ("adBlockCssStage") is NOT a Jev flag: '
                'it is switched inside the Google search screen.');
          }
          // ★ 旗を文字列 ("true") で渡された時に**黙って無視しない**。
          //   無視すると「入れました」 と答えたのに何も変わっていない、
          //   という一番たちの悪い形になる。
          //   `"true"` / `"false"` は受け取り、 それ以外の文字列は断る
          //   (同梱文書もこの通りに直してある)。
          String? boolErr;
          bool? boolOf(String key) {
            final v = a[key];
            if (v == null) return null;
            if (v is bool) return v;
            final s = '$v'.trim().toLowerCase();
            if (s == 'true') return true;
            if (s == 'false') return false;
            boolErr ??= '$key must be true or false';
            return null;
          }

          final feats = <String, bool>{};
          for (final k in MindMapProvider.kJevFeatureFlagKeys.keys) {
            final v = boolOf(k);
            if (v != null) feats[k] = v;
          }
          final stopAll = boolOf('stopAll');
          final release = boolOf('releaseStop') ?? false;
          if (boolErr != null) return _err(boolErr!);
          final r = await _provider.mcpSetJevSettings(
            feats,
            stopAll: stopAll,
            releaseStop: release,
          );
          final why = r['error'];
          if (why is String) return _err(why);
          return _ok(r);
        }
      case 'list_pages':
        {
          // いちばん上に開いているファイル (= ユーザー要望: 場所を明示され
          //   ない指示は、 マップではなくこれを相手にする)。
          final fd = _provider.frontDocument;
          // ★ = 調査報告 BUG-20「本文やタイムラインがあっても nodeCount が 0
          //   になり、 空ページに見える」。 本文はページ JSON の外にあるので
          //   nodeCount では数えられない。 種別ごとの中身の量を足して返す。
          final pages = _provider.mcpListPages();
          for (final pg in pages) {
            final t = '${pg['type'] ?? ''}';
            if (t == 'normal' || t == 'bookshelf') continue;
            final st = await _provider.mcpPageContentStats('${pg['id']}');
            pg.addAll(st);
          }
          return _ok({
            'pages': pages,
            // ★ = 動作検証レポート 2026-09-25 不具合 1。 「無指定の指示は
            //   何が相手か」 を 1 か所で返す。 openFileOnTop は互換のため
            //   残してある (中身は同じ判断から作られる)。
            'foregroundContext': _provider.mcpForegroundContext(),
            if (fd != null)
              'openFileOnTop': {
                'name': fd.name,
                'kind': fd.kind,
                'path': fd.path,
                'note': 'The user is looking at this FILE, opened on top of '
                    'the map. An instruction that does not name a target '
                    'means THIS FILE, not the map page. If you have no tool '
                    'for this file kind, say so and tell the user to use the '
                    'AI button inside that editor - do NOT edit the map '
                    'instead.',
              },
          });
        }
      case 'undo_page':
        {
          // ★ = 動作検証レポート 2026-09-25 不具合 11「Undo が非同期・
          //   対象不明確で応答後の状態を保証しない」。 ページを決めて、
          //   保存まで待ってから返す。
          final upid = _pageIdOrCurrent(a['pageId']);
          final upage = _provider.mcpPageById(upid);
          if (upage == null) {
            return _err(_noPageMsg(upid));
          }
          if (!_provider.canUndoPage(upid)) {
            return _err('no_history: ' +
                jsonEncode({
                  'code': 'no_history',
                  'pageId': upid,
                  'pageType': upage.pageType,
                  'note': 'nothing to undo for this page. paint / document / '
                      'videoEditor pages keep their history inside the editor '
                      'window, so it cannot be undone from here - ask the '
                      'user to press Ctrl+Z in that editor.',
                }));
          }
          // ★ = 継続検証 230 前半「生成ファイル付き添付の削除を取り消すと
          //   壊れたタイルだけ戻る」。 タイルと一緒に実体も戻す。 戻せなかった
          //   物は黙って成功扱いにせず、 ごみ箱から戻してもらうよう言わせる。
          final undoOut = <String, Object?>{};
          final undone =
              await _provider.mcpUndoPage(upid, outcome: undoOut);
          if (!undone) {
            return _err('no_history: ' +
                jsonEncode({'code': 'no_history', 'pageId': upid}));
          }
          final unrestored = undoOut['filesNotRestored'];
          return _ok({
            'undone': true,
            'pageId': upid,
            'pageName': upage.name,
            'nodeCount': upage.nodes.length,
            'connectionCount': upage.connections.length,
            'canUndoMore': _provider.canUndoPage(upid),
            if (undoOut['filesRestored'] != null)
              'filesRestored': undoOut['filesRestored'],
            if (unrestored != null) 'filesNotRestored': unrestored,
            if (unrestored != null)
              'fileWarning': 'the tiles are back but the files listed in '
                  '"filesNotRestored" could NOT be put back: they are still '
                  'in the recycle bin, so those tiles will not open. Tell the '
                  'user which file it is and that they have to restore it '
                  'from the recycle bin - do NOT say the undo fully '
                  'succeeded.',
          });
        }
      case 'search_pages':
        {
          final q = '${a['query'] ?? ''}'.trim();
          if (q.isEmpty) return _err('query is required');
          // ★ = 継続検証 142「不正な検索範囲を最も広い all として実行する」。
          //   綴り間違いで範囲が最小から最大へ広がり、 別のフォルダーの中身
          //   まで結果へ混ざっていた。 知らない値は断る。 大小文字だけの
          //   違いは正しい綴りへ均す (範囲は広げない)。
          const scopes = {'all', 'folder', 'page'};
          final rawScope = '${a['scope'] ?? ''}'.trim();
          final scope = rawScope.isEmpty
              ? 'all'
              : scopes.firstWhere(
                  (s) => s == rawScope.toLowerCase(),
                  orElse: () => '',
                );
          if (scope.isEmpty) {
            return _err('"scope" must be one of page / folder / all - got '
                '"$rawScope". Nothing was searched (a typo must not silently '
                'widen the search to every page).');
          }
          // ★ = 継続検証 139「件数の 0・負数・小数を黙って 1 件へ補正する」。
          //   丸めると「0 件だけ欲しい」 も正常な 1 件検索に見える。
          final maxHitsR = _intOf(a['maxHits'], 'maxHits', min: 1, max: 40);
          if (maxHitsR.error != null) return _err(maxHitsR.error!);
          final maxHits = maxHitsR.value ?? 12;
          final r = await _provider.mcpSearchNodes(
            q,
            scope: scope,
            maxHits: maxHits,
          );
          return _ok({
            'query': q,
            'scope': scope,
            'verdict': r.verdict,
            'hits': r.hits,
            // ★ = 継続検証 105「結果が上限で省略されたことを判別できない」。
            //   総数と打ち切りを返す (5 件しか無いのか、 30 件のうち 5 件
            //   なのかを応答から見分けられるように)。
            'totalMatches': r.totalMatches,
            'returned': r.hits.length,
            'maxHits': maxHits,
            'truncated': r.truncated,
            if (r.truncated)
              'truncatedNote': 'only ${r.hits.length} of ${r.totalMatches} '
                  'matches are listed (maxHits). Raise "maxHits" (up to 40) '
                  'or narrow the query - do NOT tell the user this is every '
                  'match.',
            // ★ = 継続検証 357 / 358 / 409。 隠れた本文の当たりがある時だけ、
            //   読み方を**全体へ 1 つ**添える (1 件ごとに同じ文を入れると
            //   search_pages の 6000 字の打ち切りに当たる)。
            if (r.hits.any((h) => h['hiddenInPageType'] != null))
              'hiddenNote': 'a hit with "hiddenInPageType" is text that page '
                  'still holds for ANOTHER page kind: it is really there, but '
                  'the page is not that kind now, so it is NOT on screen until '
                  'set_page_type switches it back. Say that - never claim the '
                  'user can see it, and do not say it was lost.',
            if (r.unsearched.isNotEmpty) 'unsearchedPages': r.unsearched,
            // ★ = 点検で判明 (動作検証の不具合「見つかったのに見つからない
            //   寄りの返事になる」 の残り)。 「探したけど無い (absent)」 と
            //   「見られなかった所がある (unknown)」 を同じ文で済ませると、
            //   読めていないページがあるのに AI が探すのをやめてしまう。
            if (r.hits.isEmpty && r.verdict == 'absent')
              'note': 'nothing matched. Do NOT fall back to reading pages one '
                  'by one - tell the user it was not found, or ask for a '
                  'different word.',
            if (r.hits.isEmpty && r.verdict != 'absent')
              'note': 'NOT found is not proven: the pages in '
                  '"unsearchedPages" keep their body outside the page data '
                  'and could not be searched here. Open them with '
                  'read_markdown / read_document / read_paint_items / '
                  'list_video_editor_items, or ask the user.',
          });
        }
      case 'search_folder_files':
        {
          final q = '${a['query'] ?? ''}'.trim();
          if (q.isEmpty) return _err('query is required');
          final fid = '${a['folderId'] ?? ''}'.trim();
          // ★ = 継続検証 286 / 392。 無いフォルダーの id を渡しても探した
          //   ふりをして absent が返っていたので、 打ち間違いと「本当に
          //   無い」 が見分けられなかった。 探す前に断る (言い方は
          //   move_page_to_folder に揃える)。
          if (fid.isNotEmpty &&
              !_provider.mcpListFolders().any((f) => f['id'] == fid)) {
            return _err('folder_not_found: no folder has the id "$fid" - call '
                'list_folders. Nothing was searched. Omit "folderId" to '
                'search every folder.');
          }
          final maxHits =
              ((a['maxHits'] as num?)?.toInt() ?? 8).clamp(1, 20);
          final r = await _provider.mcpSearchFolderFiles(
            q,
            folderId: fid.isEmpty ? null : fid,
            maxHits: maxHits,
          );
          return _ok({
            'query': q,
            if (fid.isNotEmpty) 'folderId': fid,
            // ★ 省いた時に何を見たのかを返す (= 継続検証 274: 「全フォルダー」
            //   と説明しながら一覧の直下だけを見ていた頃と区別が付くように)。
            if (fid.isEmpty)
              'searched': 'every folder, plus the pages outside any folder',
            'verdict': r.verdict,
            'hits': r.hits,
            if (r.hits.isEmpty && r.verdict == 'absent')
              'note': 'nothing matched in the files. Read a file with '
                  'read_device_file only if you have a concrete path.',
            if (r.hits.isEmpty && r.verdict != 'absent')
              'note': 'NOT found is not proven: this call ran out of time or '
                  'hit its file cap, so some files were left unread. Narrow '
                  'it down with "folderId" (list_folders) and search again, '
                  'or ask the user where the file is.',
          });
        }
      case 'read_page':
        {
          // pageId を省いたら今開いているページ (= ユーザー要望: 開いた
          // ページの中から探すのに、 一覧を引く 1 手を挟ませない)。
          final pid = _pageIdOrCurrent(a['pageId']);
          final json = _provider.mcpReadPage(pid);
          if (json == null) {
            return _err(_noPageMsg(pid));
          }
          // ★ = 動作検証レポート 2026-09-25 不具合 6。 添付の道筋だけは
          //   保存された文字がそのまま入っているので、 返す時に区切りを
          //   揃える (保存側は触らない。 あちらは本物のデータ)。
          _normalizeAttachmentPaths(json);
          // ★ 件数を先頭に置く (= 動作確認で判明: ページの JSON は 5 ノード
          //   でも 3000 文字を超えるので、 長い時に途中で切られると
          //   connections まで届かない。 数だけでも必ず届くようにする)。
          final page = _provider.mcpPageById(pid);
          return _ok({
            'nodeCount': page?.nodes.length ?? 0,
            'connectionCount': page?.connections.length ?? 0,
            // ★ = 継続検証 201。 マップ以外の種別でも裏のマップ層は読めるので、
            //   nodeCount だけ見て「画面に出ている」 と思わせない。
            if (page != null &&
                page.pageType != 'normal' &&
                page.pageType != 'bookshelf' &&
                page.nodes.isNotEmpty)
              'nodeVisibility': 'this is a "${page.pageType}" page, so the '
                  '${page.nodes.length} node(s) reported here live on the '
                  'page\'s hidden mind-map layer and are NOT drawn on that '
                  'screen. To read what the user actually sees, call '
                  '${_contentReaderFor(page.pageType)}.',
            // ★ = 不具合報告 2026-09-30「automation ページの read_page が
            //   必ず失敗する read_document を案内する」。 手順はページ JSON の
            //   外にあるので、 裏のマップ層が空 (nodeCount 0) でも読み方を
            //   必ず添える (以前は行き止まりの read_document を案内していた)。
            if (page != null && page.pageType == 'automation')
              'contentNote': 'this is an automation ("自動操作") page. The '
                  'steps the user sees are NOT in this page JSON - call '
                  'read_automation_page for them. read_document cannot open '
                  'this kind of page at all.',
            // ★ 壊れた添付も先頭へ (件数と同じ理由: 長いページでは後ろが
            //   切られ、 要素ごとの印まで届かない)。
            if (json['brokenAttachments'] != null)
              'brokenAttachments': json['brokenAttachments'],
            if (json['brokenBackground'] != null)
              'brokenBackground': json['brokenBackground'],
            ...json,
          });
        }
      // ★ = 不具合報告 2026-09-30。 automation ページの手順を読む道。
      case 'read_automation_page':
        {
          final pid = _pageIdOrCurrent(a['pageId']);
          final r = await _provider.mcpReadAutomationPage(pid);
          final err = r['error'];
          return err == null ? _ok(r) : _err('$err');
        }
      case 'delete_page':
        {
          final id = a['pageId'] as String? ?? '';
          // ★ = 継続検証 95「添付を持つページを消すとファイルが孤立する」。
          //   delete_node と同じ言い方で、 ファイルもごみ箱へ送れるようにする
          //   (既定は今までどおり「ページだけ」)。
          final pgDispose = () {
            final v = '${a['deleteFile'] ?? 'no'}'.trim().toLowerCase();
            return const {'no', 'generated', 'yes'}.contains(v) ? v : 'no';
          }();
          // 消す前に、 孤立しそうな添付の数を数えておく (案内のため)。
          final willOrphan = pgDispose == 'no'
              ? (_provider.mcpPageById(id)?.nodes.values
                      .where((n) => (n.attachmentPath ?? '').isNotEmpty)
                      .length ??
                  0)
              : 0;
          final files = <Map<String, Object?>>[];
          final reason = await _provider.mcpDeletePage(id,
              disposeFiles: pgDispose, disposed: files);
          if (reason != null) return _err(reason);
          return _ok({
            'deleted': id,
            if (files.isNotEmpty) 'files': files,
            if (willOrphan > 0)
              'orphanNote': 'the page held $willOrphan attached file(s). They '
                  'were LEFT ON DISK and now belong to no tile - call '
                  'list_orphan_files to show them to the user, or pass '
                  'deleteFile:"generated" next time to send files this app '
                  'made to the recycle bin along with the page.',
          });
        }
      case 'set_page_type':
        {
          final id = a['pageId'] as String? ?? '';
          final type = a['type'] as String? ?? '';
          // ★ = 動作検証 2026-09-28「ページ種別の往復で要素寸法が変わる」。
          //   ギャラリーから戻した時に、 何枚の寸法を返せて、 何枚は
          //   控えが無くてそのままにしたのかを返す (黙って均さない)。
          final typeOut = <String, Object?>{};
          final ok = await _provider.mcpSetPageType(id, type,
              outcome: typeOut);
          if (ok) {
            final restored = (typeOut['restoredSizes'] as int?) ?? 0;
            final kept = (typeOut['keptGallerySize'] as int?) ?? 0;
            final movedBack = (typeOut['restoredPositions'] as int?) ?? 0;
            if (restored == 0 && kept == 0 && movedBack == 0) {
              return _ok('page $id is now "$type"');
            }
            return _ok({
              'pageId': id,
              'type': type,
              if (restored > 0) 'restoredSizes': restored,
              if (kept > 0) 'keptGallerySize': kept,
              if (movedBack > 0) 'restoredPositions': movedBack,
              'note': [
                'page $id is now "$type".',
                if (restored > 0)
                  '$restored tile(s) went back to the exact size they had '
                      'before the page was laid out as a gallery.',
                if (movedBack > 0)
                  '$movedBack tile(s) also went back to the exact x/y they had '
                      'before the gallery grid, so shapes drawn around them '
                      'line up again.',
                if (kept > 0)
                  '$kept tile(s) kept their gallery size because no '
                      'pre-gallery size was ever recorded for them (the page '
                      'was already a gallery before this app started keeping '
                      'that note); only their fixed height was released. Tell '
                      'the user rather than claiming everything was restored.',
              ].join(' '),
            });
          }
          // 知らない id と知らない種別を区別する (= 前は id が違っても
          //   「その種類はありません」 と返り、 原因を取り違えていた)。
          if (_provider.mcpPageById(id) == null) {
            return _err('no page has the id "$id" - call list_pages and use '
                'an id from it.');
          }
          // ★ = 不具合報告 2026-09-30。 automation は本物の種別 (画面の ＋
          //   メニューで作れる) なので、 「無い」 とは言わない。
          //   制約の所在 (種別変更だけが未対応) をそのまま伝える。
          if (type.trim().toLowerCase() == 'automation') {
            return _err('automation ("自動操作") IS a real page kind, but '
                'set_page_type cannot convert a page into it (or out of it) - '
                'only create_page can make one, and the user can add one from '
                'the + menu in the page list. Nothing was changed.');
          }
          return _err('"$type" is not a page kind. The app has only these: '
              'normal, bookshelf, paint, document, markdown'
              '${kStoreBuild ? '' : ', videoEditor'}, automation. If '
              'the user asked for something else, tell them it does not exist '
              '- do not substitute. (automation pages can be created, but '
              'set_page_type cannot convert to or from that kind.)');
        }
      case 'clear_chat_history':
        return _provider.mcpClearChat()
            ? _ok('chat history cleared')
            : _err('the chat view is not available right now');
      case 'set_header_buttons':
        {
          final raw = (a['ids'] as List?) ?? const [];
          final ids = raw.map((e) => '$e').toList();
          // ★ 「置けなかった id」 を返す (= ユーザー報告: 存在しない機能を
          //   頼まれた時に、 付けたと嘘をつく)。 黙って捨てると AI からは
          //   成功と区別が付かない。
          final r = await _provider.mcpSetHeaderButtons(ids,
              replace: a['replace'] == true);
          return _ok(r);
        }
      case 'create_page':
        final wantFolder = '${a['folderId'] ?? ''}'.trim();
        // ★ = 継続検証 138 / 144。 断った本当の理由を 1 つだけ返す
        //   (以前は「フォルダーが無い / Pro が要る / 上限」 を並べていたので、
        //   何を直せばよいか分からなかった)。 知らない種類も黙って normal に
        //   すり替えず、 理由を返す。
        final cpOut = <String, Object?>{};
        final id = _provider.mcpCreatePage(
            type: a['type'] as String? ?? 'normal',
            name: a['name'] as String?,
            folderId: wantFolder.isEmpty ? null : wantFolder,
            // ★ 新規はフォルダーの外には作らない (= ユーザー要望)。
            //   外は古いデータのための場所なので、 toRoot は受けない。
            toRoot: false,
            outcome: cpOut);
        // 実際に出来た種類を返す (= ユーザー報告: 知らない種類を頼まれると
        //   黙って normal を作り、 頼まれた通りに作ったと答えてしまう)。
        return id == null
            ? _err(() {
                switch ('${cpOut['reason'] ?? ''}') {
                  case 'folder_not_found':
                    return 'folder_not_found: "$wantFolder" is not a real '
                        'folder id - call list_folders. No page was created '
                        '(it was NOT put somewhere else instead).';
                  case 'unknown_type':
                    return '"${a['type']}" is not a page kind. The app has '
                        'only these: normal, bookshelf, paint, document, '
                        'markdown, automation'
                        '${kStoreBuild ? '' : ', videoEditor'} '
                        '(spelled exactly like that). No page was created - '
                        'tell the user rather than substituting another kind.';
                  // ★ = 不具合報告 2026-09-30。 作れない理由をことごとく
                  //   言う (以前は「そんな種別はない」 と返していたので、
                  //   画面では作れる事実と矛盾していた)。
                  case 'automation_unavailable':
                    return 'automation ("自動操作") pages need the desktop '
                        'app and a Pro (or higher) plan, so none was created. '
                        'The kind itself exists - this build or plan just '
                        'cannot hold one.';
                  case 'store_build_no_video_editor':
                    return 'the video editor is not available in this build of '
                        'the app, so no page was created.';
                  case 'plan_or_quota':
                    return 'the current plan cannot add another '
                        '"${a['type'] ?? 'normal'}" page (a free note needs '
                        'Pro, and the free plan caps how many pages of each '
                        'kind there can be). No page was created.';
                  case 'would_be_locked_by_plan':
                    return 'a new page would be past the '
                        '${MindMapProvider.kFreeOpenPageLimit}-page limit of '
                        'this plan, so it would be created but not openable. '
                        'No page was created.';
                }
                return 'could not create a "${a['type'] ?? 'normal'}" page. '
                    'No page was created.';
              }())
            : _ok(() {
                // 実際にどこへ入ったかも返す (= 検証レポート: 作成直後に
                // 格納先を確認できない)。
                final page = _provider.mcpPageById(id);
                final fid = page?.folderId;
                return {
                  'pageId': id,
                  'type': page?.pageType ?? 'normal',
                  'name': page?.name ?? '',
                  'folderId': fid,
                  'folderName': fid == null
                      ? null
                      : _provider.folders
                          .where((f) => f.id == fid)
                          .map((f) => f.name)
                          .firstOrNull,
                };
              }());
      case 'add_node':
        {
          final pageId = a['pageId'] as String? ?? '';
          // 1 件ずつ呼ぶ形だけだと AI が途中で取りこぼす (4 個頼んで 1 個しか
          // 置かれなかった)。 まとめて置ける形も持たせる。
          // ★ 棚 (ギャラリー) に add_node は使えない (= 動作確認で判明:
          //   種別を見ていないので、 棚のページにも普通のノードが出来て
          //   しまい、 棚に並ばず線も描かれない物が残っていた)。
          final target = _provider.mcpPageById(pageId);
          if (target != null && target.pageType == 'bookshelf') {
            return _err('"$pageId" is a gallery (bookshelf) page: use '
                'add_gallery_item (its "texts" array) instead. A gallery has '
                'no parent/child lines, so if the user wants them connected, '
                'offer to convert the page with set_page_type "normal".');
          }
          // ★ 空配列で呼ばれた時に何も作らない (= 動作確認で判明: 「0 個
          //   追加して」 で空配列を投げると 1 件用の道に落ちて、 無題の
          //   ノードが 1 個出来たうえに成功として返っていた)。
          //   同じ落とし穴が他の道具にも残っていたので _emptyBatch へ寄せた
          //   (= 動作検証レポート 不具合 5)。
          final addEmpty = _emptyBatch(a, 'nodes',
              'If there is nothing to add, do not call add_node at all.');
          if (addEmpty != null) return addEmpty;
          final batch = a['nodes'];
          if (batch is List && batch.isNotEmpty) {
            // ★ = 動作検証の不具合「一括追加した要素を直後に取り消せない」。
            //   控えを 1 枚だけ積んで、 中の 1 件ずつの push は止める
            //   (止めないと 200 件で 200 回の取り消しが必要になる)。
            // ★ 点検で判明: 何も作れない呼び出し (全部空の配列など) でも
            //   控えを積んでいたため、 「消したページを戻す」 の 1 発枠と
            //   やり直し (redo) が消えていた。 **最初に本当に作る時**だけ積む。
            var undoPushed = false;
            void pushUndoOnce() {
              if (undoPushed) return;
              undoPushed = true;
              _provider.mcpPushUndo(pageId);
              _provider.beginUndoBatch(snapshot: false);
            }

            try {
            final ids = <String>[];
            // 入力の並びと 1 対 1 で対応させる控え。 ★ 使えない要素を飛ばすと
            //   ids がずれ、 以降の parentIndex が 1 つ手前のノードに繋がって
            //   いた (= 動作確認で判明)。
            final slots = <String>[];
            // ★ = 継続検証 124「無効な項目が黙って省略される」。 入力配列の
            //   どの位置が、 なぜ作られなかったのかを返す (件数だけだと
            //   呼ぶ側は全件作られたと信じる)。
            final failed = <Map<String, Object?>>[];
            // 親に繋げなかった物 (= 繋がっていないのに「親子で作った」 と
            //   報告してしまうのを防ぐ)。
            // ★ = 継続検証 131「題名だけで報告するので、 同名が 2 つあると
            //   どちらを繋ぎ直せばよいか分からない」。 入力位置・作った id・
            //   指した親・理由を組で返す。
            final unlinked = <Map<String, Object?>>[];
            // ★ = 継続検証 376「親を題名で指した時、 応答にどの要素へ
            //   繋いだのかが出ない」。 題名で指せる以上、 呼ぶ側が「実際に
            //   選ばれた id」 を応答から確かめられないといけない。
            final linked = <Map<String, Object?>>[];
            // ★ = 継続検証 230「add_node の危険 URL が黙って通常要素になる」。
            //   開けない方式 (javascript: / data: / file: など) をリンクに
            //   しなかった事を、 update_node と同じ ignored で返す
            //   (件数だけだと呼ぶ側は「全部リンクになった」 と信じる)。
            final urlIgnored = <Map<String, Object?>>[];
            // 座標を言われていない物 (= 自動で並べる相手)。
            final auto = <String>[];
            for (var bi = 0; bi < batch.length; bi++) {
              final e = batch[bi];
              final Map<String, dynamic> m;
              if (e is Map) {
                m = e.cast<String, dynamic>();
              } else {
                // 題名だけを並べた形 (["春","夏"]) も受ける。 同じファイルの
                //   add_gallery_item / add_paint_text の texts と揃えた。
                final s = '${e ?? ''}'.trim();
                if (s.isEmpty) {
                  slots.add('');
                  failed.add({
                    'index': bi,
                    'reason': 'the entry was blank (a node needs a real '
                        '"title", "memo" or "url")',
                  });
                  continue;
                }
                m = <String, dynamic>{'title': s};
              }
              // 中身の無い要素で無題ノードを作らない。
              // ★ 鍵ではなく中身で見る (= 検証レポート: {"title":"   "} が
              //   素通りしていた。 ["   "] は上で既に弾いている)。
              if (!_hasContent(m['title']) &&
                  !_hasContent(m['memo']) &&
                  !_hasContent(m['url'])) {
                slots.add('');
                failed.add({
                  'index': bi,
                  'title': '${m['title'] ?? ''}',
                  'reason': '"title", "memo" and "url" were all empty or '
                      'whitespace-only - no node was created for this entry',
                });
                continue;
              }
              // ★ = 継続検証 230。 URL しか中身が無い項目は**作らない**
              //   (作ると、 開けない文字列がメモに入っただけの普通の要素が
              //   残り、 それでも created に数えられていた)。
              final rawUrl = m['url'] == null ? '' : '${m['url']}'.trim();
              final badUrl =
                  rawUrl.isNotEmpty && !MindMapProvider.mcpIsUsableLink(rawUrl);
              if (badUrl &&
                  !_hasContent(m['title']) &&
                  !_hasContent(m['memo'])) {
                slots.add('');
                failed.add({
                  'index': bi,
                  'url': rawUrl,
                  'reason': 'unsupported_scheme: only http(s) links can be '
                      'opened from a node, and this entry had no "title" or '
                      '"memo" either - no node was created for it. Put the '
                      'address in "memo" if you want it kept as plain text.',
                });
                continue;
              }
              pushUndoOnce();
              final entryOut = <String, Object?>{};
              final id = _provider.mcpAddNode(
                pageId,
                // ★ 題名は説明文で「\n で 2 行目になる」 と案内しているので、
                //   文字 2 つのまま届きやすい。 短い札で \n を字として書く事は
                //   まず無いので 1 個から戻す。
                title:
                    _unescapeLiteralNewlines('${m['title'] ?? ''}', minHits: 1),
                x: _numOf(m['x']),
                y: _numOf(m['y']),
                // 文字列以外が来ても途中で例外にしない (= 200 個の途中で
                //   落ちると、 作った分の一覧すら返せなくなる)。
                memo: m['memo'] == null
                    ? null
                    : _unescapeLiteralNewlines('${m['memo']}'),
                url: m['url'] == null ? null : '${m['url']}',
                colorValue: _argbOf(m['color']),
                outcome: entryOut,
              );
              if (id == null) {
                failed.add({
                  'index': bi,
                  'title': '${m['title'] ?? ''}',
                  'reason': 'the app refused this node (the page may be '
                      'locked or gone)',
                });
                slots.add('');
                continue;
              }
              ids.add(id);
              slots.add(id);
              // ★ = 継続検証 230。 リンクにしなかった URL は、 どの項目の
              //   どの住所がなぜ駄目だったのかを必ず添える。
              if (entryOut['requestedUrl'] != null) {
                urlIgnored.add({
                  'index': bi,
                  'nodeId': id,
                  'title': '${m['title'] ?? ''}',
                  'field': 'url',
                  'requestedUrl': entryOut['requestedUrl'],
                  'storedAs': entryOut['storedAs'],
                  'reason': entryOut['reason'],
                });
              }
              // 座標を言われていない物だけ、 後でまとめて並べる。
              if (_numOf(m['x']) == null && _numOf(m['y']) == null) {
                auto.add(id);
              }
              // 親が指定されていればその場で繋ぐ。 parentIndex はこの呼び出しの
              // 中で先に作ったノードの番号 (0 始まり)。
              var parent = '${m['parentId'] ?? ''}'.trim();
              void cannotLink(String why, {Object? parentRef}) =>
                  unlinked.add({
                    'index': bi,
                    'nodeId': id,
                    'title': '${m['title'] ?? ''}',
                    if (parentRef != null) 'parent': parentRef,
                    'reason': why,
                  });
              // ★ = 継続検証 111「存在しない親名が部分一致した要素へ誤接続
              //   される」。 説明では完全一致だけと約束しているのに、 繋ぐ側
              //   (mcpConnectNodes) は部分一致で引き当てるので、
              //   「存在しない親」 が既存の「親」 へ繋がっていた。
              //   ここで**先に**完全一致で引き当て、 当たらなければ繋がない。
              if (parent.isNotEmpty) {
                // ★ = 継続検証 376「同名の親が 2 件あると、 作成順の 1 件目へ
                //   無警告で繋いでしまう」。 完全一致でも題名は重なるので、
                //   1 つに決まらない時は繋がずに候補 id を返す
                //   (connect_nodes / update_node / delete_node と同じ物差し)。
                final pAmb =
                    _ambiguous(pageId, parent, 'parentId', fuzzy: false);
                if (pAmb != null) {
                  cannotLink(pAmb, parentRef: parent);
                  parent = '';
                } else {
                  final exact =
                      _provider.mcpResolveNodeId(pageId, parent, fuzzy: false);
                  if (exact == null) {
                    cannotLink(
                        'no node on this page has exactly that id or title - '
                        '"parentId" does NOT accept partial matches (guessing '
                        'would attach the child to the wrong parent)',
                        parentRef: parent);
                    parent = '';
                  } else {
                    parent = exact;
                  }
                }
              }
              // ★ 番号は整数だけ (= 動作検証レポート 不具合 3: 0.9 を 0 に
              //   丸めていたので、 頼まれたのとは**別の**ノードへ繋いで
              //   おきながら成功と返していた)。 丸めずに「繋げなかった」 へ。
              final piR = _intOf(m['parentIndex'], 'parentIndex');
              final pi = piR.value;
              if (parent.isEmpty && piR.error != null) {
                cannotLink(piR.error!, parentRef: m['parentIndex']);
              } else if (parent.isEmpty && pi != null) {
                if (pi >= 0 && pi < slots.length - 1 && slots[pi].isNotEmpty) {
                  parent = slots[pi];
                } else {
                  // 前に作った物を指していない parentIndex は使えない。
                  // ★ = 継続検証 248。 配列より大きい番号を「後ろにある要素」
                  //   と説明していた (9 件しか渡していないのに 99 が
                  //   「後ろに存在する」 と読めてしまう)。 範囲外・自分自身・
                  //   範囲内だが自分より後ろ・作られなかった要素、 を分ける。
                  final piLast = batch.length - 1;
                  cannotLink(
                      (pi < 0 || pi >= batch.length)
                          ? '"parentIndex" $pi is out of range: the "nodes" '
                              'array in this call has ${batch.length} '
                              'entries, so a valid "parentIndex" is 0..$piLast '
                              'and must point at an entry BEFORE this one'
                          : pi == bi
                              ? '"parentIndex" pointed at this very entry (a '
                                  'node cannot be its own parent)'
                              : (pi > bi
                                  ? '"parentIndex" pointed at entry $pi, but a '
                                      'parent must appear EARLIER in the array '
                                      'than its child (this is entry $bi) - '
                                      'put the parent before it'
                                  : '"parentIndex" $pi is not an entry that '
                                      'was created in this call (that entry '
                                      'made no node - see "failed")'),
                      parentRef: pi);
                }
              }
              if (parent.isNotEmpty) {
                if (!_provider.mcpConnectNodes(pageId, parent, id)) {
                  cannotLink('the app refused the line between them',
                      parentRef: parent);
                } else {
                  // ★ = 継続検証 376。 題名で指されても id で返す。
                  linked.add({
                    'index': bi,
                    'nodeId': id,
                    'parentId': parent,
                  });
                }
              }
            }
            if (ids.isEmpty) {
              return _err(_provider.mcpPageById(pageId) == null
                  ? 'page not found: "$pageId"'
                  // ★ = 継続検証 230。 理由を添えないと、 開けない URL だけを
                  //   並べた依頼が「題名が足りない」 と読み違えられ、 AI が
                  //   同じ依頼を繰り返していた。
                  : 'nothing was added: every entry in "nodes" was unusable. '
                      'Reason per input index: '
                      '${jsonEncode(_capDetail(failed))}');
            }
            // 座標を渡さないと全部同じ場所に重なる。
            // ★ 以前は「後で tidy_page を呼んでね」 と返すだけだった。
            //   呼び忘れ・途中で停止のどちらでも団子のまま残るので
            //   (= ユーザー報告: 新規ページで全部が一か所に出る)、
            //   **足したノードだけ**その場で並べる。 ページ全体は触らない
            //   ので、 利用者が手で組んだ配置は崩れない。
            // ★ = 動作検証の不具合「一括追加した子要素が同じ位置に重なる」。
            //   以前は「1 件でも座標が書いてあれば、 **全部**自動配置しない」
            //   としていたので、 座標を書いていない兄弟が既定の 1 点に
            //   固まっていた。 座標を書いていない物**だけ**並べる。
            if (auto.isNotEmpty) _provider.mcpArrangeNewNodes(pageId, auto);
            return _ok({
              // id と題名を組で返す (= 続けて connect_nodes を呼ぶ時に、
              //   どの id がどのノードか迷わないように)。
              'nodes': _provider.mcpNodeIndex(pageId).where(
                  (e) => ids.contains(e['id'])).toList(),
              'nodeIds': ids,
              // ★ = 継続検証 124。 頼まれた数・作った数・落とした数を分けて
              //   返す (「全部作られた」 と読み違えさせない)。
              'summary': 'asked ${batch.length}, created ${ids.length}, '
                  'failed ${failed.length}, unlinked ${unlinked.length}, '
                  'urlIgnored ${urlIgnored.length}',
              'asked': batch.length,
              'created': ids.length,
              // ★ = 継続検証 201。 マップ以外の種別では画面に出ない事を必ず
              //   返す (成功だけ返すと「置けた」 と報告されてしまう)。
              ...?_hiddenMapLayerNote(pageId, 'add_node'),
              if (failed.isNotEmpty) 'failed': failed,
              // ★ = 継続検証 376。 どの親へ繋いだかを id で返す。
              if (linked.isNotEmpty) 'linked': linked,
              if (unlinked.isNotEmpty) 'unlinked': unlinked,
              // ★ = 継続検証 230。 update_node と同じ鍵 (ignored) で返す。
              //   storedAs は provider が入れる 'memo' (本文へ回した) か
              //   'dropped' (メモが既に有ったので捨てた) の 2 通り。
              if (urlIgnored.isNotEmpty) ...{
                'ignored': urlIgnored,
                'urlNote': '${urlIgnored.length} url(s) were NOT made '
                    'clickable (a node can only open http(s)). Check '
                    '"storedAs" per entry: "memo" = the address was kept as '
                    'plain text, "dropped" = it was not stored at all. Never '
                    'report those addresses as working links.',
              },
              if (auto.length > 1)
                'note': 'the ${auto.length} new nodes without x/y were laid '
                    'out next to their parents (new roots are placed clear of '
                    'what is already on the page). Call tidy_page only if you '
                    'want the WHOLE page rearranged.',
            });
            } finally {
              if (undoPushed) _provider.endUndoBatch();
            }
          }
          // 題名も memo も url も無い呼び出しでは何も作らない。
          // ★ 鍵が有るかどうかではなく、 中身が有るかどうかで見る
          //   (= 検証レポート: title:"   " で空のノードが出来ていた)。
          if (!_hasContent(a['title']) &&
              !_hasContent(a['memo']) &&
              !_hasContent(a['url'])) {
            return _err('nothing to add: "title", "memo" and "url" were all '
                'empty or blank. Pass "nodes" (an array) or at least a real '
                '"title". No node was created.');
          }
          // ★ = 継続検証 147。 開けない URL をメモへ回した事を必ず返す。
          // ★ = 継続検証 230。 一括経路と同じ決まりにする。 URL しか中身が
          //   無く、 その URL が開けない時は何も作らない (作ると、 開けない
          //   文字列がメモに入っただけの普通の要素が残る)。
          final soleUrl = a['url'] == null ? '' : '${a['url']}'.trim();
          if (soleUrl.isNotEmpty &&
              !MindMapProvider.mcpIsUsableLink(soleUrl) &&
              !_hasContent(a['title']) &&
              !_hasContent(a['memo'])) {
            return _err('unsupported_scheme: only http(s) links can be opened '
                'from a node, and "title" and "memo" were both empty - no node '
                'was created. Put the address in "memo" if you want it kept as '
                'plain text.');
          }
          final addOut = <String, Object?>{};
          final id = _provider.mcpAddNode(
            pageId,
            title: _unescapeLiteralNewlines('${a['title'] ?? ''}', minHits: 1),
            x: numOf('x'),
            y: numOf('y'),
            memo: a['memo'] == null
                ? null
                : _unescapeLiteralNewlines('${a['memo']}'),
            url: a['url'] == null ? null : '${a['url']}',
            colorValue: _argbOf(a['color']),
            outcome: addOut,
          );
          // ★ = 継続検証 230。 storedAs が 'dropped' (= メモが既に有る所へ
          //   開けない url を渡した) 時は「メモに残した」 が嘘になるので、
          //   保存先で文面を分ける。
          final storedNote = addOut['storedAs'] == 'memo'
              ? 'the address was kept as plain text in the memo'
              : 'the address was NOT stored anywhere';
          return id == null
              ? _err('page not found')
              : _ok({
                  'nodeId': id,
                  // ★ = 継続検証 201 (一括形と同じ注意書き。 双子なので
                  //   片方だけ直すと 1 件ずつ呼ばれた時に漏れる)。
                  ...?_hiddenMapLayerNote(pageId, 'add_node'),
                  if (addOut['requestedUrl'] != null) ...{
                    'requestedUrl': addOut['requestedUrl'],
                    'storedAs': addOut['storedAs'],
                    'urlNote': '${addOut['reason']}. Tell the user '
                        '$storedNote, not that it became a link.',
                  },
                });
        }
      case 'update_node':
        {
          // id でも題名でもよい (= ユーザー報告: AI が id の書き写しを誤る)。
          final pageId = a['pageId'] as String? ?? '';
          final key = '${a['node'] ?? a['nodeId'] ?? ''}'.trim();
          // ★ 書き換える相手が 1 つに決まらない時は断る (= 調査報告 BUG-16:
          //   同じ題名が複数あると作成順の先頭が選ばれ、 別のノードを
          //   書き換えてしまう)。
          final updAmb = _ambiguous(pageId, key, 'node', fuzzy: false);
          if (updAmb != null) return _err(updAmb);
          // 色とリンクも直せる (= ユーザー要望: 置いた後に変えたい)。
          final color = _argbOf(a['color']);
          // ★ = 継続検証 241。 範囲外 / 読めない色は _argbOf が null に倒す
          //   ので provider へは届かず、 provider の ignored にも載らない。
          //   捨てた理由をここで作って ignored へ合わせる (載せないと
          //   「既に同じ値だった」 と誤って説明してしまう)。
          final colorIgnore = _argbIgnoreReason(a['color']);
          final url = a['url'] == null ? null : '${a['url']}';
          final clearUrl = a['clearUrl'] == true;
          // ★ = 動作検証 継続検証 94 / 119 / 137 / 147 / 175 / 183。
          //   「本当に当てた項目」 と「受け取ったのに当てなかった項目」 を
          //   provider から受け取って、 そのまま返す。
          final updOut = <String, Object?>{};
          final ok = _provider.mcpUpdateNode(
            pageId,
            key,
            title: a['title'] == null
                ? null
                : _unescapeLiteralNewlines(a['title'] as String, minHits: 1),
            memo: a['memo'] == null
                ? null
                : _unescapeLiteralNewlines(a['memo'] as String),
            x: numOf('x'),
            y: numOf('y'),
            colorValue: color,
            url: url,
            clearUrl: clearUrl,
            outcome: updOut,
          );
          if (!ok) {
            // ★ = 動作検証の不具合「存在する ID を『見つからない』 と返す」。
            //   書き換えを断られた時も同じ文面だったので、 AI が id を
            //   探し直す方へ行ってしまっていた。 本当に引けないのか、
            //   引けたが書けなかったのかを分けて言う。
            // ★ 書き換える側は部分一致を使わない ので、 こちらも同じ
            //   物差し (fuzzy: false) で「居るか」 を見る。
            final exact = _provider.mcpResolveNodeId(pageId, key, fuzzy: false);
            if (exact == null) {
              final near = _provider.mcpResolveNodeId(pageId, key);
              if (near != null) {
                return _err('"$key" only partially matches a node title, and '
                    'the update path does not accept partial matches (it '
                    'would risk changing the wrong node). Pass the exact '
                    'title or the id. Available nodes: '
                    '${jsonEncode(_provider.mcpNodeIndex(pageId))}');
              }
              return _err('no node "$key" on that page. Available nodes (use '
                  'the "title" value as "node"): '
                  '${jsonEncode(_provider.mcpNodeIndex(pageId))}');
            }
            return _err('"$key" exists on "$pageId" but the update was not '
                'applied (the page may be locked, or nothing to change was '
                'passed). The node was left as it was.');
          }
          // どのノードを書き換えたかを返す (= 題名で指した時に、 思った物と
          //   違うノードを直していないか AI が確かめられるように)。
          final rid = _provider.mcpResolveNodeId(pageId, key);
          final hit = _provider.mcpNodeIndex(pageId).firstWhere(
              (e) => e['id'] == rid,
              orElse: () => const <String, String>{});
          // ★ = 動作検証レポート 2026-09-25 不具合 4「応答が公開契約どおり
          //   適用値を返さない」。 updated:true と color しか返さないので、
          //   確かめるのに read_page がもう 1 回必要だった。
          //   applied = 実際に当てた値。
          // ★ = 継続検証 119。 以前の ignored は「渡されなかった項目」 まで
          //   並べていたので、 色 1 つを直そうとしただけで title / memo /
          //   x / y / url が無視された事になっていた。 provider が返す
          //   「受け取ったのに当てなかった項目 (と理由)」 だけを返す。
          final changedFields =
              (updOut['appliedFields'] as List?)?.cast<String>() ??
                  const <String>[];
          final ignored = <Map<String, Object?>>[
            ...?(updOut['ignored'] as List?)?.cast<Map<String, Object?>>(),
            // ★ = 継続検証 241。 範囲外の色は provider まで届かないので
            //   provider の ignored には出て来ない。 ここで足す。
            if (colorIgnore != null)
              {
                'field': 'color',
                'value': a['color'],
                'reason': colorIgnore,
              },
          ];
          final applied = <String, Object?>{
            if (rid != null) 'id': rid,
            if (changedFields.contains('title'))
              'title': _unescapeLiteralNewlines(a['title'] as String,
                  minHits: 1),
            if (changedFields.contains('memo'))
              'memo': _unescapeLiteralNewlines(a['memo'] as String),
            if (changedFields.contains('x')) 'x': numOf('x'),
            if (changedFields.contains('y')) 'y': numOf('y'),
            if (changedFields.contains('color')) 'color': color,
            if (changedFields.contains('url') && !clearUrl && url != null)
              'url': url.trim(),
            if (changedFields.contains('url') && clearUrl) 'url': null,
          };
          // ★ = 継続検証 183「変化が無いのに updated:true を返し、 取り消し
          //   履歴まで 1 手食う」。 何も変わらない時は unchanged と言う
          //   (provider 側も控えを積まなくなった)。
          if (changedFields.isEmpty) {
            return _ok({
              'updated': false,
              'unchanged': true,
              if (rid != null) 'nodeId': rid,
              if (hit['title'] != null) 'title': hit['title'],
              if (ignored.isNotEmpty) 'ignored': ignored,
              'reason': ignored.isEmpty
                  ? 'every value passed already matched the node, so nothing '
                      'was written and no undo step was used.'
                  : 'nothing could be applied - read "ignored" for the reason '
                      'of each field. The node was left exactly as it was.',
            });
          }
          return _ok({
            'updated': true,
            if (rid != null) 'nodeId': rid,
            if (hit['title'] != null) 'title': hit['title'],
            if (changedFields.contains('color') && color != null)
              'color': color,
            if (changedFields.contains('url') && !clearUrl && url != null)
              'url': url.trim(),
            if (changedFields.contains('url') && clearUrl) 'urlCleared': true,
            'applied': applied,
            'changed': changedFields,
            if (ignored.isNotEmpty) 'ignored': ignored,
          });
        }
      case 'delete_node':
        {
          final pageId = a['pageId'] as String? ?? '';
          // ★ = 動作検証レポート 改善案 1「タイルは消えるのに実ファイルが
          //   残る」。 既定は今までどおり「タイルだけ」。 消すのは
          //   ごみ箱までで、 完全削除は決してしない。
          final disposeMode = () {
            final v = '${a['deleteFile'] ?? 'no'}'.trim().toLowerCase();
            return const {'no', 'generated', 'yes'}.contains(v) ? v : 'no';
          }();
          // ★ 空配列は 1 件用へ落とさない (= 動作検証レポート 不具合 5:
          //   中身の無い 1 件として失敗し、 そのページのノード一覧まで
          //   添えて返っていた)。
          final delEmpty = _emptyBatch(a, 'nodes',
              'Pass the titles or ids to delete, or do not call delete_node.');
          if (delEmpty != null) return delEmpty;
          // ★ = 継続検証 257「MCP で子要素を消しても兄弟の空きが詰まらない」。
          //   既定は画面の削除と同じ「跡を詰める」。 わざと空けたままに
          //   したい時だけ compact:false。
          final delCompact = a['compact'] != false;
          // ★ = 継続検証 159「単一指定と一括指定の併記を黙って処理し、 単一
          //   指定を無視する」。 消す操作は取り返しが付きにくいので、 食い違った
          //   依頼は実行せずに断る (どちらを消すのか当てずっぽうで決めない)。
          if (a['nodes'] is List &&
              (a['nodes'] as List).isNotEmpty &&
              ('${a['node'] ?? a['nodeId'] ?? ''}'.trim().isNotEmpty)) {
            return _err('"nodes" (the array form) and "node"/"nodeId" (the '
                'single form) were both given, and they name different '
                'targets. Nothing was deleted - send ONE of them (put every '
                'target in "nodes" if you want several).');
          }
          // まとめて消せる形も持たせる (= 1 件ずつだと AI が取りこぼす)。
          final batch = a['nodes'];
          if (batch is List && batch.isNotEmpty) {
            // 何を消したかを題名で返す (= 数だけだと、 頼まれた物と違う
            //   ノードが消えていても AI が気付けない)。
            final removed = <String>[];
            // ★ = 動作検証レポート 2026-09-25 不具合 7「無題の表ノードを
            //   識別できない」。 題名だけだと caption 付き・title 空の表は
            //   空文字で返り、 どれを消したのか後から分からない。
            //   id / caption / 種別を添えた deletedItems も返す
            //   (deleted は互換のため残す)。
            final removedItems = <Map<String, Object?>>[];
            final missed = <String>[];
            // ★ = 継続検証 278 / 373。 1 つに決まらなかった指定 (消していない)。
            final ambiguous = <Map<String, Object?>>[];
            final files = <Map<String, Object?>>[];
            for (final e in batch) {
              final k = '${e ?? ''}'.trim();
              // ★ = 継続検証 278 / 373。 1 件ずつの形は 1 つに決まらない指定を
              //   断るのに、 一括の形はそのまま消していたので、 同名が 2 件
              //   あると作成順の 1 件目が黙って消えていた。 消すのは取り返しが
              //   付かない。 同じ物差しで断る。
              final delAmbOne = _ambiguous(pageId, k, 'nodes', fuzzy: false);
              if (delAmbOne != null) {
                ambiguous.add({'node': k, 'reason': delAmbOne});
                continue;
              }
              // 消す前に添付の在処を控える (消した後では引けない)。
              final was = disposeMode == 'no'
                  ? ''
                  : _provider.mcpAttachmentPathOf(pageId, k);
              // 消す前に見出しを控える (消した後では引けない)。
              final brief = _provider.mcpNodeSummary(pageId, k);
              final title =
                  _provider.mcpDeleteNode(pageId, k, compact: delCompact);
              if (title != null && was.isNotEmpty) {
                files.add({
                  'path': was,
                  // ★ = 継続検証 230 前半。 どのページの取り消しで戻すのかを
                  //   渡す (渡さないと写しを控える先が決まらない)。
                  ...await _provider.mcpDisposeAttachmentFile(
                      was, disposeMode,
                      undoPageId: pageId),
                });
              }
              if (title == null) {
                missed.add(k);
              } else {
                // ★ = 継続検証 127。 題名の無い要素は見出し / id で名乗る。
                removed.add(title.trim().isNotEmpty
                    ? title
                    : '${brief?['caption'] ?? brief?['id'] ?? k}');
                removedItems.add(brief ?? {'title': title});
              }
            }
            // ★ = 継続検証 278 / 373。 決まらない指定しか無かった時は、
            //   「見つからない」 ではなく「決まらない」 と返す。
            if (removed.isEmpty && ambiguous.isNotEmpty) {
              return _err('ambiguous_name: ' +
                  jsonEncode({
                    'code': 'ambiguous_name',
                    'nodes': ambiguous,
                    if (missed.isNotEmpty) 'notFound': missed,
                    'note': 'nothing was deleted. Each of those names matches '
                        'more than one node, so picking one would be a guess. '
                        'Pass the exact "id" (read_page lists id and title).',
                  }));
            }
            return removed.isEmpty
                ? _err('none of $missed were found. Available nodes: '
                    '${jsonEncode(_provider.mcpNodeIndex(pageId))}')
                : _ok({
                    'deleted': removed,
                    'deletedItems': removedItems,
                    if (missed.isNotEmpty) 'failed': missed,
                    // ★ = 継続検証 278 / 373。 決まらなかった指定は消していない
                    //   ので、 必ず応答へ出す。
                    if (ambiguous.isNotEmpty) 'ambiguous': ambiguous,
                    // 実ファイルをどうしたか (= 「消した」 と言い切らせない)。
                    if (files.isNotEmpty) 'files': files,
                  });
          }
          final key = '${a['node'] ?? a['nodeId'] ?? ''}'.trim();
          // ★ 消す相手が 1 つに決まらない時は当てずっぽうで選ばない
          //   (= 調査報告 BUG-16)。 消す操作は取り返しが付きにくい。
          final delAmb = _ambiguous(pageId, key, 'node', fuzzy: false);
          if (delAmb != null) return _err(delAmb);
          final wasOne = disposeMode == 'no'
              ? ''
              : _provider.mcpAttachmentPathOf(pageId, key);
          final briefOne = _provider.mcpNodeSummary(pageId, key);
          final removedTitle =
              _provider.mcpDeleteNode(pageId, key, compact: delCompact);
          if (removedTitle == null) {
            return _err('no node "$key" on that page. Available nodes (use '
                'the "title" value as "node"): '
                '${jsonEncode(_provider.mcpNodeIndex(pageId))}');
          }
          return _ok({
            // ★ = 継続検証 127「表要素の削除結果で代表値が空文字になる」。
            //   題名を持たない要素 (caption だけの表など) は空文字で返って
            //   いたので、 短い成功表示しか使わない呼び側は何を消したか
            //   言えなかった。 見出し → id の順に代わりを立てる。
            'deleted': removedTitle.trim().isNotEmpty
                ? removedTitle
                : '${briefOne?['caption'] ?? briefOne?['id'] ?? key}',
            'deletedItems': [briefOne ?? {'title': removedTitle}],
            if (wasOne.isNotEmpty)
              'file': {
                'path': wasOne,
                // ★ = 継続検証 230 前半 (一括の方と同じ)。
                ...await _provider.mcpDisposeAttachmentFile(
                    wasOne, disposeMode,
                    undoPageId: pageId),
              },
          });
        }
      // ── 絵を描いて「開いているページの上」 に置く (= ユーザー要望:
      //    「〜の絵を描いて」「画像を生成して」 と置き場所を言われずに
      //    頼まれた時は、 今開いているページに配置する) ──
      case 'generate_image':
        {
          final drawPrompt = (a['prompt'] as String? ?? '').trim();
          if (drawPrompt.isEmpty) return _err('prompt is required');
          // ★ pageId は省ける。 省かれたら**今開いているページ**。 ここで
          //   決めてしまうので、 AI が場所を書き忘れても外さない。
          final drawPageId = _pageIdOrCurrent(a['pageId']);
          if (drawPageId.isEmpty) {
            return _err('no page is open - make one with create_page first.');
          }
          try {
            return await _drawImageOnPage(
              drawPageId,
              drawPrompt,
              title: a['title'] as String?,
              x: numOf('x'),
              y: numOf('y'),
            );
          } catch (e) {
            return _err('$e');
          }
        }
      case 'generate_page_background':
        {
          // ★ 指定が無ければ「今開いているページ」 (= ユーザー要望:
          //   現在開いているページに適用するか、 出来ないなら確認を取る)。
          final genPageId = _pageIdOrCurrent(a['pageId']);
          // 絵を描かせる前に、 背景を出せるページか確かめる。 出せない所へ
          //   描くと 1 枚分のクレジットを捨てる事になる。
          final genRefusal = _provider.mcpBackgroundRefusal(genPageId);
          if (genRefusal != null) return _err(genRefusal);
          // 濃さは provider が 0..100 に丸める (set_page_background と同じ)。
          final genOpacity = intOf('opacityPercent', min: -1 << 31);
          if (intErr != null) return _err(intErr!);
          try {
            final path = await _provider.mcpGeneratePageBackground(
              genPageId,
              a['prompt'] as String? ?? '',
              opacityPercent: genOpacity,
              fit: a['fit'] as String?,
              // ★ = ユーザー要望「フリーノートを開いている状態で AI に〜を
              //   描画する指示を出した場合、 そのノート上に描画を行う」。
              placeOnSheet: a['placeOnSheet'] == true,
            );
            final genPage = _provider.mcpPageById(genPageId);
            // 絵の出どころ (= ユーザー要望: チャットに出典を出す)。
            final src = _provider.lastImageSource;
            return _ok({
              'background': path,
              'pageId': genPageId,
              if (genPage != null) 'pageName': genPage.name,
              if (src != null) 'imageSource': src.label,
              if (src?.url != null) 'imageSourceUrl': src!.url,
              'tellTheUser': src == null
                  ? 'Say where the picture came from.'
                  : 'Tell the user where the picture came from, in your reply: '
                      '${src.label}${src.url == null ? '' : ' (${src.url})'}',
            });
          } catch (e) {
            return _err('$e');
          }
        }
      case 'tidy_page':
        {
          final pageId = a['pageId'] as String? ?? '';
          final page = _provider.mcpPageById(pageId);
          if (page == null) {
            return _err(_noPageMsg(pageId));
          }
          final type = page.pageType ?? 'normal';
          // ギャラリーは「セルを左上から詰め直す」 整列で応える
          // (= ユーザー報告: 整列を頼むと「必要ありません」 と断られる)。
          if (type == 'bookshelf') {
            if (page.nodes.isEmpty) {
              return _err('nothing to tidy: "$pageId" has 0 item(s).');
            }
            // ★ = 継続検証 175「変化のない整列が成功扱いとなり、 取り消し履歴を
            //   消費する」。 1 件も動かない時は「変更なし」 と返す (provider も
            //   控えを積まない)。
            // ★ = 継続検証 285「無変更・保存なしと返しながらタイルの高さが
            //   変わる」。 provider は寸法の変化も「変わった」 と数えるように
            //   したので、 内訳 (動いた数 / 大きさを揃えた数 / 揃えた後の
            //   寸法) をそのまま返す。 unchanged はもう寸法も変えない。
            final galleryOut = <String, Object?>{};
            final movedN =
                _provider.mcpTidyGallery(pageId, outcome: galleryOut);
            if (movedN == 0) {
              return _ok({
                'tidied': false,
                'unchanged': true,
                'pageId': pageId,
                'items': page.nodes.length,
                'reason': 'every tile was already in its packed grid position '
                    'and already the right size, so nothing moved, nothing '
                    'was resized, nothing was saved, and no undo step was '
                    'used.',
              });
            }
            return _ok({
              'tidied': true,
              'pageId': pageId,
              'changed': movedN,
              ...galleryOut,
              'items': page.nodes.length,
              'note': 'packed ${galleryOut['moved']} of '
                  '${page.nodes.length} gallery item(s) into the grid from '
                  'the top-left, and squared ${galleryOut['resized']} tile(s) '
                  'to ${galleryOut['tileWidth']}x${galleryOut['tileHeight']} '
                  '(gallery tiles are all one size). One undo_page puts all '
                  'of that back.',
            });
          }
          if (type != 'normal') {
            return _err('tidy_page only works on a mind map or gallery '
                '(bookshelf) page; "$pageId" is a "$type" page, which '
                'arranges itself.');
          }
          if (page.nodes.length < 2) {
            return _err('nothing to tidy: "$pageId" has '
                '${page.nodes.length} node(s).');
          }
          // ★ = 継続検証 280「無変更の整列が成功扱いになり、 取り消し履歴を
          //   1 手消費する」。 1 つも変わらないなら unchanged と言う (provider
          //   も保存も控えもしない)。 ギャラリー側と同じ返し方に揃える。
          if (!_provider.mcpTidyPage(pageId)) {
            return _ok({
              'tidied': false,
              'unchanged': true,
              'pageId': pageId,
              'nodes': page.nodes.length,
              'reason': 'every node was already where this layout puts it and '
                  'every line was already drawn the way it draws them, so '
                  'nothing changed, nothing was saved, and no undo step was '
                  'used. Calling it again will not change that.',
            });
          }
          return _ok('tidied ${page.nodes.length} nodes on $pageId');
        }
      case 'set_page_background':
        {
          // ★ 指定が無ければ「今開いているページ」 (= ユーザー要望)。
          final bgPageId = _pageIdOrCurrent(a['pageId']);
          // ★ 背景を描かない種別 (マークダウン / 動画エディター) は、
          //   入れても何も出ないので断る。 断り文には「今開いているページ」
          //   を添えてあるので、 AI はそれを使って利用者に確かめられる
          //   (= ユーザー報告: マークダウンのページの背景を変えてきた)。
          final bgRefusal = _provider.mcpBackgroundRefusal(bgPageId);
          if (bgRefusal != null) return _err(bgRefusal);
          final bgTpl = (a['template'] as String? ?? '').trim();
          final bgImg = (a['imagePath'] as String? ?? '').trim();
          // ★ 紙 (フリーノート / 便箋) には出来合いの絵柄を貼れない。
          //   provider が false を返すだけだと、 まとめ書きの文面
          //   (「ページが見つからない…」) になって理由が伝わらない。
          final bgPageType =
              _provider.mcpPageById(bgPageId)?.pageType ?? 'normal';
          if (bgTpl.isNotEmpty &&
              (bgPageType == 'paint' || bgPageType == 'document')) {
            return _err('the built-in background templates only work on map '
                'and gallery pages. On a free note / notepad page, pass '
                'imagePath, or use generate_page_background to draw one.');
          }
          // ★ = 動作検証の不具合「画像ではないファイルを背景として
          //   受け付ける」。 在るかどうかだけ見ていたので、 中身が文字の
          //   `壊れた背景.png` でも通り、 背景が黙って出ないままになっていた。
          //   絵を受ける他の道具 (add_image_node / add_gallery_item) と
          //   同じ物差し ([_imagePathRejection]) で確かめる。
          if (a['clear'] != true && bgTpl.isEmpty && bgImg.isNotEmpty) {
            final why = await _imagePathRejection(bgImg);
            if (why != null) {
              return _err('imagePath rejected: $why: $bgImg '
                  '- the background was not changed.');
            }
          }
          // ★ 濃さ / 色味は provider が範囲に丸める。 道具の説明も
          //   「はみ出した値は丸める。 断らない」 と約束しているので、
          //   ここで断ると背景の絵ごと落としてしまう (= 粗探しで発見)。
          //   整数かどうかだけ見て、 範囲は provider に任せる。
          final bgOpacity = intOf('opacityPercent', min: -1 << 31);
          final bgHue = intOf('hueDegrees', min: -1 << 31);
          final bgSat = intOf('saturationPercent', min: -1 << 31);
          final bgBright = intOf('brightnessPercent', min: -1 << 31);
          if (intErr != null) return _err(intErr!);
          final bgOut = <String, Object?>{};
          final ok = await _provider.mcpSetPageBackground(
            bgPageId,
            template: a['template'] as String?,
            imagePath: a['imagePath'] as String?,
            clear: a['clear'] == true,
            opacityPercent: bgOpacity,
            fit: a['fit'] as String?,
            hueDegrees: bgHue,
            saturationPercent: bgSat,
            brightnessPercent: bgBright,
            outcome: bgOut,
          );
          if (!ok) {
            // ★ = 継続検証 155「無効テンプレートとページ不存在のエラーを
            //   区別できない」「既に背景が無いのに更新扱いになる」。
            //   provider が返す理由を 1 つだけ伝える。
            switch ('${bgOut['reason'] ?? ''}') {
              case 'page_not_found':
                return _err(_noPageMsg(bgPageId,
                    did: 'The background was not changed.'));
              case 'page_type_has_no_background':
                return _err('"$bgPageId" is a page kind that draws no '
                    'background, so nothing was changed.');
              case 'already_no_background':
                return _ok({
                  'updated': false,
                  'unchanged': true,
                  'pageId': bgPageId,
                  'background': null,
                  'reason': 'this page already had no background, so nothing '
                      'was written (the page timestamp was left alone too).',
                });
              case 'clear_conflicts_with_background':
                return _err('"clear" was sent together with "template" / '
                    '"imagePath" - those ask for opposite things, so nothing '
                    'was changed. Send ONE of them.');
              case 'invalid_template':
                return _err('"${a['template']}" is not a built-in background. '
                    'The background was not changed. Available: '
                    '${jsonEncode(bgOut['templates'])}');
              case 'image_not_found':
                return _err('imagePath does not exist: ${a['imagePath']} '
                    '- the background was not changed.');
              case 'nothing_to_change':
                return _err('nothing to change: pass "template", "imagePath", '
                    '"clear", or at least one of opacityPercent / fit / '
                    'hueDegrees / saturationPercent / brightnessPercent.');
            }
            return _err('the background of "$bgPageId" could not be changed.');
          }
          // ★ 範囲外の値は黙って丸められるので、 入った値をそのまま返す
          //   (= 動作確認で判明: 150% と頼まれて 100% になったのに、
          //   AI には「更新しました」 としか返らず 150% と報告できてしまう)。
          final bgPage = _provider.mcpPageById(bgPageId);
          return _ok({
            'updated': true,
            // ★ どのページを変えたかを必ず返す。 返事に名前を書かせれば、
            //   狙いが外れていても利用者がその場で気付ける
            //   (= ユーザー報告: 別のページの背景を変えられていた)。
            'pageId': bgPageId,
            if (bgPage != null) ...{
              'pageName': bgPage.name,
              'background': bgPage.backgroundImagePath,
              // ★ = 継続検証 155「背景解除の応答に、 保存されていない調整値が
              //   併記される」。 背景が無い時に濃さや色味を並べると、 設定が
              //   残ったように読める。 背景がある時だけ返す。
              if ((bgPage.backgroundImagePath ?? '').isNotEmpty) ...{
                'opacityPercent': bgPage.backgroundOpacityPercent,
                'fit': bgPage.backgroundFit,
                'hueDegrees': bgPage.backgroundHueDegrees,
                'saturationPercent': bgPage.backgroundSaturationPercent,
                'brightnessPercent': bgPage.backgroundBrightnessPercent,
              } else
                'cleared': true,
            },
            // ★ = 継続検証 103「背景変更後の Undo 案内がページ種類と合わない」。
            //   背景は要素の取り消し履歴に入らないので、 それをここで言う
            //   (undo_page の「編集画面内の履歴」 案内では判断できなかった)。
            'undoNote': 'a background change is NOT part of the node undo '
                'history, so undo_page will not put it back. Call '
                'set_page_background again (or with clear:true) to change it.',
          });
        }
      case 'connect_nodes':
        {
          final pageId = a['pageId'] as String? ?? '';
          // ★ = 動作検証の不具合「ギャラリーに MCP から接続線を追加できる」。
          //   画面からは引けないので、 道具からも引かせない (add_node の
          //   ギャラリー判定と同じ形)。
          final connTarget = _provider.mcpPageById(pageId);
          // ★ = 点検で判明。 プランで鍵の掛かったページは mcpPageById が
          //   null を返すので、 ここを素通りして引き当てだけが全部失敗し、
          //   最後に code: 'node_not_found' で返っていた (= 実在する要素を
          //   「そのページにその要素はありません」 と誤診させる)。 本当の
          //   理由を _noPageMsg で返す (「無い」 と「開けない」 の言い分け)。
          if (connTarget == null) {
            return _err(_noPageMsg(pageId, did: 'No line was drawn.'));
          }
          if (connTarget.pageType == 'bookshelf') {
            return _err('"$pageId" is a gallery (bookshelf) page: a gallery '
                'has no connection lines, so nothing was connected. If the '
                'user wants them linked, offer to convert the page with '
                'set_page_type "normal" first.');
          }
          // id でも題名でもよい (= ユーザー報告: AI が id の特定に手こずって
          //   接続できなかった)。 どちらの書き方も受ける。
          String key(Map<String, dynamic> m, String a1, String a2) {
            final v1 = '${m[a1] ?? ''}'.trim();
            return v1.isNotEmpty ? v1 : '${m[a2] ?? ''}'.trim();
          }

          final connEmpty = _emptyBatch(a, 'connections',
              'Pass at least one {from, to}, or do not call connect_nodes.');
          if (connEmpty != null) return connEmpty;
          // まとめて繋げる形 (= 取りこぼし対策)。
          final batch = a['connections'];
          final entries = <Map<String, dynamic>>[];
          if (batch is List && batch.isNotEmpty) {
            for (final e in batch) {
              if (e is Map) entries.add(e.cast<String, dynamic>());
            }
          } else {
            entries.add(a);
          }
          // ★ = 動作検証レポート 改善案 4「札を書き換えただけの物まで
          //   connected に数えている」。 新しく引いた線と、 既にあった線を
          //   混ぜない。 繋ぐ**前**に見ないと後からでは見分けられない。
          final created = <Map<String, Object?>>[];
          final updated = <Map<String, Object?>>[];
          final unchanged = <Map<String, Object?>>[];
          final failed = <Map<String, Object?>>[];
          // ★ = 継続検証 232。 完全一致しなかった指定は繋がないが、 惜しい
          //   題名は候補として見せる (打ち間違いを AI が自力で直せるように)。
          List<Map<String, String>> nearOf(String want) {
            final index = {
              for (final e in _provider.mcpNodeIndex(pageId))
                e['id']: e['title']
            };
            return [
              for (final id in _provider.mcpMatchingNodeIds(pageId, want))
                {'id': id, 'title': index[id] ?? ''}
            ];
          }
          for (var i = 0; i < entries.length; i++) {
            final m = entries[i];
            final f = key(m, 'from', 'fromId');
            final t = key(m, 'to', 'toId');
            final label = m['label'] as String?;
            // ★ = 継続検証 121 / 140「既存のラベルを空文字で解除できない」。
            //   空文字は「指定なし」 と見分けが付かないので、 外す時は
            //   clearLabel で頼む (切って作り直す 2 手を要らなくする)。
            final clearLabel = m['clearLabel'] == true;
            if (f.isEmpty || t.isEmpty) {
              failed.add({
                'index': i,
                'from': f,
                'to': t,
                'reason': '"from" and "to" are both required',
              });
              continue;
            }
            // ★ = 継続検証 232。 引き当てを完全一致だけにしたので、 あいまい
            //   判定も同じ物差し (fuzzy: false) で見る。
            final amb = _ambiguous(pageId, f, 'from', fuzzy: false) ??
                _ambiguous(pageId, t, 'to', fuzzy: false);
            if (amb != null) {
              failed.add({
                'index': i,
                'from': f,
                'to': t,
                'reason': amb,
              });
              continue;
            }
            // ★ = 継続検証 232「connect_nodes だけ要素名の部分一致を許す」。
            //   存在しない部分名 (「検証232_始」) でも一番近い要素へ線を引き、
            //   created 1 と返していた (同じ指定を disconnect_nodes は
            //   node_not_found で断る)。 引く側も id / 題名の**完全一致**
            //   だけにし、 以降は引き当てた id で呼ぶ (id 指定は部分一致を
            //   通らないので、 provider の既定を触らずに物差しが揃う。
            //   add_nodes の parentId = 継続検証 111 と同じ作法)。
            final fromId = _provider.mcpResolveNodeId(pageId, f, fuzzy: false);
            final toId = _provider.mcpResolveNodeId(pageId, t, fuzzy: false);
            if (fromId == null || toId == null) {
              final near = <Map<String, String>>[
                if (fromId == null) ...nearOf(f),
                if (toId == null) ...nearOf(t),
              ];
              failed.add({
                'index': i,
                'from': f,
                'to': t,
                'code': 'node_not_found',
                'unknown': [
                  if (fromId == null) f,
                  if (toId == null) t,
                ],
                if (near.isNotEmpty) 'candidates': near,
                'reason': 'no node on this page has that exact id or title - '
                    'connect_nodes does NOT accept partial matches (a typo '
                    'would draw the line between the wrong nodes). Pass the '
                    'id, or the title exactly as read_page shows it.',
              });
              continue;
            }
            final existed = _provider.mcpConnectionExists(pageId, fromId, toId);
            final connOut = <String, Object?>{};
            if (!_provider.mcpConnectNodes(pageId, fromId, toId,
                label: label, clearLabel: clearLabel, outcome: connOut)) {
              failed.add({
                'index': i,
                'from': f,
                'to': t,
                'fromId': fromId,
                'toId': toId,
                'reason': fromId == toId
                    ? '"from" and "to" are the same node, so there is no line '
                        'to draw'
                    : 'the app refused the line between them',
              });
              continue;
            }
            // ★ = 継続検証 115 / 163。 応答の fromId / toId は**保存された
            //   向き**を返す (逆向きに頼まれた時は provider が向きも反転する)。
            final changed =
                (connOut['changed'] as List?)?.cast<String>() ?? const [];
            final item = <String, Object?>{
              'index': i,
              'fromId': connOut['fromId'] ?? fromId,
              'toId': connOut['toId'] ?? toId,
            };
            if (!existed) {
              created.add(item);
            } else if (changed.isNotEmpty) {
              updated.add({...item, 'changed': changed});
            } else {
              // ★ = 継続検証 161「同じラベルの再指定が更新扱いになり、 取り消し
              //   履歴を 1 手消費する」。 変わらないなら unchanged と言い、
              //   provider 側も控えを積まない。
              unchanged.add({
                ...item,
                'reason': 'already connected with that label - nothing was '
                    'written and no undo step was used',
              });
            }
          }
          if (created.isEmpty && updated.isEmpty && unchanged.isEmpty) {
            // 「見つからない」 だけでは AI が直しようがないので、 その
            //   ページに在るノードの id と題名を返して選び直させる。
            //   ★ 一覧を添えるのはここだけ。 空配列は上の _emptyBatch で
            //   止まっているので、 0 件で一覧を吐く事はもう無い
            //   (= 動作検証レポート 不具合 5)。
            // ★ = 継続検証 232。 全部が「その要素が無い」 だった時は、 消す側
            //   (disconnect_nodes) と同じ node_not_found の札で返す。
            if (failed.isNotEmpty &&
                failed.every((e) => e['code'] == 'node_not_found')) {
              return _err('node_not_found: ' +
                  jsonEncode({
                    'code': 'node_not_found',
                    'pairs': failed,
                    'nodes': _provider.mcpNodeIndex(pageId),
                  }));
            }
            return _err('could not connect '
                '${failed.map((e) => '${e['from']} -> ${e['to']}').join(', ')}'
                '. Available nodes on this page (use the "title" value as '
                '"from"/"to"): ${jsonEncode(_provider.mcpNodeIndex(pageId))}');
          }
          return _ok(_batchResult(
            created: created,
            updated: updated,
            unchanged: unchanged,
            failed: failed,
          ));
        }
      case 'add_table_node':
        {
          final pageId = a['pageId'] as String? ?? '';
          // ★ = 動作検証の不具合「ギャラリーへ表要素を追加でき、 既存の
          //   格子配置まで崩れる」。 ギャラリーは画像タイルを並べる場所で、
          //   画面には表を挿す口が無い。 入れると整列が表を巻き込んで
          //   既にあるタイルまで 1 列に並び直してしまうので、 ここで断る
          //   (connect_nodes / add_decoration のギャラリー判定と同じ形)。
          final tblTarget = _provider.mcpPageById(pageId);
          if (tblTarget != null && tblTarget.pageType == 'bookshelf') {
            return _err('"$pageId" is a gallery (bookshelf) page: a gallery '
                'holds tiles, not tables, so nothing was added. Use '
                'add_gallery_item for tiles, or make a mind map page with '
                'create_page type:"normal" and put the table there.');
          }
          final raw = a['rows'];
          if (raw is! List || raw.isEmpty) {
            return _err('rows must be a non-empty array of arrays');
          }
          final rows = <List<String>>[];
          for (final r in raw) {
            if (r is List) {
              rows.add([for (final c in r) '${c ?? ''}']);
            } else {
              rows.add(['${r ?? ''}']);
            }
          }
          // ★ = 動作検証の不具合「表の 100 行・30 列上限を MCP から
          //   超えられる」。 画面の表作成ダイアログと同じ上限で断る
          //   (画面は黙って丸めるが、 道具は理由を返す方が親切)。
          final tblCols = rows.fold<int>(0, (m, r) => math.max(m, r.length));
          // ★ = 継続検証 127「列が 0 件の表のエラーがページ不存在と混同
          //   される」。 正しいページ id なのに「page not found」 も候補として
          //   返っていたので、 どちらを直せばよいか分からなかった。
          //   入力の不足だけを名指しする。
          if (tblCols == 0) {
            return _err('a table needs at least one column: every row in '
                '"rows" was empty. Nothing was created - pass '
                'rows: [["a","b"],["c","d"]].');
          }
          if (rows.length > MindMapProvider.kTableMaxRows ||
              tblCols > MindMapProvider.kTableMaxCols) {
            return _err('table too big: got ${rows.length} rows x $tblCols '
                'columns. A table holds at most '
                '${MindMapProvider.kTableMaxRows} rows x '
                '${MindMapProvider.kTableMaxCols} columns (the same limit as '
                'the app\'s table dialog). No table was created - split the '
                'data across several tables, or drop columns.');
          }
          final id = _provider.mcpAddTableNode(
            pageId,
            rows: rows,
            headerRow: a['headerRow'] as bool? ?? true,
            x: numOf('x'),
            y: numOf('y'),
            // 見出しは表の上に出す説明書き。 作る時に渡す (後から付ける形は
            //   別ページだと効かなかった)。
            caption: a['title'] as String?,
          );
          if (id == null) return _err('page not found or rows empty: $pageId');
          // ★ = 継続検証 201 の双子。 表ノードも マップ以外の種別では
          //   画面に出ない (裏のマップ層に残るだけ)。
          return _ok({
            'nodeId': id,
            'rows': rows.length,
            ...?_hiddenMapLayerNote(pageId, 'add_table_node'),
          });
        }
      case 'add_image_node':
        final pageId = a['pageId'] as String? ?? '';
        // ★ この道具だけ「まとめて」 の形が無い (= 動作確認で判明: 他の
        //   道具は全部 texts / nodes でまとめられるので、 AI は配列を
        //   渡しがち。 素通しだと型エラーで落ち、 意味の分からない
        //   メッセージだけが返っていた)。
        final rawPath = a['imagePath'];
        final rawB64 = a['imageBase64'];
        if (rawPath is List || rawB64 is List) {
          return _err('add_image_node takes ONE image - there is no array '
              'form. Call it once per image.');
        }
        String? path = rawPath as String?;
        final b64 = rawB64 as String?;
        if (path == null && b64 != null && b64.isNotEmpty) {
          // base64 をアプリ書類フォルダへ保存してから添付ノード化する。
          try {
            final bytes = base64Decode(b64);
            // ★ = ユーザー要望「今開いているフォルダー外に新規ファイルや
            //   フォルダーを作成しない」。 以前は書類フォルダーの下に
            //   mcp_images/ を勝手に作っていた。
            final dir = await _provider.aiNewFileDir('mcp_images');
            var fname = (a['fileName'] as String? ?? 'image.png')
                .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
            if (!fname.contains('.')) fname = '$fname.png';
            final f = File(
                '${dir.path}/${DateTime.now().millisecondsSinceEpoch}_$fname');
            await f.writeAsBytes(bytes, flush: true);
            path = f.path;
          } catch (e) {
            return _err('failed to save image: $e');
          }
        }
        // ★ = ユーザー要望「『〜の絵を描いて』 と場所を言わずに頼んだら、
        //   開いているページに配置してほしい」。 文章のモデルは絵そのものを
        //   作れないので、 頼まれるとここへ prompt だけで来る。 これまでは
        //   「imageBase64 か imagePath が要る」 と突き返すだけで、 何も
        //   描かれずに終わっていた。 その場で描いて、 今開いているページへ
        //   置く (generate_image と同じ道)。
        if (path == null || path.isEmpty) {
          final drawFrom = (a['prompt'] as String? ?? '').trim();
          if (drawFrom.isNotEmpty) {
            try {
              return await _drawImageOnPage(
                _pageIdOrCurrent(pageId),
                drawFrom,
                title: a['title'] as String?,
                x: numOf('x'),
                y: numOf('y'),
              );
            } catch (e) {
              return _err('$e');
            }
          }
          return _err('imageBase64 or imagePath is required - or pass '
              '"prompt" to have the picture drawn with AI and placed on the '
              'page the user is looking at (the same as generate_image).');
        }
        // ★ 双子の add_gallery_item と同じ物差しで断る (= BUG-01)。
        //   存在確認だけだと、 .txt や壊れた png でも添付ノードが出来て
        //   いた (絵の出ない黒いタイルになる)。
        final imgWhy = await _imagePathRejection(path);
        if (imgWhy != null) {
          return _err('imagePath rejected: $imgWhy: $path '
              '- no node was created.');
        }
        // ★ = ユーザー報告「フリーノートに向けて絵を頼んでも、 ノートには
        //   何も出ない」。 フリーノート / 文書のページは要素 (ノード) を
        //   描かないので、 これまでは**見えないタイル**が出来るだけだった。
        //   紙の上に置く (= 選んで動かせる普通の画像要素)。
        final imgPageId = _pageIdOrCurrent(pageId);
        if (_provider.mcpPageIsPaintSheet(imgPageId)) {
          final placed = await _provider.mcpPlacePaintImage(imgPageId, path);
          return placed
              ? _ok({
                  'pageId': imgPageId,
                  'placedOn': 'free-note sheet',
                  'note': 'The picture was placed ON THE NOTE itself (it can '
                      'be moved, resized or deleted with the select tool). '
                      'Free-note pages hold no node tiles.',
                })
              : _err('could not place the picture on that free note');
        }
        final id = _provider.mcpAddImageNode(
          imgPageId,
          filePath: path,
          title: a['title'] as String?,
          x: numOf('x'),
          y: numOf('y'),
        );
        // ★ = 継続検証 201 の双子。 紙の上に置く道 (paint / document) は上で
        //   返しているので、 ここへ来る markdown / videoEditor では画面に
        //   出ない添付ノードになる。 その旨を必ず返す。
        return id == null
            ? _err('page not found')
            : _ok({
                'nodeId': id,
                ...?_hiddenMapLayerNote(imgPageId, 'add_image_node'),
              });
      case 'add_gallery_item':
        {
          final pageId = a['pageId'] as String? ?? '';
          // まとめて渡された時は 1 回で全部置く (= 1 件ずつだと AI が
          //   途中でやめたり同じ物を重ねたりして数が合わなかった)。
          final many = _stringList(a['texts']);
          // ★ texts を渡しておきながら中身が空 (= [] や ["", "  "]) の時は、
          //   下の「1 枚だけ足す」 へ落とさずに断る。 落とすと題名も memo も
          //   絵も無い白紙のタイルが 1 枚だけ増えていた (= 検証レポート)。
          final galEmpty = _emptyBatch(a, 'texts',
              'Pass at least one non-blank title, or use "memo" / '
              '"imagePath" for a tile without a title.',
              usable: many.length);
          if (galEmpty != null) return galEmpty;
          // ★ = 継続検証 174「単一形式と一括形式の併記で、 単一項目とメモを
          //   黙って無視する」。 食い違った依頼は実行せずに断る (通すと、
          //   単一側の memo を持った情報が気付かないまま消えていた)。
          if (many.isNotEmpty &&
              (_hasContent(a['text']) ||
                  _hasContent(a['memo']) ||
                  _hasContent(a['url']) ||
                  _hasContent(a['imagePath']))) {
            return _err('"texts" (the array form) and "text"/"memo"/"url"/'
                '"imagePath" (the single form) were both given. Nothing was '
                'added - the single tile and its memo would have been dropped '
                'silently. Send ONE form (call add_gallery_item once per tile '
                'when each needs its own memo or picture).');
          }
          // ★ = 動作検証の不具合「ギャラリーの 1000 件上限を MCP から
          //   超えられる」。 画面と同じ上限で、 入る分だけ入れて残りは
          //   理由付きで返す (黙って積み上げない)。
          final galPage = _provider.mcpPageById(pageId);
          final galRoom = (galPage != null && galPage.pageType == 'bookshelf')
              ? _provider.shelfRemainingItemCapacity(galPage)
              : -1;
          // ★ 点検で判明: ギャラリーでないページは、 控えを積む**前**に
          //   断る (積んでしまうと、 何も作れなかったのに「消したページを
          //   戻す」 の 1 発枠とやり直しが消える)。
          if (galRoom < 0) {
            return _err('not a gallery page (or page not found): "$pageId" '
                '- use list_pages and pick a page whose type is "bookshelf", '
                'or create one with create_page. Nothing was added.');
          }
          if (galRoom == 0) {
            return _err('gallery_full: "$pageId" already holds '
                '${_provider.shelfVisibleCount(galPage)} of '
                '${MindMapProvider.kShelfMaxVisibleItems} items. Nothing was '
                'added - tell the user instead of retrying.');
          }
          if (many.isNotEmpty) {
            // ★ 落ちた分を黙って捨てない (= これまでは titles に頼んだ分を
            //   全部並べつつ added だけ減っていたので、 何が出来なかったのか
            //   分からなかった)。
            final created = <Map<String, Object?>>[];
            final failed = <Map<String, Object?>>[];
            // ★ 同じ題名を 2 枚作ると、 後から題名では指せない
            //   (= 動作検証レポート 改善案 4)。 作るのは今までどおりだが、
            //   重なった分は必ず知らせる。
            final seen = <String>{};
            final dup = <String>[];
            // ★ = 継続検証 135「created.index が元の配列位置と一致しない」。
            //   空白を捨てた後の並びで番号を振り直していたので、 入力と
            //   作った id の対応付けが別の項目へずれていた。 元の配列を
            //   そのまま回し、 index は**呼び出し元の位置**を返す。
            final rawTexts = (a['texts'] as List);
            // 控えは 1 枚だけ (= 1 回の依頼を 1 回の取り消しで戻せる)。
            _provider.mcpPushUndo(pageId);
            _provider.beginUndoBatch(snapshot: false);
            try {
            for (var i = 0; i < rawTexts.length; i++) {
              // ★ = 機能追加案 継続検証237。 まとめて渡す時も 1 件ずつ
              //   url / memo を持てるようにする。 文字だけの書き方
              //   (["春","夏"]) は今までどおり (= add_node の nodes と同じ形)。
              final rawEntry = rawTexts[i];
              final Map<String, dynamic>? em =
                  rawEntry is Map ? rawEntry.cast<String, dynamic>() : null;
              final t =
                  (em == null ? '${rawEntry ?? ''}' : '${em['text'] ?? ''}')
                      .trim();
              final eMemo = em == null ? null : em['memo'] as String?;
              final eUrl = em == null ? null : em['url'] as String?;
              // 題名が空でも、 メモか URL があればタイルになる。
              if (t.isEmpty &&
                  !_hasContent(eMemo) &&
                  !_hasContent(eUrl)) {
                failed.add({
                  'index': i,
                  'text': '${rawEntry ?? ''}',
                  'reason': 'blank entry - a tile needs a title, a memo or a '
                      'url',
                });
                continue;
              }
              if (t.isNotEmpty && !seen.add(t.toLowerCase())) dup.add(t);
              // 入る枠を超えた分は作らずに理由を返す。
              if (galRoom > 0 && created.length >= galRoom) {
                failed.add({
                  'index': i,
                  'text': t,
                  'reason': 'gallery is full (at most '
                      '${MindMapProvider.kShelfMaxVisibleItems} items)',
                });
                continue;
              }
              final entryOut = <String, Object?>{};
              final id = _provider.mcpAddGalleryItem(
                pageId,
                text: t,
                memo: eMemo,
                url: eUrl,
                outcome: entryOut,
              );
              if (id == null) {
                failed.add({
                  'index': i,
                  'text': t,
                  'reason': galRoom >= 0
                      ? 'gallery is full (at most '
                          '${MindMapProvider.kShelfMaxVisibleItems} items)'
                      : 'not a gallery page (or page not found)',
                });
                continue;
              }
              created.add({
                'index': i,
                'nodeId': id,
                'title': t,
                if (entryOut['tileKind'] != null)
                  'tileKind': entryOut['tileKind'],
                if (entryOut['requestedUrl'] != null) ...{
                  'requestedUrl': entryOut['requestedUrl'],
                  'storedAs': entryOut['storedAs'],
                  'urlNote': entryOut['reason'],
                },
              });
            }
            } finally {
              _provider.endUndoBatch();
            }
            if (created.isEmpty) {
              return _err('not a gallery page (or page not found): $pageId '
                  '- use list_pages and pick a page whose type is '
                  '"bookshelf", or create one with create_page');
            }
            return _ok(_batchResult(
              created: created,
              failed: failed,
              extra: {
                'asked': rawTexts.length,
                // add_node と同じ鍵で返す (= 続けて指せるように)。
                // ★ = 継続検証 86。 大量追加では id の列挙だけで 12 万字に
                //   なっていたので、 上限を超えたら数だけ返す。
                if (created.length <= kBatchDetailCap)
                  'nodeIds': [for (final e in created) e['nodeId']]
                else
                  'nodeIdsNote': '${created.length} tiles were made; the id '
                      'list is left out to keep this reply short (call '
                      'read_page for them).',
                if (dup.isNotEmpty)
                  'note': 'these titles now appear more than once on the page '
                      '(${dup.take(20).join(', ')}'
                      '${dup.length > 20 ? ', …' : ''}): address those tiles '
                      'by nodeId, not by title.',
              },
            ));
          }
          // 題名も memo も絵も URL も無ければ、 中身の無いタイルは作らない。
          if (!_hasContent(a['text']) &&
              !_hasContent(a['memo']) &&
              !_hasContent(a['url']) &&
              !_hasContent(a['imagePath'])) {
            return _err('nothing to add: pass "texts" (an array of titles), '
                'or at least one of "text" / "memo" / "url" / "imagePath". '
                'No tile was created.');
          }
          // ★ 絵を渡された時は、 タイルを作る前に確かめる (= BUG-01:
          //   無いパスでも「壊れたタイル」 が出来て、 手で消すしか
          //   なかった)。 断る理由をそのまま返し、 何も作らない。
          final gimg = (a['imagePath'] as String? ?? '').trim();
          if (gimg.isNotEmpty) {
            final why = await _imagePathRejection(gimg);
            if (why != null) {
              return _err('imagePath rejected: $why: $gimg '
                  '- no tile was created.');
            }
          }
          // ★ = 継続検証 112「同名カードを単独追加した場合は重複注意が返らず、
          //   一括追加の場合だけ注意が返る」。 同じ注意をどちらの形でも返す。
          final gTitle = '${a['text'] ?? ''}'.trim();
          final gDup = gTitle.isNotEmpty &&
              (galPage?.nodes.values.any((n) =>
                      n.title.trim().toLowerCase() == gTitle.toLowerCase()) ??
                  false);
          // ★ = 機能追加案 継続検証237。 url を渡せばリンク / 動画タイル。
          final galOut = <String, Object?>{};
          final id = _provider.mcpAddGalleryItem(
            pageId,
            text: a['text'] as String?,
            memo: a['memo'] as String?,
            imagePath: gimg.isEmpty ? null : gimg,
            url: a['url'] == null ? null : '${a['url']}',
            outcome: galOut,
          );
          return id == null
              ? _err('not a gallery page (or page not found): $pageId')
              : _ok({
                  'nodeId': id,
                  if (galOut['tileKind'] != null)
                    'tileKind': galOut['tileKind'],
                  if (galOut['requestedUrl'] != null) ...{
                    'requestedUrl': galOut['requestedUrl'],
                    'storedAs': galOut['storedAs'],
                    'urlNote': '${galOut['reason']}. Tell the user the '
                        'address was kept as plain text, not as a link.',
                  },
                  if (gDup)
                    'note': '"$gTitle" now appears more than once on this '
                        'page: address these tiles by nodeId, not by title.',
                });
        }
      case 'add_paint_text':
        {
          final pageId = a['pageId'] as String? ?? '';
          // ★ = 継続検証 238 と同じ直し。 キャンバスの文字は折り返さないので
          //   字下げに意味がある。 前後の空白を残す。
          final many = _stringList(a['texts'], keepSpaces: true);
          final ptEmpty = _emptyBatch(
              a, 'texts', 'Pass at least one line, or send a single "text".',
              usable: many.length);
          if (ptEmpty != null) return ptEmpty;
          final lines = [
            for (final l in many.isNotEmpty
                ? many
                : [
                    if ((a['text'] as String? ?? '').isNotEmpty)
                      a['text'] as String
                  ])
              _unescapeLiteralNewlines(l),
          ];
          // text も texts も無い呼び出しは「空白だから捨てた」 ではない。
          if (lines.isEmpty) {
            return _err('add_paint_text needs text: put every line in '
                '"texts" (array of strings), or send a single "text".');
          }
          // ★ 空白だけの行は捨てられる仕様なので、 先に区別して返す
          //   (= 動作確認で判明: 「空白だけの行を 3 行」 と頼まれた時、
          //   ページ種別の間違いと同じ文面が返り、 AI が「フリーノートでは
          //   ありません」 と誤った理由を伝えていた)。
          if (lines.every((l) => l.trim().isEmpty)) {
            return _err('nothing was written: blank / whitespace-only text is '
                'discarded - this app cannot insert empty lines. Tell the '
                'user instead of retrying.');
          }
          // ★ = ユーザー報告「テキスト一括追加で、 成工件数と読み取り件数が
          //   一致しない場合がある」。 1 行ごとに prefs を読んで書いていたので、
          //   途中で開いているノートの遅延保存と競合して行が消えていた。
          //   provider 側で **1 回の読み書き**にまとめる。
          // ★ どの紙に書いたかを返す (= 入り切らずに次のタブへ続いた時、
          //   黙っていると AI が「1 枚に収めた」 と嘘を伝える)。
          // ★ = 継続検証 222「補正値が応答に出ない」。 頼まれた値を控えて、
          //   provider が丸めた実値と並べて返す。
          final reqX = numOf('x');
          final reqY = numOf('y');
          final reqSize = numOf('size');
          final usedSheets = <String>[];
          final placedOut = <String, Object?>{};
          final wrote = await _provider.mcpAddPaintTexts(
            pageId,
            lines,
            // ★ = 動作検証の不具合「複数文章を一括追加すると指定座標が
            //   無視される」。 以前はまとめ書きの時だけ捨てていた。 provider は
            //   どちらでも正しく扱う (省けば既存の下へ、 渡せばそこから
            //   1 行ずつ下へ) ので、 そのまま通す。
            x: reqX,
            y: reqY,
            size: reqSize,
            // ★ add_node と同じ正し方を通す (= 動作確認で判明: 「赤」 の
            //   つもりの 0xFF0000 は α=0 で透明になり、 文字が見えない
            //   まま成功と返っていた)。
            colorValue: _argbOf(a['color']),
            usedSheets: usedSheets,
            placedOut: placedOut,
          );
          // ★ = 継続検証 134「asked が元の入力件数を示さない」。 空白を捨てた
          //   後の数を asked と名乗っていたので、 呼ぶ側は「要求した全項目が
          //   保存された」 と読んでいた。 頼まれた数 / 使える数 / 書いた数 /
          //   捨てた数を分けて返す。
          final rawPt = a['texts'];
          final askedTotal = rawPt is List ? rawPt.length : lines.length;
          final usable = lines.where((l) => l.trim().isNotEmpty).length;
          final asked = usable;
          // ★ = 継続検証 222。 実際に置いた値を取り出し、 頼まれた値と
          //   ずれていたら clamped: true を立てる (黙って丸めるのが一番
          //   たちが悪い。 呼んだ側は言った通りに置けたと思い込む)。
          final gotX = (placedOut['x'] as num?)?.toDouble();
          final gotY = (placedOut['y'] as num?)?.toDouble();
          final gotSize = (placedOut['size'] as num?)?.toDouble();
          final paperW = (placedOut['paperWidth'] as num?)?.toDouble();
          final paperH = (placedOut['paperHeight'] as num?)?.toDouble();
          final wrapW = (placedOut['wrapWidth'] as num?)?.toDouble();
          bool moved(double? want, double? got) =>
              want != null && got != null && (want - got).abs() > 0.5;
          final clampedFields = <String>[
            if (moved(reqX, gotX)) 'x',
            if (moved(reqY, gotY)) 'y',
            if (moved(reqSize, gotSize)) 'size',
          ];
          return wrote > 0
              ? _ok({
                  'written': wrote,
                  'asked': askedTotal,
                  'usable': usable,
                  // 実際に置いた所・大きさ (read_paint_items と同じ名前)。
                  if (gotX != null) 'x': gotX,
                  if (gotY != null) 'y': gotY,
                  if (gotSize != null) 'size': gotSize,
                  if (reqX != null) 'requestedX': reqX,
                  if (reqY != null) 'requestedY': reqY,
                  if (reqSize != null) 'requestedSize': reqSize,
                  if (paperW != null) 'paperWidth': paperW,
                  if (paperH != null) 'paperHeight': paperH,
                  if (clampedFields.isNotEmpty) ...{
                    'clamped': true,
                    'clampedFields': clampedFields,
                    'clampedNote':
                        'The value(s) you gave were outside the sheet and were '
                        'moved (${clampedFields.join(" / ")}). The text really '
                        'sits at x=$gotX, y=$gotY with size=$gotSize on a '
                        '${paperW}x$paperH sheet: x is kept within '
                        '0..(paperWidth-120), y within '
                        '0..(paperHeight-lineHeight) and size within 6..200. '
                        'Tell the user the real position / size, not the one '
                        'you asked for.',
                  },
                  if (wrapW != null && gotSize != null && wrapW < gotSize * 3)
                    'narrowNote':
                        'Only ${wrapW}px of width was left for the text at '
                        'x=$gotX with size=$gotSize, so each line holds just a '
                        'character or two. Use a smaller x or a smaller size '
                        'if that is not what the user wanted.',
                  if (askedTotal > usable) ...{
                    'discarded': askedTotal - usable,
                    'discardedIndexes': [
                      if (rawPt is List)
                        for (var i = 0; i < rawPt.length; i++)
                          if ('${rawPt[i] ?? ''}'.trim().isEmpty) i
                    ],
                    'discardedNote':
                        '${askedTotal - usable} of $askedTotal entries were '
                        'blank / whitespace-only and were dropped - this app '
                        'cannot place empty lines. Tell the user the real '
                        'number.',
                  },
                  if (usedSheets.isNotEmpty) 'sheets': usedSheets,
                  if (usedSheets.length > 1)
                    'continued': 'The text did not fit on one sheet and '
                        'continues on ${usedSheets.length} tabs '
                        '(${usedSheets.join(" / ")}). Tell the user which '
                        'tabs it went on.',
                  if (wrote != asked)
                    'note': 'Only $wrote of $asked paragraphs were written - '
                        'the rest did not fit. Tell the user the real number.',
                })
              : _err('not a free-note page, or text empty: $pageId '
                  '- add_paint_text only works on pages whose type is '
                  '"paint"');
        }
      case 'list_paint_tabs':
        {
          final r = await _provider.mcpListPaintTabs(a['pageId'] as String? ?? '');
          return r == null
              ? _err('not a free-note page (pageType must be "paint"), or the '
                  'page was not found')
              : _ok(r);
        }
      case 'add_paint_tabs':
        {
          final names = _stringList(a['names']);
          final tabEmpty = _emptyBatch(a, 'names', 'Pass at least one name.',
              usable: names.length);
          if (tabEmpty != null) return tabEmpty;
          if (names.isEmpty) {
            return _err('pass the tab names in "names" (array of strings)');
          }
          final tabBinder = intOf('binder');
          if (intErr != null) return _err(intErr!);
          final added = await _provider.mcpAddPaintTabs(
              a['pageId'] as String? ?? '', names,
              binder: tabBinder);
          return added.isEmpty
              ? _err('could not add tabs - check that pageId is a free-note '
                  'page and that "binder" is a real index from list_paint_tabs')
              : _ok({'added': added});
        }
      case 'add_paint_binders':
        {
          final names = _stringList(a['names']);
          final bdEmpty = _emptyBatch(a, 'names', 'Pass at least one name.',
              usable: names.length);
          if (bdEmpty != null) return bdEmpty;
          if (names.isEmpty) {
            return _err('pass the binder names in "names" (array of strings)');
          }
          final added = await _provider.mcpAddPaintBinders(
              a['pageId'] as String? ?? '', names, 'Tab 1');
          return added.isEmpty
              ? _err('could not add binders - check that pageId is a '
                  'free-note page')
              : _ok({'added': added});
        }
      case 'select_paint_tab':
        {
          final selBinder = intOf('binder');
          final selTab = intOf('tab');
          if (intErr != null) return _err(intErr!);
          final ok = await _provider.mcpSelectPaintTab(
              a['pageId'] as String? ?? '',
              binder: selBinder,
              tab: selTab);
          return ok
              ? _ok({'ok': true})
              : _err('could not switch - check the indexes with '
                  'list_paint_tabs first');
        }
      case 'rename_paint_item':
        {
          final name = '${a['name'] ?? ''}'.trim();
          if (name.isEmpty) return _err('"name" is required');
          final rnBinder = intOf('binder');
          final rnTab = intOf('tab');
          if (intErr != null) return _err(intErr!);
          final ok = await _provider.mcpRenamePaintItem(
              a['pageId'] as String? ?? '',
              binder: rnBinder,
              tab: rnTab,
              name: name);
          return ok
              ? _ok({'ok': true})
              : _err('could not rename - check the indexes with '
                  'list_paint_tabs first');
        }
      // ── 作業用に作ったタブを片付ける (= ユーザー要望: 崩れた下書きを
      //    残さない) ──
      case 'delete_paint_item':
        {
          final dlBinder = intOf('binder');
          final dlTab = intOf('tab');
          if (intErr != null) return _err(intErr!);
          // ★ = 継続検証 154「削除失敗の原因がすべて同じ汎用エラーになる」。
          //   入力ミスと仕様上の保護を言い分ける。
          final dlOut = <String, Object?>{};
          final gone = await _provider.mcpDeletePaintItem(
              a['pageId'] as String? ?? '',
              binder: dlBinder,
              tab: dlTab,
              outcome: dlOut);
          if (gone != null) return _ok({'deleted': gone});
          final dlReason = '${dlOut['reason'] ?? ''}';
          switch (dlReason) {
            case 'pageNotFound':
              return _err('pageNotFound: ' +
                  _noPageMsg(a['pageId'] as String? ?? '',
                      did: 'Nothing was deleted.'));
            case 'wrongPageType':
              return _err('wrongPageType: delete_paint_item only works on a '
                  'free-note ("paint") page. Nothing was deleted.');
            case 'binderNotFound':
              return _err('binderNotFound: there is no binder '
                  '${dlBinder ?? '(selected)'} on that page (it holds '
                  '${dlOut['binderCount'] ?? '?'}). Call list_paint_tabs for '
                  'the real indexes. Nothing was deleted.');
            case 'tabNotFound':
              return _err('tabNotFound: there is no tab $dlTab in that binder '
                  '(it holds ${dlOut['tabCount'] ?? '?'}). Call '
                  'list_paint_tabs for the real indexes. Nothing was '
                  'deleted.');
            case 'lastTabProtected':
              return _err('lastTabProtected: a binder always keeps at least '
                  'one tab, so the last one cannot be deleted. Nothing was '
                  'deleted - delete the binder instead if that is what the '
                  'user wants.');
            case 'lastBinderProtected':
              return _err('lastBinderProtected: a free note always keeps at '
                  'least one binder, so the last one cannot be deleted. '
                  'Nothing was deleted.');
            case 'noBinders':
              return _err('noBinders: that page has no binder data yet - open '
                  'it once, or write to it first. Nothing was deleted.');
          }
          return _err('could not delete - call list_paint_tabs and check the '
              'indexes. Nothing was deleted.');
        }
      case 'write_markdown':
        {
          final pageId = a['pageId'] as String? ?? '';
          // ★ 相手が改行を「文字 2 つ (バックスラッシュ + n)」 のまま送って
          //   くる事がある (= ユーザー報告: CLI に作らせた本文が 1 行の
          //   長文になり、 ### も見出しにならない)。 本物の改行へ戻してから
          //   書く。 判定と限界は _unescapeLiteralNewlines の注記を参照。
          final text = _unescapeLiteralNewlines(a['text'] as String? ?? '');
          // ★ = 継続検証 170 / 171「空内容の保存が拒否されるため、 入門本文の
          //   自動挿入を抑止できない」。 本当に空へ戻したい時だけ clear:true。
          final mdClear = a['clear'] == true;
          if (text.trim().isEmpty && !mdClear) {
            return _err('"text" was empty - nothing was written. Write the '
                'markdown you want the page to hold, or pass clear:true to '
                'deliberately make the page empty.');
          }
          // ★ 「複数タブに分ける」 を CLI からも通す (= ユーザー要望)。
          //   文字でも真偽値でも受け取る (外の AI は enum を無視して
          //   true / false を送ってくる事があり、 as String? では落ちる)。
          final splitRaw = '${a['split'] ?? ''}'.trim().toLowerCase();
          final bool? splitMode = (splitRaw == 'single' ||
                  splitRaw == 'false' ||
                  splitRaw == 'no' ||
                  splitRaw == 'none')
              ? false
              : (splitRaw == 'tabs' ||
                      splitRaw == 'true' ||
                      splitRaw == 'yes' ||
                      splitRaw == 'multi')
                  ? true
                  : null;
          final mdOut = <String, Object?>{};
          final tabCount = await _provider.mcpWriteMarkdown(pageId, text,
              append: a['append'] == true,
              split: splitMode,
              clear: mdClear,
              outcome: mdOut);
          if (tabCount > 0) {
            final pageTabs = (mdOut['pageTabs'] as int?) ?? tabCount;
            final kept = (mdOut['otherTabsKept'] as int?) ?? 0;
            // ★ = 継続検証 197。 返すのは「受け取った量」 ではなく
            //   **保存できた量**。 取りこぼしを成功と言わない。
            final wroteTabs = (mdOut['wroteTabs'] as int?) ?? tabCount;
            final dropped = (mdOut['droppedLines'] as int?) ?? 0;
            final writtenChars = (mdOut['writtenChars'] as int?) ?? text.length;
            return _ok({
              'pageId': pageId,
              'written': writtenChars,
              'received': text.length,
              // ★ = 継続検証 109「split:"single" が既存の他タブを残すのに
              //   tabs:1 と返す」。 tabs は**書いた後のページ全体**のタブ数。
              //   この呼び出しで書いた枚数は wroteTabs で分けて返す。
              'tabs': pageTabs,
              'wroteTabs': wroteTabs,
              if (mdOut['wroteTo'] != null) 'wroteToTab': mdOut['wroteTo'],
              if (mdClear) 'cleared': true,
              if (wroteTabs > 1)
                'note': 'the document was laid out over $wroteTabs tabs on '
                    'this page',
              if (dropped > 0) 'droppedLines': dropped,
              if (dropped > 0)
                'droppedWarning': '$dropped line(s) of the document did NOT '
                    'reach a tab. Read the page back with read_markdown and '
                    'tell the user what is missing - do not report a clean '
                    'write.',
              // ★ written は**タブに入った本文**の文字数。 区切り行
              //   (<<<PAGE:…>>>) と区画の間の空行は保存しないので、 received
              //   より必ず小さく出る。 そこを「大半が落ちた」 と読み違えて
              //   報告されないよう、 差が目に付く時だけ訳を添える
              //   (末尾の改行だけの差では黙る)。
              if (dropped == 0 && text.length - writtenChars > 8)
                'writtenNote': 'written counts only the body stored in tabs; '
                    '<<<PAGE:...>>> separator lines, the blank lines between '
                    'sections and surrounding whitespace are not stored. '
                    'Nothing was lost - do not report missing content.',
              if (kept > 0)
                'otherTabsKept': kept,
              if (kept > 0)
                'keptNote': 'this write only replaced the tab that was open; '
                    '$kept other tab(s) on the page were left as they were. '
                    'Say so instead of reporting a one-tab page. Use '
                    'split:"tabs" with the whole document, or clear:true '
                    'first, to end up with only the new tabs.',
            });
          }
          final page = _provider.mcpPageById(pageId);
          if (page == null) {
            return _err('no page has the id "$pageId" - call list_pages and '
                'use an id from it, or make one with create_page '
                'type:"markdown".');
          }
          if (page.pageType != 'markdown') {
            return _err('"$pageId" is a "${page.pageType}" page, not a '
                '"markdown" one. Either convert it with set_page_type '
                '"markdown", or make a new page with create_page '
                'type:"markdown" and write into that.');
          }
          // ★ 開いていたのが Web タブ = 保存の失敗ではない。 原因を取り
          //   違えると AI が「アプリが保存できませんでした」 と嘘を伝える。
          if (mdOut['reason'] == 'web_tab_selected') {
            final wtName = '${mdOut['tabName'] ?? ''}'.trim();
            final wtLabel = wtName.isEmpty ? '' : ' ("$wtName")';
            return _err('the tab that is open on "$pageId" is a WEB '
                'tab$wtLabel - it shows a web page and holds no markdown '
                'body, so NOTHING was written or cleared. This is not a save '
                'failure. clear:true does not get past this either, on '
                'purpose: clearing would throw away the web tab the user '
                'made. There is no tool that changes which tab is open - ask '
                'the user to switch that page to a text tab, or write into '
                'another markdown page. Do not retry as is.');
          }
          // 種類は合っているのに書けなかった = 保存できなかった。
          //   「markdown なのに markdown ではない」 と言わないこと。
          return _err('"$pageId" is a markdown page but the write failed '
              '(the app could not save it). Do not retry in a loop - tell '
              'the user the page could not be saved.');
        }
      case 'append_document_text':
        {
          final pageId = a['pageId'] as String? ?? '';
          // ★ = 継続検証 238。 本文なので**前後の空白を残す**
          //   (空白だけの要素は _stringList が落とす)。
          final many = _stringList(a['texts'], keepSpaces: true);
          final adEmpty = _emptyBatch(a, 'texts',
              'Pass at least one paragraph, or send a single "text".',
              usable: many.length);
          if (adEmpty != null) return adEmpty;
          // ★ = 継続検証 146「text と texts の同時指定で単独側を黙って無視
          //   する」。 引数の組み立てミスで文章が欠落しても成功扱いに
          //   なっていたので、 食い違った依頼は実行せずに断る。
          if (many.isNotEmpty && '${a['text'] ?? ''}'.trim().isNotEmpty) {
            return _err('"texts" (the array form) and "text" (the single '
                'form) were both given. Nothing was appended - the single '
                'paragraph would have been dropped silently. Put every '
                'paragraph in "texts", or send only "text".');
          }
          final paras = [
            for (final p in many.isNotEmpty
                ? many
                : [
                    if ((a['text'] as String? ?? '').isNotEmpty)
                      a['text'] as String
                  ])
              _unescapeLiteralNewlines(p),
          ];
          // 空白だけの段落は捨てられる (add_paint_text と同じ理由)。
          if (paras.every((p) => p.trim().isEmpty)) {
            return _err('nothing was appended: blank / whitespace-only text '
                'is discarded - this app cannot insert empty lines. Tell the '
                'user instead of retrying.');
          }
          // ★ = 動作検証レポート 2026-09-24 不具合 1「新規文書ページの初回
          //   複数段落追加で先頭段落が欠落する」。 旧: 段落ごとに provider を
          //   呼んでいたので、 その合間に走る prefs の控えの入れ替えで
          //   先に書いた段落が無かった事になり、 作り直しで消えていた。
          //   provider 側で **1 回の読み書き**にまとめる
          //   (add_paint_text と同じ直し方)。
          // ★ = 動作検証の不具合「フリーノートの文書追記がタブごとに
          //   分かれない」。 フリーノートは**今開いているタブの**文書の層へ
          //   入るようになったので、 どのタブへ入れたかをそのまま返す。
          final paintPage =
              _provider.mcpPageById(pageId)?.pageType == 'paint';
          ({int wrote, int binder, int tab, String tabName})? paint;
          int wrote;
          if (paintPage) {
            paint = await _provider.mcpAppendPaintDocTexts(pageId, paras);
            wrote = paint?.wrote ?? 0;
          } else {
            wrote = await _provider.mcpAppendDocumentTexts(pageId, paras);
          }
          // ★ = 継続検証 146「asked が元の入力件数を示さない」。
          final rawAd = a['texts'];
          final adAskedTotal = rawAd is List ? rawAd.length : paras.length;
          final adUsable = paras.where((p) => p.trim().isNotEmpty).length;
          final asked = adUsable;
          return wrote > 0
              ? _ok({
                  'appended': wrote,
                  'asked': adAskedTotal,
                  'usable': adUsable,
                  // ★ = 継続検証 238。 保存した文字数をそのまま返す。
                  //   読み戻した文字数と比べれば、 空白落ちを AI 自身が
                  //   見つけられる (件数だけでは分からない)。 読み戻しは
                  //   段落を閉じる改行が 1 文字ずつ増えるので、
                  //   「読み戻し = chars + 段落数」 が揃っている印。
                  'chars': paras.fold<int>(0, (n, p) => n + p.length),
                  if (paras.length <= kBatchDetailCap)
                    'charsPerParagraph': [for (final p in paras) p.length],
                  if (adAskedTotal > adUsable) ...{
                    'discarded': adAskedTotal - adUsable,
                    'discardedIndexes': [
                      if (rawAd is List)
                        for (var i = 0; i < rawAd.length; i++)
                          if ('${rawAd[i] ?? ''}'.trim().isEmpty) i
                    ],
                    'discardedNote':
                        '${adAskedTotal - adUsable} of $adAskedTotal entries '
                        'were blank / whitespace-only and were dropped - this '
                        'app cannot insert empty paragraphs.',
                  },
                  // ★ どこへ書いたかを必ず言う。 フリーノートの文書の層は
                  //   **紙 (タブ) ごと**なので、 別のタブへ置きたい時は
                  //   select_paint_tab で先に選んでから呼ぶ。
                  'scope': paintPage ? 'sheet' : 'document',
                  if (paint != null) 'binder': paint.binder,
                  if (paint != null) 'tab': paint.tab,
                  if (paint != null && paint.tabName.isNotEmpty)
                    'tabName': paint.tabName,
                  if (paintPage)
                    'scopeNote': 'it went into the document layer of the tab '
                        'that is open right now - binder "binder", tab '
                        '"tab" in this reply. Call list_paint_tabs / '
                        'select_paint_tab first to append to another binder '
                        'or tab; read_document reads EVERY binder and EVERY '
                        'tab back in one call.',
                  if (wrote != asked)
                    'note': 'Only $wrote of $asked paragraphs were appended. '
                        'Tell the user the real number.',
                })
              // ★ = 動作検証の不具合「追記が成功しているのに失敗として
              //   返る / 文書ページなのに種類違いと案内される」。 ページを
              //   引き直して、 本当の理由だけを言う。
              : _err(() {
                  final p = _provider.mcpPageById(pageId);
                  if (p == null) {
                    return _noPageMsg(pageId,
                        did: 'Nothing was appended.');
                  }
                  final ty = p.pageType ?? 'normal';
                  if (ty != 'document' && ty != 'paint') {
                    return '"$pageId" is a "$ty" page: append_document_text '
                        'works only on "paint" (free note) or "document" '
                        '(notepad) pages. For a "markdown" page use '
                        'write_markdown instead.';
                  }
                  return '"$pageId" is a "$ty" page but the text could not be '
                      'saved. Do NOT retry in a loop - call read_document '
                      'first: the text may already be there.';
                }());
        }
      case 'add_video_editor_item':
        {
          // 道具一覧に出していなくても、 名前を直接送られればここに来る。
          if (kStoreBuild) {
            return _err('the video editor is not available in this build');
          }
          final pageId = a['pageId'] as String? ?? '';
          // ★ 1.5 秒のつもりで 1.5 を渡されると、 黙って 1 ミリ秒に切り捨てて
          //   成功と返していた (= 動作確認で判明)。 単位の取り違えは丸めずに
          //   突き返す。 手で書いていた検査は _intOf へ寄せた (= 動作検証
          //   レポート 不具合 3: 同じ取り違えが他の道具にも残っていたため)。
          final veStart = intOf('startMs');
          final veDuration = intOf('durationMs', min: 1);
          // レーンは 6 本しか無い。 範囲外は丸めずに突き返す。
          final veLayer = intOf('layer', min: 0, max: 5);
          // ★ 色は「番号」 ではなく 32 ビットの ARGB。 整数の検査に掛けると、
          //   不透明な色 (先頭が 0x80 以上) が軒並み弾かれて字幕そのものが
          //   置けなくなる (= 粗探しで発見)。 他の道具と同じ _argbOf で読む。
          final veColor = _argbOf(a['color']);
          if (intErr != null) {
            // ★ = 継続検証 240「レーンの範囲エラーに時刻の補足が混ざる」。
            //   レーン番号とミリ秒は無関係なので、 時刻の引数で転けた時だけ
            //   補足を付ける。
            return _err(const {'startMs', 'durationMs'}.contains(intErrKey)
                ? '$intErr '
                    '(milliseconds are whole numbers: 1.5 seconds = 1500)'
                : intErr!);
          }
          final veEmpty = _emptyBatch(a, 'texts',
              'Pass at least one caption, or use the single "kind"/"text" '
              'form.',
              usable: _stringList(a['texts']).length);
          if (veEmpty != null) return veEmpty;
          // ★ = 動作検証 継続検証 200「24 時間上限が追加と更新で一致しない」。
          //   上限の検査が update_video_editor_item 側にしか無かったので、
          //   共通の [MindMapProvider.mcpVideoTimelineRangeError] を追加からも
          //   通す。 まとめ形は後ろへ並べて置くので、 最後の字幕の終わりで見る
          //   (startMs を省いた時は置く側が同じ関数で受け止める)。
          if (veStart != null) {
            final veSlots = a['texts'] is List
                ? math.max(1, _stringList(a['texts']).length)
                : 1;
            final veRangeErr = MindMapProvider.mcpVideoTimelineRangeError(
                veStart, (veDuration ?? 4000) * veSlots);
            if (veRangeErr != null) {
              return _err('$veRangeErr Nothing was added.');
            }
          }
          // まとめて字幕を置ける形 (= 1 件ずつだと AI が取りこぼす)。
          final batch = a['texts'];
          if (batch is List && batch.isNotEmpty) {
            // ★ = 動作検証レポート 2026-09-25 不具合 9「返却数と保存数が
            //   一致しない」。 1 件ずつ回すと、 読み書きの間に挟む
            //   prefs.reload() で直前の分が控えから消え、 末尾だけが
            //   残って先の分が上書きで消えていた。 まとめて 1 回で書く。
            final wanted = <String>[
              for (final e in batch)
                if ('${e ?? ''}'.trim().isNotEmpty) '${e ?? ''}'.trim()
            ];
            final ids = await _provider.mcpAddVideoEditorItems(
              pageId,
              kind: 'text',
              texts: wanted,
              startMs: veStart,
              layer: veLayer ?? 1,
              durationMs: veDuration,
              fontSize: numOf('fontSize'),
              colorValue: veColor,
            );
            if (ids.isEmpty) {
              // ★ = 動作検証の気になった点「素材不足がページ種類の誤りとして
              //   案内される」 の残り。 1 件形は理由を言い分けていたのに、
              //   まとめ形だけが四つの原因を同じ文面で返していた。
              return _err(() {
                final p = _provider.mcpPageById(pageId);
                if (p == null) {
                  return _noPageMsg(pageId, did: 'Nothing was added.');
                }
                if ((p.pageType ?? '') != 'videoEditor') {
                  return '"$pageId" is a "${p.pageType ?? 'normal'}" page, '
                      'not a "videoEditor" one. Nothing was added.';
                }
                if (wanted.isEmpty) {
                  return 'every caption was blank - a caption needs real '
                      'characters. Nothing was added.';
                }
                if (kStoreBuild) {
                  return 'the video editor is not available in this build of '
                      'the app. Nothing was added.';
                }
                return 'the page is a videoEditor but nothing could be saved. '
                    'Call list_video_editor_items before retrying.';
              }());
            }
            // 保存し終えた件数だけを返す (要求と食い違ったらそれも返す)。
            // ★ = 継続検証 145「requested が元の入力件数を示さない」。
            //   空白を捨てた後の数を requested と名乗っていたので、 呼ぶ側は
            //   要求した全字幕が保存されたと読んでいた。
            return _ok({
              'itemIds': ids,
              'requested': batch.length,
              'usable': wanted.length,
              'persisted': ids.length,
              if (batch.length > wanted.length) ...{
                'discarded': batch.length - wanted.length,
                'discardedIndexes': [
                  for (var i = 0; i < batch.length; i++)
                    if ('${batch[i] ?? ''}'.trim().isEmpty) i
                ],
                'discardedNote': '${batch.length - wanted.length} of '
                    '${batch.length} entries were blank / whitespace-only and '
                    'were dropped - a caption needs real characters.',
              },
              if (ids.length != wanted.length)
                'failed': wanted.length - ids.length,
              // ★ = 継続検証 100「複数字幕追加時の startMs が説明と異なる」。
              //   実挙動 (先頭の開始時刻として使い、 以降は長さぶん後ろへ
              //   並べる) を返事にも書いて、 説明と食い違わせない。
              if (veStart != null)
                'startMsNote': 'with "texts", "startMs" is the start of the '
                    'FIRST caption; the rest follow one after another, each '
                    'one "durationMs" later.',
              // ★ = 継続検証 240 と同じ穴のまとめ形。 描ける範囲へ丸めたのに
              //   返事へ出さないと、 頼んだ大きさで入ったと読まれる。
              ...(() {
                final asked = numOf('fontSize');
                if (asked == null) return const <String, Object?>{};
                final got = asked.clamp(MindMapProvider.kVideoCaptionMinFont,
                    MindMapProvider.kVideoCaptionMaxFont);
                if (got == asked) return const <String, Object?>{};
                return <String, Object?>{
                  'fontSize': got,
                  'clamped': true,
                  'clampedNote': 'fontSize $asked is outside the range this '
                      'editor can draw '
                      '(${MindMapProvider.kVideoCaptionMinFont} - '
                      '${MindMapProvider.kVideoCaptionMaxFont}); $got was '
                      'stored on every caption instead. Report the stored '
                      'size, not the one you asked for.',
                };
              })(),
            });
          }
          final id = await _provider.mcpAddVideoEditorItem(
            pageId,
            kind: a['kind'] as String? ?? '',
            text: a['text'] as String?,
            path: a['path'] as String?,
            startMs: veStart,
            durationMs: veDuration,
            layer: veLayer,
            fontSize: numOf('fontSize'),
            colorValue: veColor,
          );
          return id == null
              // ★ = 動作検証の気になった点「素材不足がページ種類の誤りとして
              //   案内される」。 4 つの原因が同じ文面だったので、 足りない物を
              //   名指しする。
              ? _err(() {
                  final p = _provider.mcpPageById(pageId);
                  if (p == null) {
                    return _noPageMsg(pageId, did: 'Nothing was added.');
                  }
                  if ((p.pageType ?? '') != 'videoEditor') {
                    return '"$pageId" is a "${p.pageType ?? 'normal'}" page, '
                        'not a "videoEditor" one. Nothing was added.';
                  }
                  // ★ 大小文字や前後の空白を**均さずに**見る (= 置く側は
                  //   生の文字で引き当てるので、 ここで均すと 'Text' の時に
                  //   「保存できなかった」 と言ってしまう)。
                  final k = a['kind'] as String? ?? '';
                  if (!const {'video', 'text', 'image'}.contains(k)) {
                    return '"kind" must be exactly "text", "video" or "image" '
                        '- lower case, no spaces (got "${a['kind']}"). '
                        'Nothing was added.';
                  }
                  if (k == 'text' && '${a['text'] ?? ''}'.trim().isEmpty) {
                    return '"text" is empty: a caption needs real characters '
                        '(blank text is discarded). Nothing was added.';
                  }
                  if (k != 'text' && '${a['path'] ?? ''}'.trim().isEmpty) {
                    return '"path" is required for kind "$k" - pass the file '
                        'path. Nothing was added.';
                  }
                  return 'the page is a videoEditor but the item could not be '
                      'saved (when "startMs" is left out, the next free slot '
                      'on that layer may already be past the 24-hour limit). '
                      'Call list_video_editor_items before retrying.';
                }())
              // ★ = 継続検証 240「字幕の文字サイズが 6〜200 へ丸められるのに、
              //   追加の返事は itemId だけ」。 書き換え側は保存後の値を返して
              //   いるので、 追加もそろえる (丸めた時は clamped も立てる)。
              : _ok({'itemId': id, ...await _videoItemEcho(pageId, id, a)});
        }
      case 'create_document_file':
        try {
          final kind = (a['kind'] as String? ?? '').toLowerCase();
          final slides = _slidesOf(a['slides']);
          // ★ 中身の無い pptx を黙って作らない (= 動作確認で判明: slides を
          //   読めない形で渡すと、 表紙だけの空スライドが出来て成功が返る)。
          if (kind == 'pptx' && slides.isEmpty) {
            return _err('pptx needs "slides": '
                '[{"title":"…","bullets":["…"]}] - nothing was created.');
          }
          final reqId = a['pageId'] as String? ?? '';
          // ★ = 動作検証 継続検証206「添付を持てないページを名指ししても
          //   断らず、 今開いている別のページへタイルを置いてしまう」。
          //   名指しされた時は**何も作らずに**断る (今のページへ逃げるのは
          //   pageId を省かれた時だけ。 注意書きで伝えても、 頼んでいない
          //   ページに物が増えるのは事故)。 ここで返せば、 ディスクにも
          //   ページにも 1 文字も書かれていない。
          if (reqId.trim().isNotEmpty && !_provider.mcpCanHoldFileNode(reqId)) {
            final want = _provider.mcpPageById(reqId);
            // ★ 「そんな id は無い」 と「プランで開けない」 を言い分ける
            //   (_noPageMsg)。 鍵の掛かったページは list_pages に
            //   locked: true で出ているので、 「無い (かも)」 と返すと
            //   一覧と話が合わず、 直しようが無くなる。
            if (want == null) {
              final why = _noPageMsg(reqId, did: 'Nothing was created.');
              return _err('$why Or leave "pageId" out to use the page the '
                  'user has open.');
            }
            final ty = want.pageType;
            return _err('target page cannot hold attachments: page "$reqId" '
                'is a "$ty" page and cannot hold a file tile - nothing was '
                'created. Pass a mind map ("normal") or gallery '
                '("bookshelf") pageId, or leave "pageId" out to use the '
                'page the user has open.');
          }
          // ★ 名前が書かれていない時、 そのページに同じ種類のファイルが
          //   ちょうど 1 つだけあれば、 それを書き換える
          //   (= ユーザー報告: 資料を作らせた後に「おしゃれな資料にして」
          //   と言うと、 直すのではなく新しい pptx が出来てしまう)。
          //   「作り直して」 の意味で言われるのが普通なので、 同じ物へ
          //   向ける。 2 つ以上ある時は決められないので今までどおり新規。
          var fileName = '${a['fileName'] ?? ''}'.trim();
          if (fileName.isEmpty) {
            final same = _provider.mcpAttachmentsOfKind(reqId, kind);
            if (same.length == 1) fileName = same.first;
          }
          final made = await _provider.mcpCreateFile({
            'pageId': reqId,
            'kind': kind,
            'fileName': fileName,
            'title': a['title'] as String? ?? '',
            // ★ = 継続検証 283。 本物のファイルなので**原文のまま**渡す
            //   (字下げも空段落も、 頼まれた見た目の一部)。
            'paragraphs': _stringList(a['paragraphs'],
                keepSpaces: true, keepEmpty: true),
            'rows': _rowsOf(a['rows']),
            'slides': slides,
            // ★ 配色と「後ろへ足すだけ」 を画面側へ渡す (= 動作確認で判明:
            //   この 2 つは道具の説明には書いてあるのに、 ここで渡し忘れて
            //   いたので、 配色を指定しても効かず、 追記も新規作成に
            //   なっていた)。
            'theme': '${a['theme'] ?? ''}',
            'append': a['append'] == true,
          });
          final rawPath = made?['path'] as String?;
          if (rawPath == null) {
            return _err('could not create the file (unsupported kind, or the '
                'page was not found)');
          }
          // ★ = 動作検証 継続検証 87「作成ツールの返却パスをそのまま読み取りへ
          //   渡すと完了しない」。 組み立ての途中で `\` と `/` が混ざった道筋
          //   (…\913/名前.txt) をそのまま返していたので、 同じファイルだと
          //   判定されず、 読み取りの許可も当たらなかった。 返す道筋は
          //   必ず正規形へ揃える (他の道具の返り値と同じ物差し)。
          final path = MindMapProvider.mcpNormalizePath(rawPath);
          // ★ 上書きした時に「新しく作りました」 と答えさせない (= ユーザー
          //   報告: 直してと頼んだのに 2 つ目が出来たと言われた)。
          final replaced = made?['replaced'] == true;
          // ★ = 動作検証 継続検証245。 ファイルの上書きと、 タイルが新しく
          //   置かれたかは別の出来事 (タイルだけ消して孤立させたファイルを
          //   同じ名前で作り直すと、 中身は上書き・タイルは新規になる)。
          //   まとめて「同じタイルのまま」 と言わせない。
          final tileCreated = made?['tileCreated'] == true;
          // ★ = 継続検証384 の残り。 「札は新しく出来た」 と返すのに、 その
          //   **新しい要素 id** を返していなかったので、 続けてその札を直せ
          //   なかった (画面側は nodeId を返している。 ここで落としていた)。
          final nodeId = '${made?['nodeId'] ?? ''}'.trim();
          final replacedNote = tileCreated
              ? 'The file that was already there was REWRITTEN IN PLACE (no '
                  'second file was made), but its tile was gone, so a NEW '
                  'tile was placed on the page - its id is in "nodeId", so '
                  'use that id from now on. Say the file was updated and that '
                  'a new tile was added for it.'
              : 'The file that was already there was REWRITTEN IN PLACE (same '
                  'name, same tile ("nodeId") - no second file and no second '
                  'tile were made). Tell the user the file was updated, not '
                  'created.';
          // ★ = 動作検証 継続検証385「添付ファイルの同名上書きがページの Undo
          //   対象外」。 undo_page はページの中身 (タイル) を戻す道具で、
          //   ディスクへ書いた中身は戻さない。 黙っていると「取り消せます」 と
          //   案内されてしまうので、 上書きした時は必ず言わせる。 書く前に
          //   控えた前の版があれば、 その道筋も一緒に返す。
          // ★ 写しから書き戻せるのは txt / md / csv まで。 xlsx / docx / pptx /
          //   pdf は read_device_file が**抜き出した文字**しか返さないので、
          //   それを元に書き直すと表や版面が落ちたまま「戻した」 と答えて
          //   しまう (= _mcpRestoreTrashedFiles へ結ばなかったのと同じ理由)。
          //   その種類は道筋を利用者へ渡すだけにさせる。
          final prevVersion = '${made?['previousVersionPath'] ?? ''}'.trim();
          final prevNote = prevVersion.isEmpty
              ? 'No copy of the previous version could be kept, so those old '
                  'contents are gone - say so plainly if the user asks to go '
                  'back.'
              : 'A copy of the version from just before this call is kept for '
                  '7 days at "previousVersionPath". For txt, md and csv you '
                  'can put it back: read that copy with read_device_file (it '
                  'needs no extra permission) and call this tool again with '
                  'the SAME fileName. For xlsx, docx, pptx and pdf do NOT do '
                  'that - read_device_file gives you only the TEXT pulled out '
                  'of the file, so rewriting from it would drop the tables, '
                  'slides and layout while looking like a restore; hand the '
                  'user that exact path instead and let them copy it back. '
                  'Never say the old contents are lost without mentioning '
                  'it.';
          final undoNote = 'THE OVERWRITE ITSELF CANNOT BE UNDONE: undo_page '
              'and Ctrl+Z only put the page and its tiles back, never the '
              'contents of a file on disk - and this call adds no undo step '
              'at all, so undo_page answers "no_history" for it. $prevNote';
          // ★ 貼れたかどうかを見て返す (= 動作確認で判明: フリーノートの
          //   ページを渡すとタイルを置く場所が無く、 ファイルはどこにも
          //   貼られないのに成功と返っていた。 別のページへ逃げる事もある)。
          final reqPage = _provider.mcpPageById(reqId);
          // ★ 突き合わせは区切り文字と大小文字を吸収して見る (返す道筋を
          //   正規形へ揃えたので、 == だと保存側の生の文字と一致しない)。
          bool holds(dynamic p) =>
              p != null &&
              p.nodes.values.any((n) =>
                  MindMapProvider.mcpSamePath(n.attachmentPath ?? '', path));
          if (holds(reqPage)) {
            return _ok({
              'path': path,
              'attachedToPageId': reqPage!.id,
              if (nodeId.isNotEmpty) 'nodeId': nodeId,
              'replaced': replaced,
              'fileReplaced': replaced,
              'tileCreated': tileCreated,
              if (replaced) 'undoable': false,
              if (prevVersion.isNotEmpty) 'previousVersionPath': prevVersion,
              if (replaced) 'note': '$replacedNote $undoNote',
            });
          }
          String? hostId;
          for (final p in _provider.pages) {
            if (holds(p)) {
              hostId = p.id;
              break;
            }
          }
          final hostNote = hostId == null
              ? 'The file WAS saved at this path but is NOT pinned to any '
                  'page: a "${reqPage?.pageType ?? 'unknown'}" page cannot '
                  'hold a file tile. Tell the user the path, or ask for a '
                  'mind map ("normal") or gallery ("bookshelf") page.'
              : 'The requested page cannot hold a file tile, so it was '
                  'pinned to page $hostId instead - say so rather than '
                  'claiming it is on the page that was asked for.';
          return _ok({
            'path': path,
            if (hostId != null) 'attachedToPageId': hostId,
            if (nodeId.isNotEmpty) 'nodeId': nodeId,
            'replaced': replaced,
            'fileReplaced': replaced,
            'tileCreated': tileCreated,
            if (replaced) 'undoable': false,
            if (prevVersion.isNotEmpty) 'previousVersionPath': prevVersion,
            // ★ = 継続検証385。 貼れなかった時も上書きは起きているので、
            //   「戻せない」 は同じように言わせる (note で覆い隠さない)。
            'note': replaced ? '$replacedNote $undoNote $hostNote' : hostNote,
          });
        } catch (e, st) {
          // 理由が分からないと直せないので、 画面にもログにも残す。
          // ignore: avoid_print
          print('[MCP] create_document_file failed: $e / $st');
          return _err('file creation failed: $e');
        }
      case 'list_app_commands':
        // ★ needsUser を文字列 "true" のまま返すと、 型に厳しい相手が
        //   判定を誤る (= 動作検証レポート)。 本物の真偽値に直して返す。
        return _ok([
          for (final c in _provider.mcpCommands)
            {
              for (final e in c.entries)
                if (e.key != 'needsUser' && e.key != 'noScreen')
                  e.key: e.value,
              if (c['needsUser'] == 'true') 'needsUser': true,
              // ★ = 継続検証 251。 その場で終わる操作の印 (= これが true の
              //   物へ close_app_command を呼ばせない)。
              if (c['noScreen'] == 'true') 'noScreen': true,
            }
        ]);
      case 'update_decoration':
        {
          final pageId = a['pageId'] as String? ?? '';
          final did = '${a['decorationId'] ?? ''}'.trim();
          if (did.isEmpty) return _err('"decorationId" is required');
          // ★ 足せないなら直せてもいけない (= 点検で判明: add_decoration だけ
          //   ギャラリーを断っていたので、 種類を normal → bookshelf へ変えた
          //   ページに残った図形を、 ここから動かし放題だった)。
          final updTarget = _provider.mcpPageById(pageId);
          if (updTarget != null && updTarget.pageType == 'bookshelf') {
            return _err('"$pageId" is a gallery (bookshelf) page: shapes are '
                'not used there, so they cannot be changed either. Nothing '
                'was changed. Offer set_page_type "normal" first if the user '
                'really wants shapes on that page.');
          }
          final dLayer = intOf('layer', min: -1 << 31);
          if (intErr != null) return _err(intErr!);
          final argb = _argbOf(a['color']);
          final decoOut = <String, Object?>{};
          final ok = _provider.mcpUpdateDecoration(
            pageId,
            did,
            kind: a['kind'] as String?,
            colorRgb: argb == null ? null : (argb & 0xFFFFFF),
            strokeWidth: _numOf(a['strokeWidth']),
            text: a['text'] as String?,
            filled: a['filled'] is bool ? a['filled'] as bool : null,
            layer: dLayer,
            outcome: decoOut,
          );
          if (ok) {
            // ★ = 継続検証 261 / 306 / 364 / 365 / 368「同じ値 (や空) の更新が
            //   updated と返り、 取り消し履歴を 1 手食う」。 丸めた後の値が今と
            //   同じなら、 provider は何も書かずに unchanged を立てる。
            //   update_node と同じ返し方に揃える。
            if (decoOut.remove('unchanged') == true) {
              return _ok({
                'updated': false,
                'unchanged': true,
                'decorationId': did,
                ...decoOut,
                'reason': 'every value passed already matched the shape (the '
                    'line width is rounded into 0.5-40 first, so -1 and 0 '
                    'both mean 0.5), so nothing was written, nothing was '
                    'saved and no undo step was used.',
              });
            }
            // ★ = 継続検証 107 / 129 / 141 / 181。 実際に保存された全属性を
            //   返す (指定していない塗りが消えていた事、 負の線幅がそのまま
            //   入っていた事、 層を丸めた事に呼ぶ側が気付けなかった)。
            return _ok({'updated': did, ...decoOut});
          }
          // 知らない id と知らない形を言い分ける (= 継続検証 181 の補足:
          //   「図形 ID が無い、 または種類が不正」 では直しようが無い)。
          final decoPage = _provider.mcpPageById(pageId);
          if (decoPage == null) {
            return _err(_noPageMsg(pageId, did: 'Nothing was changed.'));
          }
          if (!decoPage.decorations.any((d) => d.id == did)) {
            return _err('no decoration has the id "$did" on "$pageId" - '
                'read_page lists them under "decorations". Nothing was '
                'changed.');
          }
          return _err('"${a['kind']}" is not a shape name this app can draw '
              '(read_page shows the names it uses under "decorations"; '
              '"polyline" cannot be set from here). The shape was left '
              'exactly as it was.');
        }
      case 'update_video_editor_item':
        {
          final pageId = a['pageId'] as String? ?? '';
          // ★ = 継続検証 264「remove:true でも、 無視するはずの更新値が先に
          //   検証され削除できない」。 消すかどうかを**最初に**決める。
          //   下の 148 で値そのものは無視していたのに、 範囲の検査だけは
          //   手前に残っていたので、 startMs:-1 を併記すると削除を
          //   断っていた (要らない値の妥当性で後片付けを止めない)。
          final vRemove = a['remove'] == true;
          final vLayer = intOf('layer', min: 0, max: 5);
          final vStart = intOf('startMs');
          final vDur = intOf('durationMs', min: 1);
          if (!vRemove && intErr != null) {
            // ★ = 継続検証 240「レーンの範囲エラーに時刻の補足が混ざる」
            //   (追加側と同じ直し)。
            return _err(const {'startMs', 'durationMs'}.contains(intErrKey)
                ? '$intErr '
                    '(milliseconds are whole numbers: 1.5 seconds = 1500)'
                : intErr!);
          }
          // ★ = 継続検証 148「削除指定でも併記した更新値の検証により削除が
          //   拒否される」。 消すなら更新用の値は見ない (要らない値の妥当性で
          //   削除だけ失敗すると、 後片付けが出来なくなる)。 呼ぶ側には
          //   「無視した」 と伝える (vRemove は上で決めている)。
          final vIgnored = <String>[
            if (vRemove)
              for (final k in const [
                'layer',
                'startMs',
                'durationMs',
                'text',
                'fontSize',
                'color'
              ])
                if (a.containsKey(k)) k
          ];
          final r = await _provider.mcpEditVideoEditorItem(
            pageId,
            '${a['itemId'] ?? ''}',
            layer: vRemove ? null : vLayer,
            startMs: vRemove ? null : vStart,
            durationMs: vRemove ? null : vDur,
            text: vRemove ? null : a['text'] as String?,
            // ★ = 継続検証 123「既存字幕の見た目を後から変えられない」。
            fontSize: vRemove ? null : _numOf(a['fontSize']),
            colorValue: vRemove ? null : _argbOf(a['color']),
            remove: vRemove,
          );
          return r['ok'] == true
              ? _ok({
                  ...r,
                  if (vIgnored.isNotEmpty) ...{
                    'ignored': vIgnored,
                    'note': 'remove:true deletes the item, so the update '
                        'fields that came with it were not used (they no '
                        'longer had anything to apply to).',
                  },
                })
              : _err('could not change the timeline item: ${r['reason']}');
        }
      case 'list_orphan_files':
        {
          final files = await _provider.mcpOrphanGeneratedFiles();
          return _ok({
            'count': files.length,
            'files': files,
            'note': files.isEmpty
                ? 'nothing left over'
                : 'these were created by this app and no tile uses them any '
                    'more. Show them to the user and ask before removing '
                    'any; files the app did not create are not listed.',
          });
        }
      case 'read_markdown':
        {
          final pid = a['pageId'] as String? ?? '';
          final r = await _provider.mcpReadMarkdown(pid);
          return r == null
              ? _err('"$pid" is not a markdown page (or there is no such '
                  'page) - call list_pages and pick one whose type is '
                  '"markdown"')
              : _ok(r);
        }
      case 'read_document':
        {
          final pid = a['pageId'] as String? ?? '';
          // ★ = 継続検証 239「選択中のバインダーだけ返る」。 既定は**全冊**。
          //   長すぎる時だけ "binder" で 1 冊に絞れるようにする (読むだけ
          //   なので、 画面で開いているバインダー / タブは動かさない)。
          final rdBinder = intOf('binder');
          if (intErr != null) return _err(intErr!);
          final r = await _provider.mcpReadDocument(pid, binder: rdBinder);
          if (r == null) {
            return _err('"$pid" is not a notepad ("document") or free-note '
                '("paint") page, or there is no such page - call list_pages');
          }
          // ★ 範囲外の "binder" は全冊を飛ばして papers:[] になり、
          //   「何も書かれていない」 と読み違えられる。 冊数が判る時
          //   (= バインダーを持つフリーノート) は突っ返す
          //   (= select_paint_tab / delete_paint_item と同じ作法)。
          //   バインダーの無いページ (文書ページ / 昔の 1 枚だけの形) は
          //   冊数が無いので、 今まで通り "binder" を読み飛ばす。
          final rdCount = (r['binderCount'] as num?)?.toInt();
          if (rdBinder != null && rdCount != null && rdBinder >= rdCount) {
            return _err('binderNotFound: there is no binder $rdBinder on '
                '"$pid" (it has $rdCount, so indexes are '
                '0..${rdCount - 1}) - call list_paint_tabs, or leave '
                '"binder" out to read every binder');
          }
          return _ok(r);
        }
      case 'read_paint_items':
        {
          final pid = a['pageId'] as String? ?? '';
          final r = await _provider.mcpReadPaintItems(pid);
          return r == null
              ? _err('"$pid" is not a free-note ("paint") page, or there is '
                  'no such page - call list_pages')
              : _ok(r);
        }
      case 'list_video_editor_items':
        {
          final pid = a['pageId'] as String? ?? '';
          final r = await _provider.mcpListVideoEditorItems(pid);
          return r == null
              ? _err('"$pid" is not a video editor page, or there is no such '
                  'page - call list_pages')
              : _ok(r);
        }
      case 'cloud_sync':
        {
          final r = await _provider.mcpCloudSync(
            action: '${a['action'] ?? ''}',
            pageIds: _stringList(a['pageIds']),
            folderId: (a['folderId'] as String? ?? '').trim().isEmpty
                ? null
                : (a['folderId'] as String).trim(),
          );
          // ★ 失敗は _err で返す (= _ok で {ok:false} を返すと、 AI が
          //   成功と読み違えて「同期しました」 と答える)。
          return r['ok'] == true
              ? _ok(r)
              : _err('cloud sync did not run: ${r['reason']}');
        }
      case 'run_app_command':
        {
          final id = a['id'] as String? ?? '';
          final ok = _provider.mcpRunCommand(id);
          if (ok) {
            // ★ 「窓が開くだけ」 の機能を "launched" と返すと、 AI が
            //   「同期しました」「ロックを掛けました」 と答えてしまう
            //   (= 動作検証レポート 2026-09-15)。 起きた事を分けて返す。
            final needsUser = _provider.mcpCommands
                .any((c) => c['id'] == id && c['needsUser'] == 'true');
            // ★ = 継続検証 251「画面を開かない操作コマンドが『画面を開いた』
            //   と返し、 閉じ方まで誤案内する」。 取り消しや拡大率のように
            //   その場で終わる操作は画面を持たないので、 screenId /
            //   closeable / 閉じ方の案内を**付けない** (付けていたので
            //   close_app_command が呼ばれ、 必ず fullScreenDialog で空振り
            //   していた)。 代わりに「何が起きたか」 を返す。
            final noScreen = _provider.mcpCommands
                .any((c) => c['id'] == id && c['noScreen'] == 'true');
            if (noScreen) {
              return _ok({
                'launched': true,
                'command': id,
                'opensScreen': false,
                ...?_provider.mcpLastCommandDetail,
                'note': 'ran: $id - this finishes on the spot and opens no '
                    'screen, so there is nothing to close. Do NOT call '
                    'close_app_command for it.',
              });
            }
            // ★ = 動作検証の機能修正案「MCP から開いた機能画面を閉じる操作」。
            //   開いた物を後で閉じられるように、 画面の名前と「閉じられるか」
            //   を返す。 判定は画面側へ訊く (probe = 閉じずに見るだけ)。
            // ★ = 継続検証 88「closeable:false と返るのに close_app_command で
            //   閉じられる」。 浮遊窓は Overlay へ差し込まれるまで台帳に
            //   載らないので、 押した直後に訊くと必ず「開いていない」 に
            //   なっていた。 描画が 1 周するのを待ってから訊く。
            await Future<void>.delayed(const Duration(milliseconds: 450));
            final probe = await _provider.mcpCloseCommand(id, probe: true);
            final closeable =
                ((probe['closed'] as List?) ?? const []).contains(id);
            return _ok({
              'screenId': id,
              'opened': true,
              // ★ = 継続検証 215/216「起動は opened:true なのに終了 API から
              //   追跡できない」。 「開いた」 と「ここから閉じられる」 は
              //   別の話なので分けて返す (closeable:false = この道具では
              //   閉じられない → 終了の案内も出さない)。
              'closeable': closeable,
              if (!closeable) 'tracked': false,
              'note': needsUser
                  ? 'opened: $id - a window is now on screen and the user has '
                      'to finish it there (and a plan upgrade prompt may have '
                      'appeared instead). Say the window is open; do not claim '
                      'the action itself is done.'
                  : 'launched: $id',
              if (closeable)
                'closeHint': 'call close_app_command with this screenId to '
                    'close it again.'
              else
                // ★ = 継続検証 215/216。 ここで「渡せば閉じられる」 と
                //   案内していたため、 閉じられない画面にも
                //   close_app_command が呼ばれ、 必ず notOpen で空振りして
                //   いた。 閉じられない事をはっきり言い、 呼ばせない。
                'cannotClose': 'this screen is NOT tracked from here, so '
                    'close_app_command cannot close it - do NOT call it for '
                    'this screenId. If the user wants it gone, ask them to '
                    'close it with its own X button or Esc.',
            });
          }
          // ★ 「知らない id」 と「利用者しか始められない機能」 を区別する。
          //   以前はどちらも同じ文面だったため、 存在しない id を投げた時にも
          //   「利用者が押してください」 と答えてしまい、 出来るはずの事まで
          //   断るようになっていた (= ユーザー報告)。
          //   (_mcpBlockedCommands は今は空なので、 下へは届かない。)
          if (_provider.mcpIsBlockedCommand(id)) {
            return _err('"$id" is a feature only the user can start. '
                'Tell the user to press the button themselves.');
          }
          return _err('unknown command id "$id", or it does not work on this '
              'device (the app lock and the focus lock are mobile-only). '
              'Call list_app_commands for the ids that really work here. '
              'Note: deleting a page is delete_page, changing a page kind is '
              'set_page_type, and putting buttons on the header is '
              'set_header_buttons - those are tools, not commands.');
        }
      // ★ = 機能追加案 継続検証190。 今の画面の様子を読むだけ。
      case 'describe_screen':
        return _ok(_provider.mcpScreenState());
      case 'close_app_command':
        {
          final res = await _provider.mcpCloseCommand(a['id'] as String? ?? '');
          final err = res['error'];
          if (err != null) return _err('$err');
          return _ok(res);
        }
      // ★ = 継続検証 412。 前面のファイル閲覧画面だけを閉じる
      //   (run_app_command で開いた機能画面は上の case の担当)。
      case 'close_foreground_file':
        {
          final res = await _provider.mcpCloseForegroundFile();
          final err = res['error'];
          if (err != null) return _err('$err');
          return _ok(res);
        }
      case 'set_split_view':
        {
          final splitCell = intOf('cell');
          if (intErr != null) return _err(intErr!);
          final res = await _provider.mcpSetSplitView(
            layout: '${a['layout'] ?? ''}'.trim(),
            pageIds: [
              for (final e in (a['pageIds'] as List? ?? const [])) '$e'
            ],
            cell: splitCell,
          );
          final err = res['error'];
          if (err != null) return _err('$err');
          return _ok(res);
        }
      case 'list_app_docs':
        return _ok(_provider.mcpListAppDocs());
      case 'read_app_doc':
        {
          final name = a['name'] as String? ?? '';
          final text = await _provider.mcpReadAppDoc(name);
          return text == null
              ? _err('unknown doc: "$name" (call list_app_docs for valid names)')
              : _ok(text);
        }
      case 'text_file_status':
        return _ok(_provider.mcpTextFileStatus());
      case 'text_file_read':
        {
          final tfStart = intOf('startLine', min: 1);
          final tfEnd = intOf('endLine', min: 1);
          if (intErr != null) return _err(intErr!);
          final r = _provider.mcpTextFileRead(
            startLine: tfStart,
            endLine: tfEnd,
          );
          if (r != null) return _ok(r);
          // ★ = 動作検証レポート 2026-09-25 不具合 3「エラー案内が運用
          //   ルールと逆」。 前面に非 TXT が出ている時に「TXT を開いて」 と
          //   頼ませていた。 種別と次の一手を機械が読める形で返す。
          final fd = _provider.frontDocument;
          if (fd != null) {
            final st = _provider.mcpFileState(fd.path);
            return _err('unsupported_editor_kind: ' +
                jsonEncode({
                  'code': 'unsupported_editor_kind',
                  'editorKind': st['editorKind'],
                  'fileName': fd.name,
                  'path': MindMapProvider.mcpNormalizePath(fd.path),
                  'recommended': 'this file is on screen but NOT in the text '
                      'editor, so text_file_* cannot touch it. Do NOT ask the '
                      'user to open it as text. Read it with read_device_file '
                      'on this path (or read_page for the page attachment), '
                      'and for pptx / xlsx / docx tell the user to use the AI '
                      'button inside that editor.',
                }));
          }
          return _err('no_file_open: ' +
              jsonEncode({
                'code': 'no_file_open',
                'recommended': 'nothing is on screen. Find the document with '
                    'read_page (attachmentName / attachmentPath) and read it '
                    'with read_device_file. Do NOT ask the user to open a '
                    'file just so you can edit it.',
              }));
        }
      case 'text_file_edit':
        {
          final raw = a['edits'];
          if (raw is! List || raw.isEmpty) {
            return _err('edits must be a non-empty array');
          }
          final edits = <Map<String, dynamic>>[
            for (final e in raw)
              if (e is Map) e.cast<String, dynamic>()
          ];
          if (edits.isEmpty) return _err('edits must contain objects');
          final err = _provider.mcpTextFileEdit(edits);
          return err == null
              ? _ok('edited (${edits.length} edit(s) applied)')
              : _err(err);
        }
      // ── ページ / フォルダーの整理 ──
      case 'rename_page':
        {
          final renamed = <Map<String, Object?>>[];
          final unchanged = <Map<String, Object?>>[];
          final failed = <Map<String, Object?>>[];
          var seq = 0;
          // ★ = 動作検証レポート 改善案 4「failed が id だけで理由が無い」。
          //   出来なかった訳 (名前が空 / そんなページは無い / 元から同じ名前)
          //   を分けて返す。 まとめて頼まれた時に、 どれをどう直せばよいか
          //   AI が分かるように。
          void one(String pageId, String nm) {
            final i = seq++;
            if (pageId.isEmpty) {
              failed.add({
                'index': i,
                'pageId': pageId,
                'reason': '"pageId" was blank - call list_pages for the ids',
              });
              return;
            }
            if (MindMapProvider.mcpSafeDisplayName(nm).isEmpty) {
              failed.add({
                'index': i,
                'pageId': pageId,
                'reason': nm.trim().isEmpty
                    ? 'the new name was blank'
                    : 'the new name held nothing but control characters / '
                        'line breaks, which cannot be shown in the page list',
              });
              return;
            }
            final cur = _provider.mcpPageById(pageId);
            if (cur != null &&
                cur.name == MindMapProvider.mcpSafeDisplayName(nm)) {
              unchanged.add({
                'index': i,
                'pageId': pageId,
                'name': nm.trim(),
                'reason': 'already had that name',
              });
              return;
            }
            final got = <String>[];
            if (_provider.mcpRenamePage(pageId, nm, applied: got)) {
              // ★ = 継続検証 128 / 178。 制御文字を落とした名前と、 同名を
              //   避けて採番した名前を**実際に入った形**で返す。
              final real = got.isEmpty ? nm.trim() : got.first;
              renamed.add({
                'index': i,
                'pageId': pageId,
                'name': real,
                if (real != nm.trim()) 'requestedName': nm.trim(),
                if (real != nm.trim())
                  'adjusted': 'the name was cleaned up (control characters / '
                      'line breaks removed) and/or numbered so it does not '
                      'collide with another page in the same folder.',
              });
            } else {
              failed.add({
                'index': i,
                'pageId': pageId,
                'reason': 'no page has that id',
              });
            }
          }

          final renEmpty = _emptyBatch(a, 'pages',
              'Pass at least one {pageId, name}, or use the single '
              '"pageId"/"name" form.');
          if (renEmpty != null) return renEmpty;
          // ★ = 継続検証 165「単一指定と一括指定の併記で単一指定を黙って
          //   無視する」。 食い違った依頼は実行せずに断る (片方だけ通ると、
          //   変えたはずのページが元の名前のまま残る)。
          if (a['pages'] is List &&
              (a['pages'] as List).isNotEmpty &&
              '${a['pageId'] ?? ''}'.trim().isNotEmpty) {
            return _err('"pages" (the array form) and "pageId"/"name" (the '
                'single form) were both given. Nothing was renamed - put '
                'every page in "pages", or send only the single form.');
          }
          final batch = a['pages'];
          if (batch is List && batch.isNotEmpty) {
            for (final e in batch) {
              if (e is! Map) continue;
              final m = e.cast<String, dynamic>();
              one('${m['pageId'] ?? ''}'.trim(), '${m['name'] ?? ''}');
            }
          } else {
            one('${a['pageId'] ?? ''}'.trim(), '${a['name'] ?? ''}');
          }
          if (renamed.isEmpty && unchanged.isEmpty) {
            return _err('could not rename '
                '${failed.map((e) => '${e['pageId']} (${e['reason']})').join(', ')}'
                ' - call list_pages and use an id from it.');
          }
          return _ok(_batchResult(
            created: const [],
            updated: renamed,
            unchanged: unchanged,
            failed: failed,
          ));
        }
      case 'reorder_pages':
        {
          final ids = _stringList(a['pageIds']);
          if (ids.isEmpty) return _err('pageIds must be a non-empty array');
          // ★ = 継続検証 125 / 177「重複 ID・存在しない ID が黙って除外
          //   される」。 捨てた物を返す (部分成功を成功と読ませない)。
          final roOut = <String, Object?>{};
          final order = _provider.mcpReorderPages(ids, outcome: roOut);
          return _ok({
            'order': order,
            'requested': roOut['requested'],
            'used': roOut['used'],
            if (roOut['ignoredDuplicates'] != null)
              'ignoredDuplicates': roOut['ignoredDuplicates'],
            if (roOut['unknownPageIds'] != null) ...{
              'unknownPageIds': roOut['unknownPageIds'],
              'note': 'some ids in "pageIds" are not real pages, so they had '
                  'no place in the order. Tell the user which ones instead of '
                  'reporting a full reorder.',
            },
          });
        }
      case 'list_folders':
        return _ok(_provider.mcpListFolders());
      case 'create_folder':
        {
          final wantName = '${a['name'] ?? ''}'.trim();
          final id = _provider.mcpCreateFolder(a['name'] as String?);
          final hit = _provider.mcpListFolders().firstWhere(
              (e) => e['id'] == id,
              orElse: () => const <String, dynamic>{});
          final real = '${hit['name'] ?? ''}';
          return _ok({
            'folderId': id,
            if (hit['name'] != null) 'name': hit['name'],
            // ★ = 継続検証 128 / 176。 均した名前・採番した名前を必ず伝える。
            if (wantName.isNotEmpty && real != wantName) ...{
              'requestedName': wantName,
              'adjusted': 'the name was cleaned up (control characters / line '
                  'breaks removed) and/or numbered so it does not collide '
                  'with another folder.',
            },
          });
        }
      case 'rename_folder':
        {
          final fid = '${a['folderId'] ?? ''}'.trim();
          final want = '${a['name'] ?? ''}';
          // ★ = 継続検証 96 / 176「『ID が存在しない、 または名前が空』 と
          //   複合条件で返るため、 どちらが原因か分かりにくい」。
          //   先に名前だけを見て、 理由を 1 つに絞る。
          if (MindMapProvider.mcpSafeDisplayName(want).isEmpty) {
            return _err(want.trim().isEmpty
                ? 'the new folder name was blank - nothing was renamed.'
                : 'the new folder name held nothing but control characters / '
                    'line breaks, which cannot be shown in the folder list - '
                    'nothing was renamed.');
          }
          if (!_provider.mcpListFolders().any((f) => f['id'] == fid)) {
            return _err('no folder has the id "$fid" - call list_folders. '
                'Nothing was renamed.');
          }
          final got = <String>[];
          final ok = _provider.mcpRenameFolder(fid, want, applied: got);
          final real = got.isEmpty ? want.trim() : got.first;
          return ok
              ? _ok({
                  'folderId': fid,
                  'name': real,
                  if (real != want.trim()) ...{
                    'requestedName': want.trim(),
                    // ★ = 継続検証 176「同名フォルダーを作れて一覧で区別
                    //   しにくい」。 採番した事を必ず伝える。
                    'adjusted': 'the name was cleaned up and/or numbered so '
                        'it does not collide with another folder.',
                  },
                })
              : _err('the folder "$fid" could not be renamed.');
        }
      case 'delete_folder':
        {
          final fid = '${a['folderId'] ?? ''}'.trim();
          final reason = _provider.mcpDeleteFolder(fid,
              deletePages: a['deletePages'] == true);
          return reason == null
              ? _ok(a['deletePages'] == true
                  ? 'deleted folder $fid and the pages inside it'
                  : 'deleted folder $fid (the pages inside were kept)')
              : _err(reason);
        }
      case 'move_page_to_folder':
        {
          final toRoot = a['toRoot'] == true;
          final fid = '${a['folderId'] ?? ''}'.trim();
          // ★ = 継続検証 158「移動先フォルダーと toRoot の競合指定を黙って
          //   処理する」。 どちらを取っても引数の組み立てミスに気付けないので
          //   断る (黙ってルートへ出すと、 頼んだフォルダーとは別の場所へ
          //   ページが置かれる)。
          if (toRoot && fid.isNotEmpty) {
            return _err('"toRoot" and "folderId" ask for opposite places, so '
                'nothing was moved. Send "folderId" to put the page in a '
                'folder, or "toRoot" to take it out.');
          }
          final target = toRoot || fid.isEmpty ? null : fid;
          // ★ = 継続検証 158「不明ページと不明フォルダーの失敗理由を区別
          //   できない」。 行き先はページごとではなく 1 回だけ確かめる。
          if (target != null &&
              !_provider.mcpListFolders().any((f) => f['id'] == target)) {
            return _err('folder_not_found: no folder has the id "$target" - '
                'call list_folders. Nothing was moved.');
          }
          final ids = _stringList(a['pageIds']);
          final mvEmpty = _emptyBatch(a, 'pageIds',
              'Pass at least one page id, or use the single "pageId" form.',
              usable: ids.length);
          if (mvEmpty != null) return mvEmpty;
          final list =
              ids.isNotEmpty ? ids : [('${a['pageId'] ?? ''}').trim()];
          // ★ 既にそのフォルダーに入っている物を moved に数えない
          //   (= 動作検証レポート 改善案 4: 何が動いたのか分からない)。
          final moved = <Map<String, Object?>>[];
          final same = <Map<String, Object?>>[];
          final failed = <Map<String, Object?>>[];
          for (var i = 0; i < list.length; i++) {
            final pid = list[i];
            if (pid.isEmpty) continue;
            final already = _provider.mcpPageIsInFolder(pid, target);
            // ★ = 継続検証 249。 移動先の同名を避けて採番した時は、 実際に
            //   入った名前を返す (黙って変えると、 AI が古い名前のまま次の
            //   道具を呼んで「ページが見つかりません」 になる)。
            final renamedTo = <String>[];
            if (!_provider.mcpMovePageToFolder(pid, target,
                applied: renamedTo)) {
              // 行き先は上で確かめてあるので、 ここへ来るのはページ側の問題。
              failed.add({
                'index': i,
                'pageId': pid,
                'reason': 'page_not_found: no page has that id - call '
                    'list_pages',
              });
              continue;
            }
            (already ? same : moved).add({
              'index': i,
              'pageId': pid,
              if (renamedTo.isNotEmpty) ...{
                'name': renamedTo.first,
                'adjusted': 'the destination already held a page with this '
                    'name, so this one was numbered (same rule as '
                    'create_page / rename_page). Use the new name from '
                    'now on.',
              },
              if (already) 'reason': 'already in that folder',
            });
          }
          if (moved.isEmpty && same.isEmpty) {
            return _err('page_not_found: none of '
                '${failed.map((e) => e['pageId']).join(', ')} is a real page '
                'id (the folder itself was fine) - call list_pages. '
                'Nothing was moved.');
          }
          return _ok(_batchResult(
            created: const [],
            updated: moved,
            unchanged: same,
            failed: failed,
            extra: {'folderId': target},
          ));
        }
      // ── 線だけを消す ──
      case 'disconnect_nodes':
        {
          final pageId = a['pageId'] as String? ?? '';
          // ★ 双子 (connect_nodes) と同じ穴。 鍵の掛かったページは
          //   mcpPageById が null なので、 引き当てが全部外れて
          //   node_not_found になり、 実在する要素を「ありません」 と
          //   誤診させていた。 先に本当の理由を返す。
          if (_provider.mcpPageById(pageId) == null) {
            return _err(_noPageMsg(pageId, did: 'No line was removed.'));
          }
          String key(Map<String, dynamic> m, String a1, String a2) {
            final v1 = '${m[a1] ?? ''}'.trim();
            return v1.isNotEmpty ? v1 : '${m[a2] ?? ''}'.trim();
          }

          final discEmpty = _emptyBatch(a, 'connections',
              'Pass at least one {from, to}, or do not call disconnect_nodes.');
          if (discEmpty != null) return discEmpty;
          final batch = a['connections'];
          final pairs = <List<String>>[];
          if (batch is List && batch.isNotEmpty) {
            for (final e in batch) {
              if (e is! Map) continue;
              final m = e.cast<String, dynamic>();
              pairs.add([key(m, 'from', 'fromId'), key(m, 'to', 'toId')]);
            }
          } else {
            pairs.add([key(a, 'from', 'fromId'), key(a, 'to', 'toId')]);
          }
          var done = 0;
          // ★ = 継続検証 98 / 162「未接続の UUID 指定を『要素なし』 と誤判定
          //   し、 UUID をハイフンごとに分解して返す」。 原因は失敗した組を
          //   `"from - to"` の**1 本の文字列**に詰めてから、 後で
          //   `-` で割り直していた事。 UUID には `-` が入っているので、
          //   1 つの id が 5 個の知らない語に化けていた。
          //   組は最後まで**組のまま**持ち、 両端の在る / 無いもその場で見る。
          // ★ = 継続検証 130「実在する未接続と、 存在しない要素を区別しない」。
          final notConnected = <Map<String, Object?>>[];
          // ★ = 継続検証 374「同名の要素があると 1 件目を選んで
          //   not_connected と返し、 2 件目の線が残る」。 線を引く側
          //   (connect_nodes) と同じで、 1 つに決まらない指定は消さずに
          //   候補 id を返す (当てずっぽうで別の線を消すと後から気付けない)。
          final ambiguous = <Map<String, Object?>>[];
          final notFound = <Map<String, Object?>>[];
          for (var i = 0; i < pairs.length; i++) {
            final p = pairs[i];
            if (p[0].isEmpty || p[1].isEmpty) {
              notFound.add({
                'index': i,
                'from': p[0],
                'to': p[1],
                'reason': '"from" and "to" are both required',
              });
              continue;
            }
            // ★ = 継続検証 374。 引く側 (connect_nodes) と同じ物差し
            //   (fuzzy: false) で、 1 つに決まらない指定は消さない。
            final dAmb = _ambiguous(pageId, p[0], 'from', fuzzy: false) ??
                _ambiguous(pageId, p[1], 'to', fuzzy: false);
            if (dAmb != null) {
              ambiguous.add({
                'index': i,
                'from': p[0],
                'to': p[1],
                'reason': dAmb,
              });
              continue;
            }
            // 実際に消えた本数を数える (= ユーザー報告: 2 本消えたのに
            // 1 と返っていた)。
            final removedCount =
                _provider.mcpDisconnectNodes(pageId, p[0], p[1]);
            if (removedCount > 0) {
              done += removedCount;
              continue;
            }
            // 消す側は部分一致を使わないので、 在るかどうかも同じ物差しで見る。
            final fromId =
                _provider.mcpResolveNodeId(pageId, p[0], fuzzy: false);
            final toId =
                _provider.mcpResolveNodeId(pageId, p[1], fuzzy: false);
            if (fromId == null || toId == null) {
              notFound.add({
                'index': i,
                'from': p[0],
                'to': p[1],
                'unknown': [
                  if (fromId == null) p[0],
                  if (toId == null) p[1],
                ],
                'reason': 'no node on this page has that exact id or title',
              });
            } else {
              notConnected.add({
                'index': i,
                'from': p[0],
                'to': p[1],
                'fromId': fromId,
                'toId': toId,
                'reason': 'both nodes exist but there is no line between them '
                    '(it may already be gone)',
              });
            }
          }
          if (done == 0) {
            // ★ = 動作検証レポート 2026-09-25 不具合 8「ノード不存在と
            //   未接続を区別しない」。 打ち間違いと「もう切れている
            //   (= 何度呼んでも同じ)」 を別の札で返す。
            // ★ = 継続検証 374。 1 つに決まらない指定しか無かった時は、
            //   「線が無い」 でも「要素が無い」 でもない。 別の札で返す
            //   (not_connected と返すと、 2 件目の線が残っているのに
            //    「もう切れている」 と報告されてしまう)。
            if (ambiguous.isNotEmpty &&
                notFound.isEmpty &&
                notConnected.isEmpty) {
              return _err('ambiguous_name: ' +
                  jsonEncode({
                    'code': 'ambiguous_name',
                    'pairs': ambiguous,
                    'note': 'no line was removed. Pass the exact "id" of the '
                        'node you mean (read_page lists id and title).',
                  }));
            }
            if (notFound.isNotEmpty && notConnected.isEmpty) {
              return _err('node_not_found: ' +
                  jsonEncode({
                    'code': 'node_not_found',
                    'pairs': notFound,
                    if (ambiguous.isNotEmpty) 'ambiguous': ambiguous,
                    'nodes': _provider.mcpNodeIndex(pageId),
                  }));
            }
            return _err('not_connected: ' +
                jsonEncode({
                  'code': 'not_connected',
                  'pairs': notConnected,
                  if (notFound.isNotEmpty) 'notFound': notFound,
                  if (ambiguous.isNotEmpty) 'ambiguous': ambiguous,
                  'note': 'both nodes exist but there is no line between '
                      'them (it may already be gone). Calling this again is '
                      'safe and will report not_connected the same way. '
                      'Nothing was changed, so no undo step was used.',
                }));
          }
          return _ok({
            'disconnected': done,
            if (notConnected.isNotEmpty) 'notConnected': notConnected,
            if (notFound.isNotEmpty) 'notFound': notFound,
            // ★ = 継続検証 374。 決まらなかった指定の線は残っている。
            if (ambiguous.isNotEmpty) 'ambiguous': ambiguous,
          });
        }
      // ── 図形 (装飾) ──
      case 'add_decoration':
        {
          final pageId = a['pageId'] as String? ?? '';
          // ★ = 動作検証の不具合「ギャラリーに MCP から図形を挿入できる」。
          //   画面側 (_showMapShapePicker) が 'gallery.noShapeInsert' で
          //   断っているのと同じ線引きにする。
          final decoTarget = _provider.mcpPageById(pageId);
          if (decoTarget != null && decoTarget.pageType == 'bookshelf') {
            return _err('"$pageId" is a gallery (bookshelf) page: shapes '
                'cannot be inserted in a gallery (the app refuses the same '
                'way). No shape was drawn. Offer set_page_type "normal" if '
                'the user really wants shapes there.');
          }
          // ★ = 動作検証レポート 不具合 2「空・不正な入力が、 既定座標の
          //   四角を成功扱いで作る」。 kind を 'rectangle' で埋め、 場所の
          //   指定が無ければページの基準位置に 240x160 の四角を置いていたので、
          //   `{}` でも、 居ないノードを囲めと言われた時でも、 誰も頼んで
          //   いない四角が出来て added に数えられていた。
          //   囲む相手も座標も無い図形は**作らない**。
          // ★ 種類は**必ず enum から組む**。 手で並べ直すと、 star / heart /
          //   hexagon など実際に描ける形まで弾いてしまう (= 粗探しで発見:
          //   道具の説明は 15 種類を案内しているのに 8 種類しか通さなかった)。
          //   折れ線だけは通過点が要るので、 ここでは扱わない
          //   (mcpAddDecoration も同じ理由で断っている)。
          final kinds = <String>{
            for (final v in MapDecorationKind.values)
              if (v != MapDecorationKind.polyline) v.name
          };
          // その 1 要素で図形を作れるか検分する。 作れない時は理由 (英語)。
          String? problemOf(Map<String, dynamic> m) {
            final kind = '${m['kind'] ?? ''}'.trim();
            if (kind.isEmpty) {
              return '"kind" is required (${kinds.join(' / ')}) - there is '
                  'no default shape';
            }
            if (!kinds.any((k) => k.toLowerCase() == kind.toLowerCase())) {
              return 'unknown kind "$kind" (use ${kinds.join(' / ')}; '
                  '"polyline" is not available here)';
            }
            // 層は provider が 1..5 に丸める。 範囲で断ると、 丸めを当てにして
            //   0 を渡された時に図形ごと消えてしまう (= 粗探しで発見)。
            final lay = _intOf(m['layer'], 'layer', min: -1 << 31);
            if (lay.error != null) return lay.error;
            final around = _stringList(m['aroundNodes']);
            if (around.isNotEmpty) {
              // ★ = 継続検証 377 / 381。 候補が複数ある指定は囲まない。
              //   ただし aroundNodes は複数指定できるので、 1 つでも
              //   1 つに決まる指定があれば囲む (全部落とさない)。
              final sp = _aroundSplit(pageId, around);
              if (sp.ids.isEmpty) {
                if (sp.amb.isEmpty) {
                  return 'none of the nodes in "aroundNodes" exist on this '
                      'page (${sp.missed.join(', ')}) - nothing was drawn. '
                      'Call read_page and use the exact titles';
                }
                final unknown = sp.missed.isEmpty
                    ? ''
                    : ' Unknown: ${sp.missed.join(', ')}.';
                return 'no entry in "aroundNodes" points at a single node, so '
                    'nothing was drawn (a name shared by several nodes is '
                    'skipped, never guessed - pass the id).$unknown '
                    '${jsonEncode(sp.amb)}';
              }
              return null; // 1 つに決まる指定が 1 件でもあれば囲める
            }
            final has = _numOf(m['x1']) != null &&
                _numOf(m['y1']) != null &&
                _numOf(m['x2']) != null &&
                _numOf(m['y2']) != null;
            if (!has) {
              return 'give either "aroundNodes" (titles to enclose) or all '
                  'four of x1/y1/x2/y2 - a shape with neither is not drawn';
            }
            return null;
          }

          String? addOne(Map<String, dynamic> m, Map<String, Object?> out,
                  List<String> aroundIds) =>
              _provider.mcpAddDecoration(
                pageId,
                outcome: out,
                kind: '${m['kind'] ?? ''}',
                x1: _numOf(m['x1']),
                y1: _numOf(m['y1']),
                x2: _numOf(m['x2']),
                y2: _numOf(m['y2']),
                // ★ = 継続検証 377 / 381。 1 つに決まった id だけを渡す
                //   (provider の引き当ては部分一致なので、 生の題名を渡すと
                //    候補が複数ある指定も 1 件目に当たってしまう)。
                aroundNodeIds: aroundIds,
                // MapDecoration の色は 24 ビット (不透明度を持たない)。
                colorRgb: _argbOf(m['color']) == null
                    ? null
                    : (_argbOf(m['color'])! & 0xFFFFFF),
                strokeWidth: _numOf(m['strokeWidth']),
                text: m['text'] as String?,
                filled: m['filled'] == true ? true : null,
                layer: _intOf(m['layer'], 'layer', min: -1 << 31).value,
              );

          final decoEmpty = _emptyBatch(a, 'shapes',
              'Pass at least one shape, or do not call add_decoration. An '
              'empty array does NOT mean "one default rectangle".');
          if (decoEmpty != null) return decoEmpty;
          if (_provider.mcpPageById(pageId) == null) {
            return _err('page not found: "$pageId" - nothing was drawn');
          }
          final batch = a['shapes'];
          final entries = <Map<String, dynamic>>[];
          if (batch is List && batch.isNotEmpty) {
            for (final e in batch) {
              entries.add(e is Map ? e.cast<String, dynamic>() : {});
            }
          } else {
            entries.add(a);
          }
          // ★ 先に全部を検分してから作る。 途中で気付いて止めると、
          //   「半分だけ描かれた」 という一番直しにくい状態になる。
          final created = <Map<String, Object?>>[];
          final failed = <Map<String, Object?>>[];
          for (var i = 0; i < entries.length; i++) {
            final why = problemOf(entries[i]);
            if (why != null) {
              failed.add({
                'index': i,
                'kind': '${entries[i]['kind'] ?? ''}',
                'reason': why,
              });
            }
          }
          if (failed.isNotEmpty && created.isEmpty && entries.length == 1) {
            return _err('${failed.first['reason']} - nothing was drawn.');
          }
          for (var i = 0; i < entries.length; i++) {
            if (failed.any((f) => f['index'] == i)) continue;
            final m = entries[i];
            final out = <String, Object?>{};
            // ★ = 継続検証 377 / 381。 囲む相手をここで分ける。
            final sp = _aroundSplit(pageId, _stringList(m['aroundNodes']));
            final id = addOne(m, out, sp.ids);
            if (id == null) {
              failed.add({
                'index': i,
                'kind': '${m['kind'] ?? ''}',
                'reason': 'the app refused this shape',
              });
              continue;
            }
            created.add({
              'index': i,
              'decorationId': id,
              'kind': '${m['kind'] ?? ''}',
              // ★ = 継続検証 129「層を範囲内へ補正しても応答に適用値が
              //   出ない」 / 107「線幅へ負の値を保存できる」。 実際に保存した
              //   値と、 丸めたかどうかを返す。
              'layer': out['layer'],
              'strokeWidth': out['strokeWidth'],
              if (out['layerClamped'] == true) ...{
                'requestedLayer': out['requestedLayer'],
                'layerClamped': true,
              },
              if (out['strokeWidthClamped'] == true) ...{
                'requestedStrokeWidth': out['requestedStrokeWidth'],
                'strokeWidthClamped': true,
              },
              // ★ = 継続検証 132 / 180「囲みの対象が一部見つからなくても
              //   黙って成功する」。 囲めた相手と囲めなかった相手を返す。
              if (out['aroundNodeIds'] != null)
                'aroundNodeIds': out['aroundNodeIds'],
              // ★ 見つからなかった指定は**ここ**で数える。 provider へ渡すのは
              //   1 つに決まった id だけなので、 provider 側の
              //   aroundNotFound は必ず空になる。
              if (sp.missed.isNotEmpty) 'aroundNotFound': sp.missed,
              // ★ = 継続検証 377 / 381。 候補が複数あった指定は囲わずに落とし、
              //   落とした事と候補を返す (他の指定は活きているので図形は描く)。
              if (sp.amb.isNotEmpty) 'aroundAmbiguous': sp.amb,
              if (sp.missed.isNotEmpty || sp.amb.isNotEmpty) ...{
                'partial': true,
                'note': 'only part of "aroundNodes" was enclosed, so the '
                    'shape covers fewer nodes than asked for. '
                    '"aroundNotFound" = no node has that id or title; '
                    '"aroundAmbiguous" = the name matched several nodes, so '
                    'it was skipped instead of guessed (pass the id). Tell '
                    'the user instead of saying every node is enclosed.',
              },
              if (out['aroundFitsOnce'] == true)
                'aroundNote': 'the box was fitted to those nodes ONCE, at '
                    'the moment it was drawn. It does not follow them if they '
                    'move later.',
            });
          }
          if (created.isEmpty) {
            return _err('nothing was drawn. '
                '${failed.map((f) => '[${f['index']}] ${f['reason']}').join('; ')}');
          }
          return _ok(_batchResult(
            created: created,
            failed: failed,
            extra: {
              'decorationIds': [for (final e in created) e['decorationId']],
            },
          ));
        }
      case 'delete_decoration':
        {
          final pageId = a['pageId'] as String? ?? '';
          final did = '${a['decorationId'] ?? ''}'.trim();
          return _provider.mcpDeleteDecoration(pageId, did)
              ? _ok('deleted decoration $did')
              : _err('no decoration "$did" on that page '
                  '(read_page lists them under "decorations")');
        }
      // ── 端末のファイル (利用者の許可つき) ──
      case 'read_device_file':
        {
          // ★ 既定値へ倒す前に理由を返す (= 粗探しで発見: `?? 12000` だと、
          //   おかしな値を渡された事に誰も気付けない)。
          final rdMax = intOf('maxChars', min: 1) ?? 12000;
          if (intErr != null) return _err(intErr!);
          final r = await _provider.mcpReadDeviceFile(
            '${a['path'] ?? ''}',
            reason: '${a['reason'] ?? ''}',
            maxChars: rdMax,
          );
          final err = r['error'];
          return err == null ? _ok(r) : _err('$err');
        }
      case 'pick_user_file':
        {
          final puMax = intOf('maxChars', min: 1) ?? 12000;
          if (intErr != null) return _err(intErr!);
          final r = await _provider.mcpPickAndReadFile(
            reason: '${a['reason'] ?? ''}',
            maxChars: puMax,
          );
          final err = r['error'];
          return err == null ? _ok(r) : _err('$err');
        }
      // ── Web ──
      case 'web_search':
        {
          final q = '${a['query'] ?? ''}'.trim();
          if (q.isEmpty) return _err('query is required');
          final wsLimit = intOf('limit', min: 1, max: 50) ?? 8;
          if (intErr != null) return _err(intErr!);
          final hits = await _provider.mcpWebSearch(q, limit: wsLimit);
          if (hits.isEmpty) {
            return _err('no results for "$q". Try different words, or ask '
                'the user for a url.');
          }
          // ★ = 不具合報告 2026-09-30「webRank が候補を差し替える」。
          //   検索が成功した事と Jev の並べ替えが成功した事を分けて
          //   確かめられるようにする (並べ替えは順列だけ。 差し替えない)。
          return _ok({
            'query': q,
            'results': hits,
            'jev': _provider.jevWebRankLastInfo,
          });
        }
      case 'web_fetch':
        {
          final wfMax = intOf('maxChars', min: 1) ?? 8000;
          if (intErr != null) return _err(intErr!);
          final r = await _provider.mcpWebFetch(
            '${a['url'] ?? ''}',
            maxChars: wfMax,
          );
          final err = r['error'];
          return err == null ? _ok(r) : _err('$err');
        }
      default:
        return _err('unknown tool: $name');
    }
  }
}

class _McpMethodNotFound implements Exception {}
