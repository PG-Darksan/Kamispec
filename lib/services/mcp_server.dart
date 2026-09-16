import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';

// 自動操作へ渡す合図 (= ユーザー要望: アシスタントから PC を操作)。
import '../main.dart' show automationRequestFromAssistant;
import '../providers/mind_map_provider.dart';
import '../utils/build_flags.dart';

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
        return {
          'tools': allowPowerfulTools
              ? toolDefs
              : [
                  for (final t in toolDefs)
                    if (!kPowerfulTools.contains(t['name'])) t,
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
    'list_video_editor_items',
    'list_orphan_files',
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
        'Desktop only. Returns immediately after handing it over - watch the '
        'panel for the result.',
        {
          'instruction': {
            'type': 'string',
            'description':
                'What to do, in the user\'s own words. Example: "PC の Chrome '
                'を起動して example.com を開いて".'
          }
        },
        ['instruction']),
    // ★ isCurrent を必ず説明に書く (= ユーザー報告: 「このページ消して」 で
    //   全ページを消しにいった)。 どれが「今のページ」 かを知る手立てが
    //   説明に無いと、 AI は当てずっぽうで全部に手を出す。
    _tool('list_pages',
        'List all pages (id, name, type: normal/bookshelf/paint/..., node '
        'count, isCurrent, lastModified). isCurrent is true for the one page '
        'the user is looking at right now: "this page" / "the page I am on" '
        'always means that one - never guess from the name, and never act on '
        'other pages. lastModified is the last EDIT time, NOT the creation '
        'time, so it cannot decide which of two same-named pages is "the old '
        'one" - show the times and let the user pick.',
        {}),
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
        'table. The same applies to image, video and long-memo nodes.',
        {'pageId': {'type': 'string'}},
        ['pageId']),
    _tool(
        'delete_page',
        'Delete a page permanently. Use this when the user explicitly asks to '
        'delete/remove a page. Cannot delete the last remaining page. '
        'Call list_pages first and use a real pageId from it - never make up '
        'an id. SCOPE: delete only the pages the user actually named. '
        '"this page" is the single page with isCurrent:true - delete that one '
        'and stop. Do NOT walk down the page list deleting one after another, '
        'and do not retry with another id when a delete fails. '
        'When the page is named clearly, just delete it - do not ask again. '
        'When it is NOT clear which page (two pages share a name, or the user '
        'says "the ones I do not need"), list the candidates and get an OK '
        'first. There is no restore tool: only the single most recently '
        'deleted page can be brought back, and only by the user pressing '
        'Ctrl+Z (undo) in the app.',
        {'pageId': {'type': 'string'}},
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
        (kStoreBuild ? '. ' : ' or "videoEditor" (video timeline). ') +
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
        'Nodes created without x/y all land on the SAME spot, so call '
        'tidy_page on this pageId once you have finished adding, or they stay '
        'stacked. Returns nodeIds in the same order. '
        'ALWAYS put links in "url", never as bare text inside "memo": a node '
        'with "url" becomes a real clickable link, and a YouTube WATCH url '
        '(https://www.youtube.com/watch?v=VIDEOID or https://youtu.be/VIDEOID) '
        'becomes an embedded video node with a thumbnail that plays in the '
        'app. Search urls (/results?search_query=...) are NOT videos, so give '
        'the actual watch url when you know the video. "memo" and "url" can '
        'be used together on the same node. '
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
        '"parentId" may be an existing node\'s id OR its exact title. Any '
        'entry whose parent could not be linked comes back in "unlinked" - '
        'link those with connect_nodes and never report them as connected.',
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
        '- using the title means you do not have to look up ids. '
        '("nodeId" is accepted as an alias.) "title" is a short label: long '
        'text is ellipsised to about two lines on the canvas, so put long '
        'text in "memo". A blank / whitespace-only title is accepted, but the '
        'node can then only be addressed by its id. x/y may be negative. '
        'This tool CAN also recolour a node and give it a link after it was '
        'placed: "color" takes 32-bit ARGB (a 6-digit RGB value is made '
        'opaque; out-of-range values are ignored), "url" makes the node a '
        'clickable link - a YouTube watch url becomes an embedded video node '
        'instead - and "clearUrl":true removes an existing link/video. The '
        'result echoes back what was actually applied; report that, not what '
        'you asked for.',
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
        'fields you pass change; everything else stays. This does NOT move or '
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
        '(layer), start time, length or caption text. Get itemId from '
        'list_video_editor_items. Only the fields you pass change. Set '
        '"remove": true to delete the item instead. Times are whole '
        'milliseconds (1.5 seconds = 1500). This is the only way to fix a '
        'caption you placed at the wrong moment - do not add a second one on '
        'top of it.',
        {
          'pageId': {'type': 'string'},
          'itemId': {'type': 'string'},
          'layer': {'type': 'integer'},
          'startMs': {'type': 'integer'},
          'durationMs': {'type': 'integer'},
          'text': {'type': 'string'},
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
        'One entry deletes ONE node: a title resolves to the FIRST node '
        'carrying it, so when several nodes share a title call read_page and '
        'pass every matching "id" as its own entry. The result lists the '
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
        'never touched, nothing is ever deleted permanently, and undo brings '
        'back the tile but not the file. The reply carries "fileRecycled" or '
        '"fileKept" with a reason - report that, do not claim the file is '
        'gone. Use list_orphan_files to find leftovers from earlier '
        'tile-only deletions.',
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
        'their visual order — use it when gallery items are strewn about. '
        'Other page types arrange themselves.',
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
        'select tool - that is '
        'the '
        'right tool when the user says "draw a picture on this free note". '
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
        'SET "placeOnSheet": true WHEN THE USER ASKS YOU TO DRAW SOMETHING '
        'ON AN OPEN FREE NOTE ("このノートに猫を描いて" / "draw a cat here"). '
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
    _tool(
        'set_page_background',
        'Set the page background from an existing picture, or remove it. '
        '"Remove / get rid of / I do not like this background" means '
        '"clear": true - run it straight away, do not ask again and do not '
        'generate a replacement (disliking a background is not a request for '
        'a new one). Prefer generate_page_background only when the user '
        'describes a look they DO want. Use "imagePath" for an absolute path '
        'to an image file already on this device, "clear": true to remove, '
        'or "template" for one of the built-in ones (wood, chalkboard, ocean, '
        'sakura, fireworks, castle, aurora, nightSky, galaxy, rain, nature, '
        'blueprint, midnight, sage, sunset). '
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
        'Connecting the same pair twice just updates the label. A title match is not unique: when two nodes on a page share a title the FIRST one (creation order, NOT screen position) is used, and if no title matches exactly a partial match may pick a longer title. So when titles repeat, or the user names a node by position ("the lower one"), call read_page first and pass the node id - read_page gives x/y, and a larger y is lower on the canvas. The result echoes fromId/toId: check them.',
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
              },
            },
          },
          'from': {'type': 'string'},
          'to': {'type': 'string'},
          'fromId': {'type': 'string'},
          'toId': {'type': 'string'},
          'label': {'type': 'string'},
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
        'decoded comes back as an error and no node is made.',
        {
          'pageId': {'type': 'string'},
          'imageBase64': {'type': 'string'},
          'fileName': {'type': 'string'},
          'imagePath': {'type': 'string'},
          'title': {'type': 'string'},
          'x': {'type': 'number'},
          'y': {'type': 'number'},
        },
        ['pageId']),
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
        '(array of strings) in a SINGLE call - do not call this tool once '
        'per tile. Use "text" + "memo" for a single tile with a body, or '
        '"imagePath" (absolute local path) for a picture tile.',
        {
          'pageId': {'type': 'string'},
          'texts': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'text': {'type': 'string'},
          'memo': {'type': 'string'},
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
        'write_markdown',
        'Write the body of a MARKDOWN page (pageType "markdown"). This is '
        'how you fill in a page made with create_page type:"markdown" - '
        'append_document_text does NOT work on markdown pages. Pass the '
        'WHOLE document in "text" in a SINGLE call (headings, lists, tables, '
        'code fences and ```mermaid diagrams all render). By default the '
        'text REPLACES the body; pass "append":true to add to the end of '
        'what is already there. The page is opened and shown after writing, '
        'so the user sees the result immediately.',
        {
          'pageId': {'type': 'string'},
          'text': {'type': 'string'},
          'append': {'type': 'boolean'},
        },
        ['pageId', 'text']),
    _tool(
        'append_document_text',
        'Append text to the end of a free note used as a notepad '
        '(pageType "paint", or an existing "document" page). '
        'Plain text only (no markup). '
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
        'defaults to the end of that layer and is IGNORED when "texts" is '
        'used; durationMs defaults to 4000. layer 0 is the '
        'back-most and the timeline has only 6 lanes (0-5); captions usually '
        'go on layer 1. '
        'IMPORTANT: to add several captions, pass them ALL AT ONCE in '
        '"texts" (array of strings) in a SINGLE call - do not call this '
        'tool once per caption. Returns itemId(s). '
        'This tool can only ADD. There is no tool to move, re-layer, re-time, '
        're-word or delete an item already on the timeline, and read_page '
        'cannot show the timeline (it lives outside the page JSON). If the '
        'user asks to change something already placed, say so and tell them '
        'to click the block in the video editor - do NOT add a second copy on '
        'another layer and call it moved.',
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
        'is the header). '
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
        'pages cannot hold file tiles); anything else falls back to the open '
        'page. '
        'Returns {path, replaced, attachedToPageId}. When "replaced" is '
        'true the file that was already there was updated - say updated, '
        'not created.',
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
          },
          'rows': {
            'type': 'array',
            'items': {
              'type': 'array',
              'items': {'type': 'string'}
            },
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
        '{papers:[{index, text}], appendsTo}. append_document_text always '
        'adds to the LAST paper ("appendsTo"), so read this first to see what '
        'is already written instead of repeating it.',
        {
          'pageId': {'type': 'string'},
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
        'list_paint_tabs, and select_paint_tab to move between them.',
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
        'buttons are set_header_buttons.',
        {
          'id': {'type': 'string'},
        },
        ['id']),
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
        'Optionally pass pageIds to fill the cells, in the order '
        '0 = top-left, 1 = top-right, 2 = bottom-left, 3 = bottom-right '
        '(ids come from list_pages; document and video-editor pages cannot '
        'go in a pane). Cells you leave out are filled with other pages '
        'automatically. Calling it twice with the same layout is safe - it '
        'does not toggle the split back off; use "off" to close it. '
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
        'Returns {open, fileName, lineCount}. The other text_file_* tools '
        'work ONLY on that one open file - they cannot touch a file that is '
        'merely attached to a page. If "open" is false, nothing is open: do '
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
        'being silently ignored.',
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
        '(an approximate title is rejected, never guessed). Pass '
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
        'have to invent coordinates. Only fall back to x1/y1/x2/y2 when the '
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
  ];

  // ─── ツール実行 ───────────────────────────────────────────────────────

  Map<String, dynamic> _ok(Object data) => {
        'content': [
          {'type': 'text', 'text': data is String ? data : jsonEncode(data)}
        ],
        'isError': false,
      };

  Map<String, dynamic> _err(String message) => {
        'content': [
          {'type': 'text', 'text': message}
        ],
        'isError': true,
      };

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
  static const Set<String> _kImageExts = {
    'jpg', 'jpeg', 'jpe', 'png', 'gif', 'webp', 'bmp',
  };

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

  /// 配列の引数を文字列の並びに直す (空文字は捨てる)。
  static List<String> _stringList(Object? v) {
    if (v is! List) return const [];
    final out = <String>[];
    for (final e in v) {
      final s = '${e ?? ''}'.trim();
      if (s.isNotEmpty) out.add(s);
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
  static Map<String, Object?> _batchResult({
    required List<Map<String, Object?>> created,
    List<Map<String, Object?>> updated = const [],
    List<Map<String, Object?>> unchanged = const [],
    List<Map<String, Object?>> failed = const [],
    Map<String, Object?> extra = const {},
  }) =>
      {
        ...extra,
        'created': created,
        if (updated.isNotEmpty) 'updated': updated,
        if (unchanged.isNotEmpty) 'unchanged': unchanged,
        if (failed.isNotEmpty) 'failed': failed,
        // AI がそのまま利用者へ読み上げられる 1 行 (= 頼まれた数では無く、
        //   実際に変わった数を報告させるため)。
        'summary': 'created ${created.length}, updated ${updated.length}, '
            'unchanged ${unchanged.length}, failed ${failed.length}',
      };

  /// ツール実行 (HTTP 経由と、 アプリ内 AI チャット [MCP チャット] の両方
  /// から呼ばれる)。
  Future<Map<String, dynamic>> callTool(
      String name, Map<String, dynamic> a) async {
    double? numOf(String key) => _numOf(a[key]); // ★ 文字列の "12" も受ける
    // 整数の引数はここを通す。 1 つでも駄目なら、 何もせずに理由を返す
    // (= 半分だけ実行して「成功」 と返すのが一番たちが悪いため)。
    String? intErr;
    int? intOf(String key, {int min = 0, int? max}) {
      final r = _intOf(a[key], key, min: min, max: max);
      if (r.error != null) intErr ??= r.error;
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
          // 画面側 (自動操作パネル) がこの合図を拾って動かす。
          automationRequestFromAssistant.value = text;
          return _ok('自動操作に渡しました: $text\n'
              '実行の様子と結果は自動操作の画面に出ます。 '
              '利用者の許可設定によっては確認を求めるか、 断ることがあります。');
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
      case 'read_page':
        {
          final pid = a['pageId'] as String? ?? '';
          final json = _provider.mcpReadPage(pid);
          if (json == null) {
            return _err('no page has the id "$pid" - call list_pages.');
          }
          // ★ 件数を先頭に置く (= 動作確認で判明: ページの JSON は 5 ノード
          //   でも 3000 文字を超えるので、 長い時に途中で切られると
          //   connections まで届かない。 数だけでも必ず届くようにする)。
          final page = _provider.mcpPageById(pid);
          return _ok({
            'nodeCount': page?.nodes.length ?? 0,
            'connectionCount': page?.connections.length ?? 0,
            // ★ 壊れた添付も先頭へ (件数と同じ理由: 長いページでは後ろが
            //   切られ、 要素ごとの印まで届かない)。
            if (json['brokenAttachments'] != null)
              'brokenAttachments': json['brokenAttachments'],
            if (json['brokenBackground'] != null)
              'brokenBackground': json['brokenBackground'],
            ...json,
          });
        }
      case 'delete_page':
        {
          final id = a['pageId'] as String? ?? '';
          final reason = await _provider.mcpDeletePage(id);
          return reason == null ? _ok('deleted: $id') : _err(reason);
        }
      case 'set_page_type':
        {
          final id = a['pageId'] as String? ?? '';
          final type = a['type'] as String? ?? '';
          final ok = await _provider.mcpSetPageType(id, type);
          if (ok) return _ok('page $id is now "$type"');
          // 知らない id と知らない種別を区別する (= 前は id が違っても
          //   「その種類はありません」 と返り、 原因を取り違えていた)。
          if (_provider.mcpPageById(id) == null) {
            return _err('no page has the id "$id" - call list_pages and use '
                'an id from it.');
          }
          return _err('"$type" is not a page kind. The app has only these: '
              'normal, bookshelf, paint, document, markdown'
              '${kStoreBuild ? '' : ', videoEditor'}. If '
              'the user asked for something else, tell them it does not exist '
              '- do not substitute.');
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
        final id = _provider.mcpCreatePage(
            type: a['type'] as String? ?? 'normal',
            name: a['name'] as String?,
            folderId: wantFolder.isEmpty ? null : wantFolder,
            // ★ 新規はフォルダーの外には作らない (= ユーザー要望)。
            //   外は古いデータのための場所なので、 toRoot は受けない。
            toRoot: false);
        // 実際に出来た種類を返す (= ユーザー報告: 知らない種類を頼まれると
        //   黙って normal を作り、 頼まれた通りに作ったと答えてしまう)。
        return id == null
            ? _err('could not create a "${a['type'] ?? 'normal'}" page: '
                'either "folderId" is not a real folder (call list_folders), '
                'or a free note ("paint") page needs Pro, or the free plan '
                'caps how many pages of each kind there can be. Tell the '
                'user - do not retry with a different type.')
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
            final ids = <String>[];
            // 入力の並びと 1 対 1 で対応させる控え。 ★ 使えない要素を飛ばすと
            //   ids がずれ、 以降の parentIndex が 1 つ手前のノードに繋がって
            //   いた (= 動作確認で判明)。
            final slots = <String>[];
            final failed = <String>[];
            // 親に繋げなかった物 (= 繋がっていないのに「親子で作った」 と
            //   報告してしまうのを防ぐ)。
            final unlinked = <String>[];
            for (final e in batch) {
              final Map<String, dynamic> m;
              if (e is Map) {
                m = e.cast<String, dynamic>();
              } else {
                // 題名だけを並べた形 (["春","夏"]) も受ける。 同じファイルの
                //   add_gallery_item / add_paint_text の texts と揃えた。
                final s = '${e ?? ''}'.trim();
                if (s.isEmpty) {
                  slots.add('');
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
                continue;
              }
              final id = _provider.mcpAddNode(
                pageId,
                title: '${m['title'] ?? ''}',
                x: _numOf(m['x']),
                y: _numOf(m['y']),
                // 文字列以外が来ても途中で例外にしない (= 200 個の途中で
                //   落ちると、 作った分の一覧すら返せなくなる)。
                memo: m['memo'] == null ? null : '${m['memo']}',
                url: m['url'] == null ? null : '${m['url']}',
                colorValue: _argbOf(m['color']),
              );
              if (id == null) {
                failed.add('${m['title'] ?? ''}');
                slots.add('');
                continue;
              }
              ids.add(id);
              slots.add(id);
              // 親が指定されていればその場で繋ぐ。 parentIndex はこの呼び出しの
              // 中で先に作ったノードの番号 (0 始まり)。
              var parent = '${m['parentId'] ?? ''}'.trim();
              // ★ 番号は整数だけ (= 動作検証レポート 不具合 3: 0.9 を 0 に
              //   丸めていたので、 頼まれたのとは**別の**ノードへ繋いで
              //   おきながら成功と返していた)。 丸めずに「繋げなかった」 へ。
              final piR = _intOf(m['parentIndex'], 'parentIndex');
              final pi = piR.value;
              if (parent.isEmpty && piR.error != null) {
                unlinked.add('${m['title'] ?? ''}');
              } else if (parent.isEmpty && pi != null) {
                if (pi >= 0 && pi < slots.length - 1 && slots[pi].isNotEmpty) {
                  parent = slots[pi];
                } else {
                  // 前に作った物を指していない parentIndex は使えない。
                  unlinked.add('${m['title'] ?? ''}');
                }
              }
              if (parent.isNotEmpty &&
                  !_provider.mcpConnectNodes(pageId, parent, id)) {
                unlinked.add('${m['title'] ?? ''}');
              }
            }
            if (ids.isEmpty) {
              return _err(_provider.mcpPageById(pageId) == null
                  ? 'page not found: "$pageId"'
                  : 'nothing was added: every entry in "nodes" was unusable. '
                      'Each entry needs at least a "title".');
            }
            // 座標を渡さないと全部同じ場所に重なる。
            // ★ 以前は「後で tidy_page を呼んでね」 と返すだけだった。
            //   呼び忘れ・途中で停止のどちらでも団子のまま残るので
            //   (= ユーザー報告: 新規ページで全部が一か所に出る)、
            //   **足したノードだけ**その場で並べる。 ページ全体は触らない
            //   ので、 利用者が手で組んだ配置は崩れない。
            final placed =
                batch.any((e) => e is Map && (e['x'] != null || e['y'] != null));
            if (!placed) _provider.mcpArrangeNewNodes(pageId, ids);
            return _ok({
              // id と題名を組で返す (= 続けて connect_nodes を呼ぶ時に、
              //   どの id がどのノードか迷わないように)。
              'nodes': _provider.mcpNodeIndex(pageId).where(
                  (e) => ids.contains(e['id'])).toList(),
              'nodeIds': ids,
              if (failed.isNotEmpty) 'failed': failed,
              if (unlinked.isNotEmpty) 'unlinked': unlinked,
              if (!placed && ids.length > 1)
                'note': 'the ${ids.length} new nodes were laid out next to '
                    'their parents automatically. Call tidy_page only if you '
                    'want the whole page rearranged.',
            });
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
          final id = _provider.mcpAddNode(
            pageId,
            title: '${a['title'] ?? ''}',
            x: numOf('x'),
            y: numOf('y'),
            memo: a['memo'] == null ? null : '${a['memo']}',
            url: a['url'] == null ? null : '${a['url']}',
            colorValue: _argbOf(a['color']),
          );
          return id == null ? _err('page not found') : _ok({'nodeId': id});
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
          final url = a['url'] == null ? null : '${a['url']}';
          final clearUrl = a['clearUrl'] == true;
          final ok = _provider.mcpUpdateNode(
            pageId,
            key,
            title: a['title'] as String?,
            memo: a['memo'] as String?,
            x: numOf('x'),
            y: numOf('y'),
            colorValue: color,
            url: url,
            clearUrl: clearUrl,
          );
          if (!ok) {
            return _err('no node "$key" on that page. Available nodes (use '
                'the "title" value as "node"): '
                '${jsonEncode(_provider.mcpNodeIndex(pageId))}');
          }
          // どのノードを書き換えたかを返す (= 題名で指した時に、 思った物と
          //   違うノードを直していないか AI が確かめられるように)。
          final rid = _provider.mcpResolveNodeId(pageId, key);
          final hit = _provider.mcpNodeIndex(pageId).firstWhere(
              (e) => e['id'] == rid,
              orElse: () => const <String, String>{});
          return _ok({
            'updated': true,
            if (rid != null) 'nodeId': rid,
            if (hit['title'] != null) 'title': hit['title'],
            // 実際に効いた分だけを返す (色が範囲外なら黙って落ちるため)。
            if (color != null) 'color': color,
            if (!clearUrl && url != null && url.trim().isNotEmpty)
              'url': url.trim(),
            if (clearUrl) 'urlCleared': true,
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
          // まとめて消せる形も持たせる (= 1 件ずつだと AI が取りこぼす)。
          final batch = a['nodes'];
          if (batch is List && batch.isNotEmpty) {
            // 何を消したかを題名で返す (= 数だけだと、 頼まれた物と違う
            //   ノードが消えていても AI が気付けない)。
            final removed = <String>[];
            final missed = <String>[];
            final files = <Map<String, Object?>>[];
            for (final e in batch) {
              final k = '${e ?? ''}'.trim();
              // 消す前に添付の在処を控える (消した後では引けない)。
              final was = disposeMode == 'no'
                  ? ''
                  : _provider.mcpAttachmentPathOf(pageId, k);
              final title = _provider.mcpDeleteNode(pageId, k);
              if (title != null && was.isNotEmpty) {
                files.add({
                  'path': was,
                  ...await _provider.mcpDisposeAttachmentFile(
                      was, disposeMode),
                });
              }
              if (title == null) {
                missed.add(k);
              } else {
                removed.add(title);
              }
            }
            return removed.isEmpty
                ? _err('none of $missed were found. Available nodes: '
                    '${jsonEncode(_provider.mcpNodeIndex(pageId))}')
                : _ok({
                    'deleted': removed,
                    if (missed.isNotEmpty) 'failed': missed,
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
          final removedTitle = _provider.mcpDeleteNode(pageId, key);
          if (removedTitle == null) {
            return _err('no node "$key" on that page. Available nodes (use '
                'the "title" value as "node"): '
                '${jsonEncode(_provider.mcpNodeIndex(pageId))}');
          }
          return _ok({
            'deleted': removedTitle,
            if (wasOne.isNotEmpty)
              'file': {
                'path': wasOne,
                ...await _provider.mcpDisposeAttachmentFile(
                    wasOne, disposeMode),
              },
          });
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
            return _err('no page has the id "$pageId" - call list_pages.');
          }
          final type = page.pageType ?? 'normal';
          // ギャラリーは「セルを左上から詰め直す」 整列で応える
          // (= ユーザー報告: 整列を頼むと「必要ありません」 と断られる)。
          if (type == 'bookshelf') {
            if (page.nodes.isEmpty) {
              return _err('nothing to tidy: "$pageId" has 0 item(s).');
            }
            _provider.mcpTidyGallery(pageId);
            return _ok('packed ${page.nodes.length} gallery item(s) into the '
                'grid from the top-left on $pageId');
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
          _provider.mcpTidyPage(pageId);
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
          if (a['clear'] != true &&
              bgTpl.isEmpty &&
              bgImg.isNotEmpty &&
              !File(bgImg).existsSync()) {
            return _err('background image file not found: $bgImg');
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
          );
          if (!ok) {
            return _err('page not found, or no valid background was given '
                '(use template / imagePath / clear)');
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
              'opacityPercent': bgPage.backgroundOpacityPercent,
              'fit': bgPage.backgroundFit,
              'hueDegrees': bgPage.backgroundHueDegrees,
              'saturationPercent': bgPage.backgroundSaturationPercent,
              'brightnessPercent': bgPage.backgroundBrightnessPercent,
            },
          });
        }
      case 'connect_nodes':
        {
          final pageId = a['pageId'] as String? ?? '';
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
          for (var i = 0; i < entries.length; i++) {
            final m = entries[i];
            final f = key(m, 'from', 'fromId');
            final t = key(m, 'to', 'toId');
            final label = m['label'] as String?;
            if (f.isEmpty || t.isEmpty) {
              failed.add({
                'index': i,
                'from': f,
                'to': t,
                'reason': '"from" and "to" are both required',
              });
              continue;
            }
            final amb = _ambiguous(pageId, f, 'from') ??
                _ambiguous(pageId, t, 'to');
            if (amb != null) {
              failed.add({
                'index': i,
                'from': f,
                'to': t,
                'reason': amb,
              });
              continue;
            }
            final existed = _provider.mcpConnectionExists(pageId, f, t);
            if (!_provider.mcpConnectNodes(pageId, f, t, label: label)) {
              failed.add({
                'index': i,
                'from': f,
                'to': t,
                'reason': 'no node on this page matched "from" and/or "to"',
              });
              continue;
            }
            final item = <String, Object?>{
              'index': i,
              'fromId': _provider.mcpResolveNodeId(pageId, f),
              'toId': _provider.mcpResolveNodeId(pageId, t),
            };
            if (!existed) {
              created.add(item);
            } else if (label != null && label.trim().isNotEmpty) {
              updated.add({...item, 'changed': 'label'});
            } else {
              unchanged.add({...item, 'reason': 'already connected'});
            }
          }
          if (created.isEmpty && updated.isEmpty && unchanged.isEmpty) {
            // 「見つからない」 だけでは AI が直しようがないので、 その
            //   ページに在るノードの id と題名を返して選び直させる。
            //   ★ 一覧を添えるのはここだけ。 空配列は上の _emptyBatch で
            //   止まっているので、 0 件で一覧を吐く事はもう無い
            //   (= 動作検証レポート 不具合 5)。
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
          return _ok({'nodeId': id, 'rows': rows.length});
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
        if (path == null || path.isEmpty) {
          return _err('imageBase64 or imagePath is required');
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
        return id == null ? _err('page not found') : _ok({'nodeId': id});
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
            for (var i = 0; i < many.length; i++) {
              final t = many[i];
              if (!seen.add(t.toLowerCase())) dup.add(t);
              final id = _provider.mcpAddGalleryItem(pageId, text: t);
              if (id == null) {
                failed.add({
                  'index': i,
                  'text': t,
                  'reason': 'not a gallery page (or page not found)',
                });
                continue;
              }
              created.add({'index': i, 'nodeId': id, 'title': t});
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
                // add_node と同じ鍵で返す (= 続けて指せるように)。
                'nodeIds': [for (final e in created) e['nodeId']],
                if (dup.isNotEmpty)
                  'note': 'these titles now appear more than once on the page '
                      '(${dup.join(', ')}): address those tiles by nodeId, '
                      'not by title.',
              },
            ));
          }
          // 題名も memo も絵も無ければ、 中身の無いタイルは作らない。
          if (!_hasContent(a['text']) &&
              !_hasContent(a['memo']) &&
              !_hasContent(a['imagePath'])) {
            return _err('nothing to add: pass "texts" (an array of titles), '
                'or at least one of "text" / "memo" / "imagePath". '
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
          final id = _provider.mcpAddGalleryItem(
            pageId,
            text: a['text'] as String?,
            memo: a['memo'] as String?,
            imagePath: gimg.isEmpty ? null : gimg,
          );
          return id == null
              ? _err('not a gallery page (or page not found): $pageId')
              : _ok({'nodeId': id});
        }
      case 'add_paint_text':
        {
          final pageId = a['pageId'] as String? ?? '';
          final many = _stringList(a['texts']);
          final ptEmpty = _emptyBatch(
              a, 'texts', 'Pass at least one line, or send a single "text".',
              usable: many.length);
          if (ptEmpty != null) return ptEmpty;
          final lines = many.isNotEmpty
              ? many
              : [if ((a['text'] as String? ?? '').isNotEmpty) a['text'] as String];
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
          var wrote = 0;
          for (final line in lines) {
            final ok = await _provider.mcpAddPaintText(
              pageId,
              line,
              // まとめ書きの時は自動で縦に積ませる。
              x: many.isNotEmpty ? null : numOf('x'),
              y: many.isNotEmpty ? null : numOf('y'),
              size: numOf('size'),
              // ★ add_node と同じ正し方を通す (= 動作確認で判明: 「赤」 の
              //   つもりの 0xFF0000 は α=0 で透明になり、 文字が見えない
              //   まま成功と返っていた。 色名の文字列は型エラーで落ちて
              //   いた)。
              colorValue: _argbOf(a['color']),
            );
            if (ok) wrote++;
          }
          return wrote > 0
              ? _ok({'written': wrote})
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
      case 'write_markdown':
        {
          final pageId = a['pageId'] as String? ?? '';
          final text = a['text'] as String? ?? '';
          if (text.trim().isEmpty) {
            return _err('"text" was empty - nothing was written. Write the '
                'markdown you want the page to hold.');
          }
          final ok = await _provider.mcpWriteMarkdown(pageId, text,
              append: a['append'] == true);
          if (ok) return _ok({'pageId': pageId, 'written': text.length});
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
          // 種類は合っているのに書けなかった = 保存できなかった。
          //   「markdown なのに markdown ではない」 と言わないこと。
          return _err('"$pageId" is a markdown page but the write failed '
              '(the app could not save it). Do not retry in a loop - tell '
              'the user the page could not be saved.');
        }
      case 'append_document_text':
        {
          final pageId = a['pageId'] as String? ?? '';
          final many = _stringList(a['texts']);
          final adEmpty = _emptyBatch(a, 'texts',
              'Pass at least one paragraph, or send a single "text".',
              usable: many.length);
          if (adEmpty != null) return adEmpty;
          final paras = many.isNotEmpty
              ? many
              : [if ((a['text'] as String? ?? '').isNotEmpty) a['text'] as String];
          // 空白だけの段落は捨てられる (add_paint_text と同じ理由)。
          if (paras.every((p) => p.trim().isEmpty)) {
            return _err('nothing was appended: blank / whitespace-only text '
                'is discarded - this app cannot insert empty lines. Tell the '
                'user instead of retrying.');
          }
          var wrote = 0;
          for (final para in paras) {
            if (await _provider.mcpAppendDocumentText(pageId, para)) wrote++;
          }
          return wrote > 0
              ? _ok({'appended': wrote})
              : _err('could not append to "$pageId": append_document_text '
                  'works only on pages whose type is '
                  '"paint" (free note) or "document" (notepad). For a '
                  '"markdown" page use write_markdown instead.');
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
            return _err('$intErr '
                '(milliseconds are whole numbers: 1.5 seconds = 1500)');
          }
          final veEmpty = _emptyBatch(a, 'texts',
              'Pass at least one caption, or use the single "kind"/"text" '
              'form.',
              usable: _stringList(a['texts']).length);
          if (veEmpty != null) return veEmpty;
          // まとめて字幕を置ける形 (= 1 件ずつだと AI が取りこぼす)。
          final batch = a['texts'];
          if (batch is List && batch.isNotEmpty) {
            final ids = <String>[];
            // ★ startMs を捨てない (= 動作検証レポート: まとめて字幕を置くと
            //   開始時刻が無視され、 全部が勝手な位置に並んでいた)。
            //   1 枚目は言われた時刻から、 2 枚目からはその後ろへ続ける
            //   (時刻を渡されていない時は今までどおりアプリ任せ)。
            var nextStart = veStart;
            for (final e in batch) {
              final t = '${e ?? ''}'.trim();
              if (t.isEmpty) continue;
              final one = await _provider.mcpAddVideoEditorItem(
                pageId,
                kind: 'text',
                text: t,
                startMs: nextStart,
                layer: veLayer ?? 1,
                durationMs: veDuration,
                fontSize: numOf('fontSize'),
                colorValue: veColor,
              );
              if (one != null) ids.add(one);
              if (nextStart != null) nextStart += veDuration ?? 4000;
            }
            return ids.isEmpty
                ? _err('not a video editor page: $pageId')
                : _ok({'itemIds': ids});
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
              ? _err('not a video editor page, or kind/text/path missing: '
                  '$pageId - add_video_editor_item only works on pages '
                  'whose type is "videoEditor"')
              : _ok({'itemId': id});
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
            'paragraphs': _stringList(a['paragraphs']),
            'rows': _rowsOf(a['rows']),
            'slides': slides,
            // ★ 配色と「後ろへ足すだけ」 を画面側へ渡す (= 動作確認で判明:
            //   この 2 つは道具の説明には書いてあるのに、 ここで渡し忘れて
            //   いたので、 配色を指定しても効かず、 追記も新規作成に
            //   なっていた)。
            'theme': '${a['theme'] ?? ''}',
            'append': a['append'] == true,
          });
          final path = made?['path'] as String?;
          if (path == null) {
            return _err('could not create the file (unsupported kind, or the '
                'page was not found)');
          }
          // ★ 上書きした時に「新しく作りました」 と答えさせない (= ユーザー
          //   報告: 直してと頼んだのに 2 つ目が出来たと言われた)。
          final replaced = made?['replaced'] == true;
          const replacedNote =
              'The file that was already there was REWRITTEN IN PLACE (same '
              'name, same tile - no second file and no second tile were '
              'made). Tell the user the file was updated, not created.';
          // ★ 貼れたかどうかを見て返す (= 動作確認で判明: フリーノートの
          //   ページを渡すとタイルを置く場所が無く、 ファイルはどこにも
          //   貼られないのに成功と返っていた。 別のページへ逃げる事もある)。
          final reqPage = _provider.mcpPageById(reqId);
          bool holds(dynamic p) =>
              p != null && p.nodes.values.any((n) => n.attachmentPath == path);
          if (holds(reqPage)) {
            return _ok({
              'path': path,
              'attachedToPageId': reqPage!.id,
              'replaced': replaced,
              if (replaced) 'note': replacedNote,
            });
          }
          String? hostId;
          for (final p in _provider.pages) {
            if (holds(p)) {
              hostId = p.id;
              break;
            }
          }
          return _ok({
            'path': path,
            if (hostId != null) 'attachedToPageId': hostId,
            'replaced': replaced,
            'note': hostId == null
                ? 'The file WAS saved at this path but is NOT pinned to any '
                    'page: a "${reqPage?.pageType ?? 'unknown'}" page cannot '
                    'hold a file tile. Tell the user the path, or ask for a '
                    'mind map ("normal") or gallery ("bookshelf") page.'
                : 'The requested page cannot hold a file tile, so it was '
                    'pinned to page $hostId instead - say so rather than '
                    'claiming it is on the page that was asked for.',
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
                if (e.key != 'needsUser') e.key: e.value,
              if (c['needsUser'] == 'true') 'needsUser': true,
            }
        ]);
      case 'update_decoration':
        {
          final pageId = a['pageId'] as String? ?? '';
          final did = '${a['decorationId'] ?? ''}'.trim();
          if (did.isEmpty) return _err('"decorationId" is required');
          final dLayer = intOf('layer', min: -1 << 31);
          if (intErr != null) return _err(intErr!);
          final argb = _argbOf(a['color']);
          final ok = _provider.mcpUpdateDecoration(
            pageId,
            did,
            kind: a['kind'] as String?,
            colorRgb: argb == null ? null : (argb & 0xFFFFFF),
            strokeWidth: _numOf(a['strokeWidth']),
            text: a['text'] as String?,
            filled: a['filled'] is bool ? a['filled'] as bool : null,
            layer: dLayer,
          );
          return ok
              ? _ok({'updated': did})
              : _err('no decoration "$did" on that page, or "kind" was not a '
                  'real shape name (read_page lists them under '
                  '"decorations")');
        }
      case 'update_video_editor_item':
        {
          final pageId = a['pageId'] as String? ?? '';
          final vLayer = intOf('layer', min: 0, max: 5);
          final vStart = intOf('startMs');
          final vDur = intOf('durationMs', min: 1);
          if (intErr != null) {
            return _err('$intErr '
                '(milliseconds are whole numbers: 1.5 seconds = 1500)');
          }
          final r = await _provider.mcpEditVideoEditorItem(
            pageId,
            '${a['itemId'] ?? ''}',
            layer: vLayer,
            startMs: vStart,
            durationMs: vDur,
            text: a['text'] as String?,
            remove: a['remove'] == true,
          );
          return r['ok'] == true
              ? _ok(r)
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
          final r = await _provider.mcpReadDocument(pid);
          return r == null
              ? _err('"$pid" is not a notepad ("document") or free-note '
                  '("paint") page, or there is no such page - call list_pages')
              : _ok(r);
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
            return _ok(needsUser
                ? 'opened: $id - a window is now on screen and the user has '
                    'to finish it there (and a plan upgrade prompt may have '
                    'appeared instead). Say the window is open; do not claim '
                    'the action itself is done.'
                : 'launched: $id');
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
          return r == null
              ? _err('no text file is open in the app text editor - '
                  'ask the user to open one first')
              : _ok(r);
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
            if (nm.trim().isEmpty) {
              failed.add({
                'index': i,
                'pageId': pageId,
                'reason': 'the new name was blank',
              });
              return;
            }
            final cur = _provider.mcpPageById(pageId);
            if (cur != null && cur.name == nm.trim()) {
              unchanged.add({
                'index': i,
                'pageId': pageId,
                'name': nm.trim(),
                'reason': 'already had that name',
              });
              return;
            }
            if (_provider.mcpRenamePage(pageId, nm)) {
              renamed.add({'index': i, 'pageId': pageId, 'name': nm.trim()});
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
          final order = _provider.mcpReorderPages(ids);
          return _ok({'order': order});
        }
      case 'list_folders':
        return _ok(_provider.mcpListFolders());
      case 'create_folder':
        {
          final id = _provider.mcpCreateFolder(a['name'] as String?);
          final hit = _provider.mcpListFolders().firstWhere(
              (e) => e['id'] == id,
              orElse: () => const <String, dynamic>{});
          return _ok({
            'folderId': id,
            if (hit['name'] != null) 'name': hit['name'],
          });
        }
      case 'rename_folder':
        {
          final fid = '${a['folderId'] ?? ''}'.trim();
          final ok = _provider.mcpRenameFolder(fid, '${a['name'] ?? ''}');
          return ok
              ? _ok({'folderId': fid, 'name': '${a['name']}'.trim()})
              : _err('could not rename folder "$fid": no folder has that '
                  'id, or the name was blank - call list_folders.');
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
          final target = toRoot || fid.isEmpty ? null : fid;
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
            if (!_provider.mcpMovePageToFolder(pid, target)) {
              failed.add({
                'index': i,
                'pageId': pid,
                'reason': 'unknown page id, or that folderId does not exist',
              });
              continue;
            }
            (already ? same : moved).add({
              'index': i,
              'pageId': pid,
              if (already) 'reason': 'already in that folder',
            });
          }
          if (moved.isEmpty && same.isEmpty) {
            return _err('could not move '
                '${failed.map((e) => e['pageId']).join(', ')}: unknown '
                'page id, or that folderId does not exist '
                '- call list_pages / list_folders.');
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
          final missed = <String>[];
          for (final p in pairs) {
            if (p[0].isEmpty || p[1].isEmpty) continue;
            // 実際に消えた本数を数える (= ユーザー報告: 2 本消えたのに
            // 1 と返っていた)。
            final removedCount =
                _provider.mcpDisconnectNodes(pageId, p[0], p[1]);
            if (removedCount > 0) {
              done += removedCount;
            } else {
              missed.add('${p[0]} - ${p[1]}');
            }
          }
          if (done == 0) {
            return _err('no line was removed for ${missed.join(', ')} '
                '(either the node was not found, or those two were not '
                'connected). Nodes on this page: '
                '${jsonEncode(_provider.mcpNodeIndex(pageId))}');
          }
          return _ok({
            'disconnected': done,
            if (missed.isNotEmpty) 'notConnected': missed,
          });
        }
      // ── 図形 (装飾) ──
      case 'add_decoration':
        {
          final pageId = a['pageId'] as String? ?? '';
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
              final missed = [
                for (final k in around)
                  if (_provider.mcpResolveNodeId(pageId, k) == null) k
              ];
              if (missed.length == around.length) {
                return 'none of the nodes in "aroundNodes" exist on this '
                    'page (${missed.join(', ')}) - nothing was drawn. Call '
                    'read_page and use the exact titles';
              }
              return null; // 1 つでも見つかれば囲める
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

          String? addOne(Map<String, dynamic> m) => _provider.mcpAddDecoration(
                pageId,
                kind: '${m['kind'] ?? ''}',
                x1: _numOf(m['x1']),
                y1: _numOf(m['y1']),
                x2: _numOf(m['x2']),
                y2: _numOf(m['y2']),
                aroundNodeIds: _stringList(m['aroundNodes']),
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
            final id = addOne(m);
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
          return _ok({'query': q, 'results': hits});
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
