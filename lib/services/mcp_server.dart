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
        'tidied into a tree afterwards. Returns nodeIds in the same order.',
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
        'Update a node title / memo / position.',
        {
          'pageId': {'type': 'string'},
          'nodeId': {'type': 'string'},
          'title': {'type': 'string'},
          'memo': {'type': 'string'},
          'x': {'type': 'number'},
          'y': {'type': 'number'},
        },
        ['pageId', 'nodeId']),
    _tool(
        'delete_node',
        'Delete a node (and its connections) from a page.',
        {
          'pageId': {'type': 'string'},
          'nodeId': {'type': 'string'},
        },
        ['pageId', 'nodeId']),
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
        '"connections" as an array of {fromId, toId, label?} to make every '
        'link in ONE call.',
        {
          'pageId': {'type': 'string'},
          'connections': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'fromId': {'type': 'string'},
                'toId': {'type': 'string'},
                'label': {'type': 'string'},
              },
            },
          },
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
        'Add one item to the timeline of a VIDEO EDITOR page (pageType '
        '"videoEditor"). kind: "text" (caption; requires text), "video" or '
        '"image" (requires an absolute local path). startMs defaults to the '
        'end of that layer, durationMs defaults to 4000. layer 0 is the '
        'back-most; captions usually go on layer 1. Returns itemId.',
        {
          'pageId': {'type': 'string'},
          'kind': {'type': 'string', 'enum': ['text', 'video', 'image']},
          'text': {'type': 'string'},
          'path': {'type': 'string'},
          'startMs': {'type': 'integer'},
          'durationMs': {'type': 'integer'},
          'layer': {'type': 'integer'},
          'fontSize': {'type': 'number'},
          'color': {'type': 'integer'},
        },
        ['pageId', 'kind']),
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
            return _ok({
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
        final ok = _provider.mcpUpdateNode(
          a['pageId'] as String? ?? '',
          a['nodeId'] as String? ?? '',
          title: a['title'] as String?,
          memo: a['memo'] as String?,
          x: numOf('x'),
          y: numOf('y'),
        );
        return ok ? _ok('updated') : _err('page or node not found');
      case 'delete_node':
        final ok = _provider.mcpDeleteNode(
            a['pageId'] as String? ?? '', a['nodeId'] as String? ?? '');
        return ok ? _ok('deleted') : _err('page or node not found');
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
          // まとめて繋げる形 (= 取りこぼし対策)。
          final batch = a['connections'];
          if (batch is List && batch.isNotEmpty) {
            var done = 0;
            for (final e in batch) {
              if (e is! Map) continue;
              final m = e.cast<String, dynamic>();
              if (_provider.mcpConnectNodes(
                pageId,
                '${m['fromId'] ?? ''}',
                '${m['toId'] ?? ''}',
                label: m['label'] as String?,
              )) {
                done++;
              }
            }
            return done == 0
                ? _err('page or node not found')
                : _ok({'connected': done});
          }
          final ok = _provider.mcpConnectNodes(
            pageId,
            a['fromId'] as String? ?? '',
            a['toId'] as String? ?? '',
            label: a['label'] as String?,
          );
          return ok ? _ok('connected') : _err('page or node not found');
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
          return ok
              ? _ok('launched: $id')
              : _err('cannot launch "$id". Either the id is wrong (call '
                  'list_app_commands for valid ids), or it is a feature '
                  'that only the user may start themselves (sharing over '
                  'the local network, cloud sync, and the app/focus locks). '
                  'For those, tell the user to press the button.');
        }
      default:
        return _err('unknown tool: $name');
    }
  }
}

class _McpMethodNotFound implements Exception {}
