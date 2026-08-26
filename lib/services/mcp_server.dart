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
        'before you report it.',
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
        'note), "document" (notepad), "markdown" (markdown + mermaid), '
        '"videoEditor". Use this when the user asks to convert/turn a page '
        'into another kind - the nodes stay, so never rebuild the page with '
        'delete_page + create_page. What a free note / notepad / markdown / '
        'video page holds is stored beside the page rather than inside it, so '
        'it survives a round trip too (switch the kind back and it is there '
        'again). The one exception: cloud sync only carries a free-note '
        '("paint") body, so a page converted away from "paint" does not take '
        'that drawing to another device. '
        'Converting a note page ("paint" / "document" / "markdown") to '
        '"normal" does NOT turn its text into nodes: the text is kept aside '
        'and simply stops being displayed, so the mind map looks empty. No '
        'tool can read a note body back (read_page returns nodes / '
        'connections / decorations only), so ask the user for the headings - '
        'or use text already in this conversation - and create the nodes '
        'yourself with add_node. '
        'These six are the only page kinds the app has; if the user names '
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
              'videoEditor'
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
        'exist and "blocked" are user-only features (cloud sync, app lock, '
        'focus lock) - neither was placed, so say so plainly instead of '
        'reporting them as added. This tool can only fill the HEADER; it '
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
        'append_document_text), "markdown" (markdown + mermaid) or '
        '"videoEditor" (video timeline). Returns {pageId, type}: type is what '
        'was really created. An unknown type falls back to "normal", so check '
        'the returned type before telling the user what you made.',
        {
          'type': {
            'type': 'string',
            'enum': [
              'normal',
              'bookshelf',
              'paint',
              'document',
              'markdown',
              'videoEditor'
            ]
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
        'they did not mean.',
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
        'background. This is the preferred way to change a background: '
        'describe the picture you want in "prompt" (English works best, be '
        'concrete about subject, colours and mood) and an image is generated '
        'and applied. Costs a flat ~0.047 USD of prepaid credit per picture, '
        'whatever the prompt length - one charge PER PAGE, so "give every '
        'page the same background" costs that much times the number of '
        'pages. Because it costs money, do '
        'not run it on a vague request ("make the background nice"): settle '
        'which page, what kind of picture, and whether a built-in template '
        '(free, via set_page_background) would do, then generate. '
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
        'report those numbers rather than the ones you asked for.',
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
        'once per image. An invented array argument is ignored, so passing '
        'three paths in one call would attach only one and still look like a '
        'success.',
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
        'feature you are not sure about. The list is the whole truth: cloud '
        'sync, the app lock and the focus lock are deliberately missing '
        'because only the user may start them, and anything else not in the '
        'list simply does not exist.',
        {}),
    _tool(
        'run_app_command',
        'Launch one app feature by its id (see list_app_commands). Example '
        'ids: "flashcards" (flash cards), "silentCamera" (silent camera), '
        '"calendar", "qrReader". The feature opens on screen for the user. '
        'Just run it when asked - do not ask for confirmation first. '
        'This only OPENS features; it never edits data: deleting a page is '
        'delete_page, changing a page kind is set_page_type, and header '
        'buttons are set_header_buttons.',
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
        'Check the text file currently open in the app text editor. '
        'Returns {open, fileName, lineCount}. The other text_file_* tools '
        'work on this file. If "open" is false, no text editor is open - '
        'ask the user to open a text file first.',
        {}),
    _tool(
        'text_file_read',
        'Read the text file currently open in the app text editor as '
        'numbered lines. Optionally pass startLine/endLine (1-based, '
        'inclusive) to read only part of a long file. Out-of-range or reversed '
        'values are clamped to the file, so check the returned lineCount / '
        'startLine / endLine (and "note") before quoting the result, and '
        'tell the user when the lines they asked for do not exist.',
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

  /// ツール実行 (HTTP 経由と、 アプリ内 AI チャット [MCP チャット] の両方
  /// から呼ばれる)。
  Future<Map<String, dynamic>> callTool(
      String name, Map<String, dynamic> a) async {
    double? numOf(String key) => (a[key] as num?)?.toDouble();
    switch (name) {
      case 'list_pages':
        return _ok(_provider.mcpListPages());
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
              'normal, bookshelf, paint, document, markdown, videoEditor. If '
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
        final id = _provider.mcpCreatePage(
            type: a['type'] as String? ?? 'normal',
            name: a['name'] as String?);
        // 実際に出来た種類を返す (= ユーザー報告: 知らない種類を頼まれると
        //   黙って normal を作り、 頼まれた通りに作ったと答えてしまう)。
        return id == null
            ? _err('could not create a "${a['type'] ?? 'normal'}" page: a '
                'free note ("paint") page needs Pro, and the free plan caps '
                'how many pages of each kind there can be. Tell the user - '
                'do not retry with a different type.')
            : _ok({
                'pageId': id,
                'type': _provider.mcpPageById(id)?.pageType ?? 'normal',
              });
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
          final batch = a['nodes'];
          // ★ 空配列で呼ばれた時に何も作らない (= 動作確認で判明: 「0 個
          //   追加して」 で空配列を投げると 1 件用の道に落ちて、 無題の
          //   ノードが 1 個出来たうえに成功として返っていた)。
          if (batch is List && batch.isEmpty) {
            return _err('"nodes" was an empty array - nothing was added. '
                'If there is nothing to add, do not call add_node at all.');
          }
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
              if (!m.containsKey('title') &&
                  !m.containsKey('memo') &&
                  !m.containsKey('url')) {
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
              final pi = _numOf(m['parentIndex'])?.toInt();
              if (parent.isEmpty && pi != null) {
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
            // 座標を渡さないと全部同じ場所に重なる。 アプリ内の AI は最後に
            //   自動で並べ直すが、 外部の MCP クライアントは自分で
            //   tidy_page を呼ばないと重なったまま (= 動作確認で判明)。
            final placed =
                batch.any((e) => e is Map && (e['x'] != null || e['y'] != null));
            return _ok({
              // id と題名を組で返す (= 続けて connect_nodes を呼ぶ時に、
              //   どの id がどのノードか迷わないように)。
              'nodes': _provider.mcpNodeIndex(pageId).where(
                  (e) => ids.contains(e['id'])).toList(),
              'nodeIds': ids,
              if (failed.isNotEmpty) 'failed': failed,
              if (unlinked.isNotEmpty) 'unlinked': unlinked,
              if (!placed && ids.length > 1)
                'note': 'all ${ids.length} nodes were placed on the same spot; '
                    'call tidy_page on this pageId to lay them out.',
            });
          }
          // 題名も memo も url も無い呼び出しでは何も作らない。
          if (!a.containsKey('title') &&
              !a.containsKey('memo') &&
              !a.containsKey('url')) {
            return _err('nothing to add: pass "nodes" (an array) or at least '
                'a "title". No node was created.');
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
          // まとめて消せる形も持たせる (= 1 件ずつだと AI が取りこぼす)。
          final batch = a['nodes'];
          if (batch is List && batch.isNotEmpty) {
            // 何を消したかを題名で返す (= 数だけだと、 頼まれた物と違う
            //   ノードが消えていても AI が気付けない)。
            final removed = <String>[];
            final missed = <String>[];
            for (final e in batch) {
              final k = '${e ?? ''}'.trim();
              final title = _provider.mcpDeleteNode(pageId, k);
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
                  });
          }
          final key = '${a['node'] ?? a['nodeId'] ?? ''}'.trim();
          final removedTitle = _provider.mcpDeleteNode(pageId, key);
          return removedTitle != null
              ? _ok({'deleted': removedTitle})
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
          final bgPageId = a['pageId'] as String? ?? '';
          // ★ 無いファイルを渡された時に、 まとめ書きの文面 (「ページが
          //   見つからない…」) が返って原因を取り違えていた
          //   (= 動作確認で判明)。 clear / template が先に効くので、
          //   それらが無い時だけ実在を見る (provider と同じ優先順位)。
          if (_provider.mcpPageById(bgPageId) == null) {
            return _err('no page has the id "$bgPageId" - call list_pages.');
          }
          final bgTpl = (a['template'] as String? ?? '').trim();
          final bgImg = (a['imagePath'] as String? ?? '').trim();
          if (a['clear'] != true &&
              bgTpl.isEmpty &&
              bgImg.isNotEmpty &&
              !File(bgImg).existsSync()) {
            return _err('background image file not found: $bgImg');
          }
          final ok = await _provider.mcpSetPageBackground(
            bgPageId,
            template: a['template'] as String?,
            imagePath: a['imagePath'] as String?,
            clear: a['clear'] == true,
            opacityPercent: (a['opacityPercent'] as num?)?.toInt(),
            fit: a['fit'] as String?,
            hueDegrees: (a['hueDegrees'] as num?)?.toInt(),
            saturationPercent: (a['saturationPercent'] as num?)?.toInt(),
            brightnessPercent: (a['brightnessPercent'] as num?)?.toInt(),
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
            if (bgPage != null) ...{
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
              // 実際に繋いだ id を返す (= 同じ題名のノードが 2 つある時に、
              //   思った方に繋がったか AI が確かめられるように)。
              ? _ok({
                  'connected': 1,
                  'fromId': _provider.mcpResolveNodeId(pageId, f),
                  'toId': _provider.mcpResolveNodeId(pageId, t),
                })
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
      case 'append_document_text':
        {
          final pageId = a['pageId'] as String? ?? '';
          final many = _stringList(a['texts']);
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
                  '"paint" (free note) or "document" (notepad). A "markdown" '
                  'page body cannot be written by any tool: create the text '
                  'as a .md file with create_document_file instead.');
        }
      case 'add_video_editor_item':
        {
          final pageId = a['pageId'] as String? ?? '';
          // ★ 1.5 秒のつもりで 1.5 を渡されると、 黙って 1 ミリ秒に切り捨てて
          //   成功と返していた (= 動作確認で判明)。 単位の取り違えは丸めずに
          //   突き返す。
          for (final k in const ['durationMs', 'startMs']) {
            final v = a[k] as num?;
            if (v == null) continue;
            if (v % 1 != 0 || (k == 'durationMs' && v <= 0)) {
              return _err('$k must be a whole number of MILLISECONDS '
                  '(1.5 seconds = 1500, not 1.5)');
            }
          }
          // レーンは 6 本しか無い。 範囲外は丸めずに突き返す (単位と同じ
          //   考え方。 丸めると戻り値で伝えられない)。
          final lay = a['layer'] as num?;
          if (lay != null && (lay % 1 != 0 || lay < 0 || lay > 5)) {
            return _err('layer must be a whole number from 0 to 5 '
                '(0 = back-most); the timeline has only 6 lanes.');
          }
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
          final kind = (a['kind'] as String? ?? '').toLowerCase();
          final slides = _slidesOf(a['slides']);
          // ★ 中身の無い pptx を黙って作らない (= 動作確認で判明: slides を
          //   読めない形で渡すと、 表紙だけの空スライドが出来て成功が返る)。
          if (kind == 'pptx' && slides.isEmpty) {
            return _err('pptx needs "slides": '
                '[{"title":"…","bullets":["…"]}] - nothing was created.');
          }
          final reqId = a['pageId'] as String? ?? '';
          final path = await _provider.mcpCreateFile({
            'pageId': reqId,
            'kind': kind,
            'fileName': a['fileName'] as String? ?? '',
            'title': a['title'] as String? ?? '',
            'paragraphs': _stringList(a['paragraphs']),
            'rows': _rowsOf(a['rows']),
            'slides': slides,
          });
          if (path == null) {
            return _err('could not create the file (unsupported kind, or the '
                'page was not found)');
          }
          // ★ 貼れたかどうかを見て返す (= 動作確認で判明: フリーノートの
          //   ページを渡すとタイルを置く場所が無く、 ファイルはどこにも
          //   貼られないのに成功と返っていた。 別のページへ逃げる事もある)。
          final reqPage = _provider.mcpPageById(reqId);
          bool holds(dynamic p) =>
              p != null && p.nodes.values.any((n) => n.attachmentPath == path);
          if (holds(reqPage)) {
            return _ok({'path': path, 'attachedToPageId': reqPage!.id});
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
      // ── ページ / フォルダーの整理 ──
      case 'rename_page':
        {
          final renamed = <Map<String, String>>[];
          final failed = <String>[];
          void one(String pageId, String nm) {
            if (_provider.mcpRenamePage(pageId, nm)) {
              renamed.add({'pageId': pageId, 'name': nm.trim()});
            } else {
              failed.add(pageId.isEmpty ? '(blank id)' : pageId);
            }
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
          if (renamed.isEmpty) {
            return _err('could not rename ${failed.join(', ')} '
                '(unknown page id, or a blank name). Pages: '
                '${jsonEncode(_provider.mcpListPages())}');
          }
          return _ok({
            'renamed': renamed,
            if (failed.isNotEmpty) 'failed': failed,
          });
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
              : _err('no folder "$fid" (or a blank name). Folders: '
                  '${jsonEncode(_provider.mcpListFolders())}');
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
          final list =
              ids.isNotEmpty ? ids : [('${a['pageId'] ?? ''}').trim()];
          var moved = 0;
          final failed = <String>[];
          for (final pid in list) {
            if (pid.isEmpty) continue;
            if (_provider.mcpMovePageToFolder(pid, target)) {
              moved++;
            } else {
              failed.add(pid);
            }
          }
          if (moved == 0) {
            return _err('could not move ${failed.join(', ')} '
                '(unknown page or folder id). Pages: '
                '${jsonEncode(_provider.mcpListPages())} Folders: '
                '${jsonEncode(_provider.mcpListFolders())}');
          }
          return _ok({
            'moved': moved,
            'folderId': target,
            if (failed.isNotEmpty) 'failed': failed,
          });
        }
      // ── 線だけを消す ──
      case 'disconnect_nodes':
        {
          final pageId = a['pageId'] as String? ?? '';
          String key(Map<String, dynamic> m, String a1, String a2) {
            final v1 = '${m[a1] ?? ''}'.trim();
            return v1.isNotEmpty ? v1 : '${m[a2] ?? ''}'.trim();
          }

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
            if (_provider.mcpDisconnectNodes(pageId, p[0], p[1])) {
              done++;
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
          String? addOne(Map<String, dynamic> m) => _provider.mcpAddDecoration(
                pageId,
                kind: '${m['kind'] ?? 'rectangle'}',
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
                layer: (m['layer'] as num?)?.toInt(),
              );

          final batch = a['shapes'];
          final made = <String>[];
          final failed = <String>[];
          if (batch is List && batch.isNotEmpty) {
            for (final e in batch) {
              if (e is! Map) continue;
              final m = e.cast<String, dynamic>();
              final id = addOne(m);
              if (id != null) {
                made.add(id);
              } else {
                failed.add('${m['kind'] ?? '?'}');
              }
            }
          } else {
            final id = addOne(a);
            if (id != null) {
              made.add(id);
            } else {
              failed.add('${a['kind'] ?? '?'}');
            }
          }
          if (made.isEmpty) {
            return _err('could not add ${failed.join(', ')} - the page was '
                'not found, or that shape name does not exist (see the "kind" '
                'list; "polyline" is not available here).');
          }
          return _ok({
            'added': made.length,
            'decorationIds': made,
            if (failed.isNotEmpty) 'failed': failed,
          });
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
          final r = await _provider.mcpReadDeviceFile(
            '${a['path'] ?? ''}',
            reason: '${a['reason'] ?? ''}',
            maxChars: (a['maxChars'] as num?)?.toInt() ?? 12000,
          );
          final err = r['error'];
          return err == null ? _ok(r) : _err('$err');
        }
      case 'pick_user_file':
        {
          final r = await _provider.mcpPickAndReadFile(
            reason: '${a['reason'] ?? ''}',
            maxChars: (a['maxChars'] as num?)?.toInt() ?? 12000,
          );
          final err = r['error'];
          return err == null ? _ok(r) : _err('$err');
        }
      // ── Web ──
      case 'web_search':
        {
          final q = '${a['query'] ?? ''}'.trim();
          if (q.isEmpty) return _err('query is required');
          final hits = await _provider.mcpWebSearch(q,
              limit: (a['limit'] as num?)?.toInt() ?? 8);
          if (hits.isEmpty) {
            return _err('no results for "$q". Try different words, or ask '
                'the user for a url.');
          }
          return _ok({'query': q, 'results': hits});
        }
      case 'web_fetch':
        {
          final r = await _provider.mcpWebFetch(
            '${a['url'] ?? ''}',
            maxChars: (a['maxChars'] as num?)?.toInt() ?? 8000,
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
