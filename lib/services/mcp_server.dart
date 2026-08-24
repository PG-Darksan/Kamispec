import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../providers/mind_map_provider.dart';

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

  final MindMapProvider _provider;
  HttpServer? _http;

  /// 稼働中の MCP エンドポイント URL (停止中は null)。
  String? url;

  /// 外部アプリからの接続に必要な合言葉 (= ユーザー要望: 別のプログラムから
  /// 勝手に操作されないように)。 起動のたびに作り直す。 これを知らない
  /// プログラムは 401 で弾かれる。
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
        debugLog('MCP サーバー起動: $url');
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
    if (t == null || t.isEmpty) return true; // 合言葉なし運用
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
        return {
          'protocolVersion':
              (params['protocolVersion'] as String?) ?? '2025-06-18',
          'capabilities': {
            'tools': {'listChanged': false},
          },
          'serverInfo': {'name': 'kamispec-mcp', 'version': '1.0.0'},
        };
      case 'ping':
        return {};
      case 'tools/list':
        return {'tools': toolDefs};
      case 'tools/call':
        return callTool(
          params['name'] as String? ?? '',
          (params['arguments'] as Map?)?.cast<String, dynamic>() ?? const {},
        );
      default:
        throw _McpMethodNotFound();
    }
  }

  // ─── ツール定義 ───────────────────────────────────────────────────────

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
      };

  /// ツール定義 (アプリ内 AI チャットからも共用するため公開)。
  static final List<Map<String, dynamic>> toolDefs = [
    _tool('list_pages',
        'List all pages (id, name, type: normal/bookshelf/paint/..., node count).', {}),
    _tool(
        'read_page',
        'Read one page as full JSON (nodes, connections, decorations).',
        {'pageId': {'type': 'string'}},
        ['pageId']),
    _tool(
        'delete_page',
        'Delete a page permanently. Use this when the user explicitly asks to '
        'delete/remove a page. Cannot delete the last remaining page. '
        'Call list_pages first to get the pageId.',
        {'pageId': {'type': 'string'}},
        ['pageId']),
    _tool(
        'set_page_type',
        'Change an existing page to another type without losing its nodes. '
        'type: "normal" (mind map), "bookshelf" (gallery), "paint" (free '
        'note), "document" (notepad), "videoEditor", "aiStudio". '
        'Use this when the user asks to convert/turn a page into another kind.',
        {
          'pageId': {'type': 'string'},
          'type': {'type': 'string'},
        },
        ['pageId', 'type']),
    _tool(
        'clear_chat_history',
        'Clear this AI assistant conversation history. Use it when the user '
        'asks to clear/reset the chat. The current request stays.',
        {}),
    _tool(
        'set_header_buttons',
        'Put buttons on the app header bar. ids are command ids from '
        'list_app_commands. replace=true swaps the whole row, false (default) '
        'appends. Use this when the user asks to place buttons in the header.',
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
        '"paint" (free note - also the place to write documents) or '
        '"videoEditor" (video timeline). Returns the new pageId. '
        'There is no "document" type to create: to write prose, make a '
        '"paint" page and use append_document_text on it.',
        {
          'type': {
            'type': 'string',
            'enum': ['normal', 'bookshelf', 'paint', 'videoEditor']
          },
          'name': {'type': 'string'},
        },
        ['type']),
    _tool(
        'add_node',
        'Add node(s) to a mind-map page. PREFER the batch form: pass "nodes" '
        'as an array of {title, memo?, url?, color?, parentIndex?, parentId?} '
        'and every node is created in ONE call. "parentIndex" is the 0-based '
        'index of an earlier node in the same array and also draws the '
        'connection, so a whole map (centre + children) is one call. '
        'Coordinates are optional and normally unnecessary - the page is '
        'tidied into a tree afterwards. Returns nodeIds in the same order. '
        'ALWAYS put links in "url", never as bare text inside "memo": a node '
        'with "url" becomes a real clickable link, and a YouTube WATCH url '
        '(https://www.youtube.com/watch?v=VIDEOID or https://youtu.be/VIDEOID) '
        'becomes an embedded video node with a thumbnail that plays in the '
        'app. Search urls (/results?search_query=...) are NOT videos, so give '
        'the actual watch url when you know the video. "memo" and "url" can '
        'be used together on the same node.',
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
        '("nodeId" is accepted as an alias.)',
        {
          'pageId': {'type': 'string'},
          'node': {'type': 'string'},
          'nodeId': {'type': 'string'},
          'title': {'type': 'string'},
          'memo': {'type': 'string'},
          'x': {'type': 'number'},
          'y': {'type': 'number'},
        },
        ['pageId']),
    _tool(
        'delete_node',
        'Delete a node (and its connections) from a page. "node" accepts '
        'EITHER the node id OR its TITLE. To remove several at once pass '
        '"nodes" (array of ids or titles).',
        {
          'pageId': {'type': 'string'},
          'node': {'type': 'string'},
          'nodeId': {'type': 'string'},
          'nodes': {
            'type': 'array',
            'items': {'type': 'string'},
          },
        },
        ['pageId']),
    _tool(
        'generate_page_background',
        'Draw a NEW background image with AI and set it as the page '
        'background. This is the preferred way to change a background: '
        'describe the picture you want in "prompt" (English works best, be '
        'concrete about subject, colours and mood) and an image is generated '
        'and applied. Costs one image generation from the prepaid credit. '
        'Optionally set opacityPercent (0-100, default 70) and '
        'fit (cover/contain/tile, default cover).',
        {
          'pageId': {'type': 'string'},
          'prompt': {'type': 'string'},
          'opacityPercent': {'type': 'integer'},
          'fit': {
            'type': 'string',
            'enum': ['cover', 'contain', 'tile']
          },
        },
        ['pageId', 'prompt']),
    _tool(
        'set_page_background',
        'Set the page background from an existing picture, or remove it. '
        'Prefer generate_page_background when the user just describes the '
        'look they want. Use "imagePath" for an absolute path to an image '
        'file already on this device, "clear": true to remove the background, '
        'or "template" for one of the built-in ones (wood, chalkboard, ocean, '
        'sakura, fireworks, castle, aurora, nightSky, galaxy, rain, nature, '
        'blueprint, midnight, sage, sunset). '
        'Optionally adjust opacityPercent (0-100), fit (cover/contain/tile) '
        'and the tone (hueDegrees -180..180, saturationPercent 0-200, '
        'brightnessPercent 20-200).',
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
        ['pageId']),
    _tool(
        'connect_nodes',
        'Connect nodes with arrow lines. PREFER the batch form: pass '
        '"connections" as an array of {from, to, label?} to make every '
        'link in ONE call. '
        'IMPORTANT: "from"/"to" accept EITHER the node id OR the node '
        'TITLE exactly as shown on the map (e.g. {"from":"春","to":"夏",'
        '"label":"次の季節へ"}). Using titles is recommended - you do not '
        'need to look up ids. ("fromId"/"toId" are accepted as aliases.) '
        'Connecting the same pair twice just updates the label.',
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
        'Add an image node to a page. Provide the image either as base64 (imageBase64 + fileName like "chart.png") or as an absolute local file path (imagePath). Returns nodeId.',
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
        'default. Returns nodeId.',
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
        '"texts" (array of strings) in a SINGLE call.',
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
        ['pageId', 'text']),
    _tool(
        'append_document_text',
        'Append text to the end of a free note used as a notepad '
        '(pageType "paint", or an existing "document" page). '
        'Plain text only (no markup). '
        'IMPORTANT: to write several paragraphs, pass them ALL AT ONCE in '
        '"texts" (array of strings) in a SINGLE call.',
        {
          'pageId': {'type': 'string'},
          'texts': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'text': {'type': 'string'},
        },
        ['pageId']),
    _tool(
        'add_video_editor_item',
        'Add items to the timeline of a VIDEO EDITOR page (pageType '
        '"videoEditor"). kind: "text" (caption; requires text), "video" or '
        '"image" (requires an absolute local path). startMs defaults to the '
        'end of that layer, durationMs defaults to 4000. layer 0 is the '
        'back-most; captions usually go on layer 1. '
        'IMPORTANT: to add several captions, pass them ALL AT ONCE in '
        '"texts" (array of strings) in a SINGLE call - do not call this '
        'tool once per caption. Returns itemId(s).',
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
        'Choose "kind": '
        '"xlsx"/"csv" -> pass "rows" (array of arrays of strings; first row '
        'is the header). '
        '"docx"/"txt"/"md"/"pdf" -> pass "title" and "paragraphs" (array of '
        'strings, one per paragraph); "pdf" may ALSO take "rows" to append a '
        'table. '
        '"pptx" -> pass "slides" (array of objects: '
        '{"title": "...", "bullets": ["...", "..."]}). '
        'Pass a pageId of a MIND MAP or GALLERY page so the file can be '
        'pinned there (free-note / video pages cannot hold file tiles). '
        'Returns the saved file path.',
        {
          'pageId': {'type': 'string'},
          'kind': {
            'type': 'string',
            'enum': ['xlsx', 'csv', 'docx', 'pptx', 'pdf', 'txt', 'md']
          },
          'fileName': {'type': 'string'},
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
              },
            },
          },
        },
        ['pageId', 'kind']),
    _tool(
        'list_app_commands',
        'List the app features that can be launched (flashcards, silent '
        'camera, calendar, QR reader, timer, and so on). Returns id + label '
        'pairs. Call this first when the user asks to open or start a '
        'feature you are not sure about.',
        {}),
    _tool(
        'run_app_command',
        'Launch one app feature by its id (see list_app_commands). Example '
        'ids: "flashcards" (flash cards), "silentCamera" (silent camera), '
        '"calendar", "qrReader". The feature opens on screen for the user.',
        {
          'id': {'type': 'string'},
        },
        ['id']),
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
        '"qa" (bug checklist). The text is Markdown with Mermaid diagrams.',
        {
          'name': {'type': 'string'},
        },
        ['name']),
    // ─── 開いているテキストファイル (= ユーザー要望: テキストエディタの
    //     中身を MCP / AI から編集できるように) ─────────────────────────
    _tool(
        'text_file_status',
        'Check the text file currently open in the app text editor. '
        'Returns {open, fileName, lineCount}. The other text_file_* tools '
        'work on this file. If "open" is false, no text editor is open - '
        'ask the user to open a text file first.',
        {}),
    _tool(
        'text_file_read',
        'Read the text file currently open in the app text editor as '
        'numbered lines. Optionally pass startLine/endLine (1-based, '
        'inclusive) to read only part of a long file.',
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
        'be the only edit in the call. The change appears in the editor '
        'immediately; the user saves the file themselves.',
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
        });
      } else {
        out.add({'title': '${e ?? ''}', 'bullets': const <String>[]});
      }
    }
    return out;
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

  /// ツール実行 (HTTP 経由と、 アプリ内 AI チャット [MCP チャット] の両方
  /// から呼ばれる)。
  Future<Map<String, dynamic>> callTool(
      String name, Map<String, dynamic> a) async {
    double? numOf(String key) => (a[key] as num?)?.toDouble();
    switch (name) {
      case 'list_pages':
        return _ok(_provider.mcpListPages());
      case 'read_page':
        final json = _provider.mcpReadPage(a['pageId'] as String? ?? '');
        return json == null ? _err('page not found') : _ok(json);
      case 'delete_page':
        {
          final id = a['pageId'] as String? ?? '';
          final ok = await _provider.mcpDeletePage(id);
          return ok
              ? _ok('deleted: $id')
              : _err('could not delete "$id" (unknown pageId, or it is the '
                  'last remaining page). Call list_pages for valid ids.');
        }
      case 'set_page_type':
        {
          final id = a['pageId'] as String? ?? '';
          final type = a['type'] as String? ?? '';
          final ok = await _provider.mcpSetPageType(id, type);
          return ok
              ? _ok('page $id is now "$type"')
              : _err('could not change "$id" to "$type". Valid types: '
                  'normal, bookshelf, paint, document, videoEditor, aiStudio.');
        }
      case 'clear_chat_history':
        return _provider.mcpClearChat()
            ? _ok('chat history cleared')
            : _err('the chat view is not available right now');
      case 'set_header_buttons':
        {
          final raw = (a['ids'] as List?) ?? const [];
          final ids = raw.map((e) => '$e').toList();
          final placed = await _provider.mcpSetHeaderButtons(ids,
              replace: a['replace'] == true);
          return _ok({'header': placed});
        }
      case 'create_page':
        final id = _provider.mcpCreatePage(
            type: a['type'] as String? ?? 'normal',
            name: a['name'] as String?);
        return id == null
            ? _err('could not create page (plan limit?)')
            : _ok({'pageId': id});
      case 'add_node':
        {
          final pageId = a['pageId'] as String? ?? '';
          // 1 件ずつ呼ぶ形だけだと AI が途中で取りこぼす (4 個頼んで 1 個しか
          // 置かれなかった)。 まとめて置ける形も持たせる。
          final batch = a['nodes'];
          if (batch is List && batch.isNotEmpty) {
            final ids = <String>[];
            final failed = <String>[];
            for (final e in batch) {
              if (e is! Map) continue;
              final m = e.cast<String, dynamic>();
              final id = _provider.mcpAddNode(
                pageId,
                title: '${m['title'] ?? ''}',
                x: (m['x'] as num?)?.toDouble(),
                y: (m['y'] as num?)?.toDouble(),
                memo: m['memo'] as String?,
                url: m['url'] as String?,
                colorValue: (m['color'] as num?)?.toInt(),
              );
              if (id == null) {
                failed.add('${m['title'] ?? ''}');
                continue;
              }
              ids.add(id);
              // 親が指定されていればその場で繋ぐ。 parentIndex はこの呼び出しの
              // 中で先に作ったノードの番号 (0 始まり)。
              var parent = '${m['parentId'] ?? ''}'.trim();
              final pi = (m['parentIndex'] as num?)?.toInt();
              if (parent.isEmpty &&
                  pi != null &&
                  pi >= 0 &&
                  pi < ids.length - 1) {
                parent = ids[pi];
              }
              if (parent.isNotEmpty) {
                _provider.mcpConnectNodes(pageId, parent, id);
              }
            }
            if (ids.isEmpty) return _err('page not found');
            // id と題名を組で返す (= 続けて connect_nodes を呼ぶ時に、
            //   どの id がどのノードか迷わないように)。
            return _ok({
              'nodes': _provider.mcpNodeIndex(pageId).where(
                  (e) => ids.contains(e['id'])).toList(),
              'nodeIds': ids,
              if (failed.isNotEmpty) 'failed': failed,
            });
          }
          final id = _provider.mcpAddNode(
            pageId,
            title: a['title'] as String? ?? '',
            x: numOf('x'),
            y: numOf('y'),
            memo: a['memo'] as String?,
            url: a['url'] as String?,
            colorValue: (a['color'] as num?)?.toInt(),
          );
          return id == null ? _err('page not found') : _ok({'nodeId': id});
        }
      case 'update_node':
        {
          // id でも題名でもよい (= ユーザー報告: AI が id の書き写しを誤る)。
          final pageId = a['pageId'] as String? ?? '';
          final key = '${a['node'] ?? a['nodeId'] ?? ''}'.trim();
          final ok = _provider.mcpUpdateNode(
            pageId,
            key,
            title: a['title'] as String?,
            memo: a['memo'] as String?,
            x: numOf('x'),
            y: numOf('y'),
          );
          return ok
              ? _ok('updated')
              : _err('no node "$key" on that page. Available nodes (use the '
                  '"title" value as "node"): '
                  '${jsonEncode(_provider.mcpNodeIndex(pageId))}');
        }
      case 'delete_node':
        {
          final pageId = a['pageId'] as String? ?? '';
          // まとめて消せる形も持たせる (= 1 件ずつだと AI が取りこぼす)。
          final batch = a['nodes'];
          if (batch is List && batch.isNotEmpty) {
            var done = 0;
            final missed = <String>[];
            for (final e in batch) {
              final k = '${e ?? ''}'.trim();
              if (_provider.mcpDeleteNode(pageId, k)) {
                done++;
              } else {
                missed.add(k);
              }
            }
            return done == 0
                ? _err('none of $missed were found. Available nodes: '
                    '${jsonEncode(_provider.mcpNodeIndex(pageId))}')
                : _ok({
                    'deleted': done,
                    if (missed.isNotEmpty) 'failed': missed,
                  });
          }
          final key = '${a['node'] ?? a['nodeId'] ?? ''}'.trim();
          final ok = _provider.mcpDeleteNode(pageId, key);
          return ok
              ? _ok('deleted')
              : _err('no node "$key" on that page. Available nodes (use the '
                  '"title" value as "node"): '
                  '${jsonEncode(_provider.mcpNodeIndex(pageId))}');
        }
      case 'generate_page_background':
        {
          try {
            final path = await _provider.mcpGeneratePageBackground(
              a['pageId'] as String? ?? '',
              a['prompt'] as String? ?? '',
              opacityPercent: (a['opacityPercent'] as num?)?.toInt(),
              fit: a['fit'] as String?,
            );
            return _ok({'background': path});
          } catch (e) {
            return _err('$e');
          }
        }
      case 'set_page_background':
        {
          final ok = await _provider.mcpSetPageBackground(
            a['pageId'] as String? ?? '',
            template: a['template'] as String?,
            imagePath: a['imagePath'] as String?,
            clear: a['clear'] == true,
            opacityPercent: (a['opacityPercent'] as num?)?.toInt(),
            fit: a['fit'] as String?,
            hueDegrees: (a['hueDegrees'] as num?)?.toInt(),
            saturationPercent: (a['saturationPercent'] as num?)?.toInt(),
            brightnessPercent: (a['brightnessPercent'] as num?)?.toInt(),
          );
          return ok
              ? _ok('background updated')
              : _err('page not found, or no valid background was given '
                  '(use template / imagePath / clear)');
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

          // まとめて繋げる形 (= 取りこぼし対策)。
          final batch = a['connections'];
          if (batch is List && batch.isNotEmpty) {
            var done = 0;
            final missed = <String>[];
            for (final e in batch) {
              if (e is! Map) continue;
              final m = e.cast<String, dynamic>();
              final f = key(m, 'from', 'fromId');
              final t = key(m, 'to', 'toId');
              if (_provider.mcpConnectNodes(pageId, f, t,
                  label: m['label'] as String?)) {
                done++;
              } else {
                missed.add('$f -> $t');
              }
            }
            if (done == 0) {
              // 「見つからない」 だけでは AI が直しようがないので、 その
              //   ページに在るノードの id と題名を返して選び直させる。
              return _err('could not connect ${missed.join(', ')}. '
                  'Available nodes on this page (use the "title" value as '
                  '"from"/"to"): ${jsonEncode(_provider.mcpNodeIndex(pageId))}');
            }
            return _ok({
              'connected': done,
              if (missed.isNotEmpty) 'failed': missed,
            });
          }
          final f = key(a, 'from', 'fromId');
          final t = key(a, 'to', 'toId');
          final ok = _provider.mcpConnectNodes(pageId, f, t,
              label: a['label'] as String?);
          return ok
              ? _ok('connected')
              : _err('could not connect "$f" -> "$t". '
                  'Available nodes on this page (use the "title" value as '
                  '"from"/"to"): ${jsonEncode(_provider.mcpNodeIndex(pageId))}');
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
          );
          if (id == null) return _err('page not found or rows empty: $pageId');
          // 見出しを付けたい場合は、 表の上に説明書きとして載せる。
          final title = (a['title'] as String? ?? '').trim();
          if (title.isNotEmpty) _provider.updateNodeCaption(id, title);
          return _ok({'nodeId': id, 'rows': rows.length});
        }
      case 'add_image_node':
        final pageId = a['pageId'] as String? ?? '';
        String? path = a['imagePath'] as String?;
        final b64 = a['imageBase64'] as String?;
        if (path == null && b64 != null && b64.isNotEmpty) {
          // base64 をアプリ書類フォルダへ保存してから添付ノード化する。
          try {
            final bytes = base64Decode(b64);
            final docs = await getApplicationDocumentsDirectory();
            final dir = Directory('${docs.path}/mcp_images');
            await dir.create(recursive: true);
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
        if (!File(path).existsSync()) {
          return _err('image file not found: $path');
        }
        final id = _provider.mcpAddImageNode(
          pageId,
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
          if (many.isNotEmpty) {
            final ids = <String>[];
            for (final t in many) {
              final id = _provider.mcpAddGalleryItem(pageId, text: t);
              if (id != null) ids.add(id);
            }
            return ids.isEmpty
                ? _err('not a gallery page (or page not found): $pageId '
                    '- use list_pages and pick a page whose type is '
                    '"bookshelf", or create one with create_page')
                : _ok({'added': ids.length, 'titles': many});
          }
          final id = _provider.mcpAddGalleryItem(
            pageId,
            text: a['text'] as String?,
            memo: a['memo'] as String?,
            imagePath: a['imagePath'] as String?,
          );
          return id == null
              ? _err('not a gallery page (or page not found): $pageId')
              : _ok({'nodeId': id});
        }
      case 'add_paint_text':
        {
          final pageId = a['pageId'] as String? ?? '';
          final many = _stringList(a['texts']);
          final lines = many.isNotEmpty
              ? many
              : [if ((a['text'] as String? ?? '').isNotEmpty) a['text'] as String];
          var wrote = 0;
          for (final line in lines) {
            final ok = await _provider.mcpAddPaintText(
              pageId,
              line,
              // まとめ書きの時は自動で縦に積ませる。
              x: many.isNotEmpty ? null : numOf('x'),
              y: many.isNotEmpty ? null : numOf('y'),
              size: numOf('size'),
              colorValue: (a['color'] as num?)?.toInt(),
            );
            if (ok) wrote++;
          }
          return wrote > 0
              ? _ok({'written': wrote})
              : _err('not a free-note page, or text empty: $pageId '
                  '- add_paint_text only works on pages whose type is '
                  '"paint"');
        }
      case 'append_document_text':
        {
          final pageId = a['pageId'] as String? ?? '';
          final many = _stringList(a['texts']);
          final paras = many.isNotEmpty
              ? many
              : [if ((a['text'] as String? ?? '').isNotEmpty) a['text'] as String];
          var wrote = 0;
          for (final para in paras) {
            if (await _provider.mcpAppendDocumentText(pageId, para)) wrote++;
          }
          return wrote > 0
              ? _ok({'appended': wrote})
              : _err('not a note page, or text empty: $pageId '
                  '- append_document_text works on pages whose type is '
                  '"paint" (free note) or "document"');
        }
      case 'add_video_editor_item':
        {
          final pageId = a['pageId'] as String? ?? '';
          // まとめて字幕を置ける形 (= 1 件ずつだと AI が取りこぼす)。
          final batch = a['texts'];
          if (batch is List && batch.isNotEmpty) {
            final ids = <String>[];
            for (final e in batch) {
              final t = '${e ?? ''}'.trim();
              if (t.isEmpty) continue;
              final one = await _provider.mcpAddVideoEditorItem(
                pageId,
                kind: 'text',
                text: t,
                layer: (a['layer'] as num?)?.toInt() ?? 1,
                durationMs: (a['durationMs'] as num?)?.toInt(),
                fontSize: numOf('fontSize'),
                colorValue: (a['color'] as num?)?.toInt(),
              );
              if (one != null) ids.add(one);
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
            startMs: (a['startMs'] as num?)?.toInt(),
            durationMs: (a['durationMs'] as num?)?.toInt(),
            layer: (a['layer'] as num?)?.toInt(),
            fontSize: numOf('fontSize'),
            colorValue: (a['color'] as num?)?.toInt(),
          );
          return id == null
              ? _err('not a video editor page, or kind/text/path missing: '
                  '$pageId - add_video_editor_item only works on pages '
                  'whose type is "videoEditor"')
              : _ok({'itemId': id});
        }
      case 'create_document_file':
        try {
          final path = await _provider.mcpCreateFile({
            'pageId': a['pageId'] as String? ?? '',
            'kind': (a['kind'] as String? ?? '').toLowerCase(),
            'fileName': a['fileName'] as String? ?? '',
            'title': a['title'] as String? ?? '',
            'paragraphs': _stringList(a['paragraphs']),
            'rows': _rowsOf(a['rows']),
            'slides': _slidesOf(a['slides']),
          });
          return path == null
              ? _err('could not create the file (unsupported kind, or the '
                  'page was not found)')
              : _ok({'path': path});
        } catch (e, st) {
          // 理由が分からないと直せないので、 画面にもログにも残す。
          // ignore: avoid_print
          print('[MCP] create_document_file failed: $e / $st');
          return _err('file creation failed: $e');
        }
      case 'list_app_commands':
        return _ok(_provider.mcpCommands);
      case 'run_app_command':
        {
          final id = a['id'] as String? ?? '';
          final ok = _provider.mcpRunCommand(id);
          if (ok) return _ok('launched: $id');
          // ★ 「知らない id」 と「利用者しか始められない機能」 を区別する。
          //   以前はどちらも同じ文面だったため、 存在しない id を投げた時にも
          //   「利用者が押してください」 と答えてしまい、 出来るはずの事まで
          //   断るようになっていた (= ユーザー報告)。
          if (_provider.mcpIsBlockedCommand(id)) {
            return _err('"$id" is a feature only the user can start '
                '(cloud sync, and the app/focus locks). Tell the user to '
                'press the button themselves.');
          }
          return _err('unknown command id "$id". Call list_app_commands for '
              'the valid ids. Note: deleting a page is delete_page, changing '
              'a page kind is set_page_type, and putting buttons on the '
              'header is set_header_buttons - those are tools, not commands.');
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
          final r = _provider.mcpTextFileRead(
            startLine: (a['startLine'] as num?)?.toInt(),
            endLine: (a['endLine'] as num?)?.toInt(),
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
      default:
        return _err('unknown tool: $name');
    }
  }
}

class _McpMethodNotFound implements Exception {}
