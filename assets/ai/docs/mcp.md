# HisatorNotebook 実装詳細 (2) MCP サーバー / AI エージェント

## 対象ファイル

| ファイル | 役割 |
|---|---|
| `lib/services/mcp_server.dart` | サーバー本体 + ツール定義 + 実行 |
| `lib/providers/mind_map_provider.dart` | 起動/停止管理 + `mcp*` 公開 facade |
| `lib/screens/mind_map_screen.dart` | アプリ内 MCP チャット (`_McpChatDialog`) |

## 何ができるか

Claude Desktop / Claude Code のような外部の MCP クライアント、またはアプリ内蔵の
AI チャットから、ページ・ノード・背景・ファイル・アプリ機能を操作できる。
変更は既存の保存経路 (`_saveToStorage`) に乗るので、起動中の画面に即座に反映され、
そのまま永続化される。

---

## 【1】全体像 — 2 つの入口が同じ実行部を共有する

```mermaid
flowchart TD
    A["外部の MCP クライアント<br/>(Claude Code など)"]
    B["アプリ内 MCP チャット<br/>(_McpChatDialog)"]
    A -->|"HTTP POST /mcp<br/>(JSON-RPC 2.0)"| C["McpServer._handle → _dispatch"]
    B -->|"直接 Dart 呼び出し<br/>(HTTP を通さない)"| D["McpServer.callTool"]
    C --> E["McpServer.callTool(name, args)"]
    D --> E
    E --> F["MindMapProvider の mcp* facade"]
    F --> G["既存のモデル操作 + _saveToStorage"]
    G --> H["notifyListeners() → 画面が即更新"]
```

> ★ アプリ内チャットは HTTP を経由しない。だから MCP サーバーを立てなくても
> (外部公開を許可しなくても) 普通に動く。

---

## 【2】サーバーの起動フロー

```mermaid
flowchart TD
    A["アプリ起動<br/>MindMapProvider ctor → _loadMcpServerSetting()"] --> B{"デスクトップ?<br/>(Win / macOS / Linux)"}
    B -->|いいえ| Z["何もせず終了"]
    B -->|はい| C["prefs から読む<br/>mcp_external_allowed (既定 false)<br/>mcp_server_enabled"]
    C --> D{"mcp_server_enabled?"}
    D -->|false| Z
    D -->|true| E["setMcpServerEnabled(true, persist:false)<br/>→ _startMcpListener()"]
    E --> F{"_mcpExternalAllowed?"}
    F -->|false| G["null を返し待ち受けを立てない<br/>(アプリ内チャットだけの既定状態)"]
    F -->|true| H["McpServer.start(token: UUIDv4 の 32 文字)"]
    H --> I["ポート 8765〜8774 を順に bind"]
    I -->|"SocketException"| I
    I -->|成功| J["url = http://127.0.0.1:PORT/mcp?token=TOKEN"]
    J --> K["listen(_handle) 開始 → ⋮メニューに URL 表示"]
```

登録例:

```bash
claude mcp add --transport http kamispec "<URL>"
```

> - ★ 待ち受けは **127.0.0.1 のみ**。LAN には一切公開しない。
> - ★ 合言葉 (token) は起動のたびに作り直す。前回の URL は再起動後には通らない。

---

## 【3】リクエスト処理 (`McpServer._handle`)

```mermaid
flowchart TD
    A["HTTP リクエスト到着"] --> B{"パスが /mcp?"}
    B -->|違う| B1["404"]
    B -->|はい| C{"_authorized(req)"}
    C -->|"token 無し運用"| D
    C -->|"?token= 一致"| D
    C -->|"Bearer 一致"| D
    C -->|不一致| C1["401 unauthorized"]
    D{"HTTP メソッド"}
    D -->|GET| D1["405 (SSE は提供しない)"]
    D -->|DELETE| D2["200 (セッション終了を受理)"]
    D -->|"POST 以外"| D3["405"]
    D -->|POST| E["本文を UTF-8 で読み jsonDecode"]
    E -->|"Map でない"| E1["400"]
    E --> F{"msg['id'] が null?"}
    F -->|"はい (notification)"| F1["202 Accepted<br/>(応答本体なし)"]
    F -->|いいえ| G["_dispatch(method, params)"]
    G -->|成功| G1["{jsonrpc, id, result}"]
    G -->|"_McpMethodNotFound"| G2["error -32601"]
    G -->|その他例外| G3["error -32603"]
    G1 --> H["Content-Type: application/json; charset=utf-8 で返す"]
    G2 --> H
    G3 --> H
```

> ※ トランスポートは Streamable HTTP の最小実装。SSE ストリームは持たず、
> 各リクエストに JSON で即応答する。

---

## 【4】`_dispatch` が扱う JSON-RPC メソッド

| メソッド | 戻り値 |
|---|---|
| `initialize` | `{protocolVersion: 相手の版 (既定 '2025-06-18'), capabilities: {tools:{listChanged:false}}, serverInfo: {name:'kamispec-mcp', version:'1.0.0'}}` |
| `ping` | `{}` |
| `tools/list` | `{tools: McpServer.toolDefs}` (static。アプリ内チャットとも共有) |
| `tools/call` | `callTool(params.name, params.arguments)` (【6】) |
| それ以外 | `_McpMethodNotFound` を投げる |

---

## 【5】ツール定義 (`McpServer.toolDefs`) 一覧

`_tool(name, description, properties, required)` で
`{name, description, inputSchema:{type:'object', properties, required}}` を組み立てる。

### 読み取り / ページ

| ツール | 説明 |
|---|---|
| `list_pages` | 全ページ (id, name, type, ノード数, `isCurrent`, `lastModified`)<br/>★ `isCurrent: true` が利用者の見ているページ。「このページ」は必ずこれ 1 枚<br/>★ `lastModified` は**最終更新**で作成日ではない (同名ページの「古いほう」は決められない) |
| `read_page` | 1 ページを完全な JSON で (nodes / connections / decorations) |
| `create_page` | 新規ページ。type = `normal` / `bookshelf` / `paint` / `document` / `markdown` / `videoEditor`<br/>戻り値 `{pageId, type}` の `type` が実際に出来た種類 (知らない type は `normal` に倒れる) |
| `delete_page` | ページを完全に削除。最後の 1 枚は消せない<br/>★ 短い間に 2 枚を超えて消そうとすると拒否される (暴走の歯止め。【8】参照)<br/>★ 戻す道具は無い。アプリ側の Ctrl+Z (`undoLastDeletedPage`) で**直前の 1 枚だけ**復元できる |
| `set_page_type` | 中身を残したまま種類を変える (`create_page` と同じ 6 種類)<br/>★ `markdown` ページの本文を書けるツールは無い (作る・変えるだけ)。中身まで欲しい時は `create_document_file` の `md` |
| `set_header_buttons` | ヘッダーにボタンを並べる。`replace: true` で総入れ替え<br/>戻り値 `{header, ignored, blocked}`。`ignored` = 存在しない id、`blocked` = 利用者しか使えない機能 (どちらも置かれていない) |
| `clear_chat_history` | AI アシスタントの会話履歴を消す (実行中の依頼は残る)。全消去のみで部分削除は不可 |
| `tidy_page` | マインドマップを自動整列で並べ直す (`mcpTidyPage`)。normal ページ限定・Ctrl+Z で戻せる |

> ★ **戻り値で確かめる道具**: `read_page` は先頭に `nodeCount` / `connectionCount` を返す。
> `add_node` は `nodeIds` / `unlinked` / `note` (重なっているので tidy_page を呼べ)、
> `update_node` は書き換えた `nodeId` と `title`、`connect_nodes` は `fromId` / `toId`、
> `delete_node` は**消した題名**、`set_page_background` は実際に入った値を返す。
> 頼んだ値ではなく、返ってきた値を報告する。

> ★ **題名で指せるが、あいまい一致はしない**: 消す (`delete_node`) と
> 書き換える (`update_node`) は id か**完全一致の題名**のみ (大小文字と空白は無視)。
> 部分一致で近い別ノードを巻き込む事故があったため。線を引く `connect_nodes` だけは
> 従来どおり部分一致も使う。

> ★ **`add_image_node` にだけ一括形が無い**。画像は 1 枚ずつ呼ぶ。

> ★ **動画のタイムラインは追加専用**。置いた後を変える道具は無い。

### マインドマップ (normal)

| ツール | 説明 |
|---|---|
| `add_node` | ノード追加。**バッチ形が推奨**<br/>`nodes: [{title, memo?, url?, color?, parentIndex?, parentId?}]`<br/>`parentIndex` は同じ配列内の先に作ったノードの 0 始まり番号で、同時に接続線も引く → 中心 + 子をまとめて 1 回で作れる。座標は省略推奨 |
| `update_node` | title / memo / 位置の更新 |
| `delete_node` | ノードと接続線を削除 |
| `connect_nodes` | 接続。**バッチ形推奨** `connections: [{fromId, toId, label?}]` |
| `add_image_node` | 画像ノード。`imageBase64`+`fileName` か `imagePath` |
| `add_table_node` | 表ノード。`rows` は 2 次元配列、先頭行が見出し |

### 背景

| ツール | 説明 |
|---|---|
| `generate_page_background` | AI で背景画像を描き起こして設定する (**推奨**)。`prompt` / `opacityPercent`(既定 70) / `fit`。画像 1 枚分のクレジットを消費 |
| `set_page_background` | 既存の画像・組み込みテンプレート・解除。`template` = wood / chalkboard / ocean / sakura / fireworks / castle / aurora / nightSky / galaxy / rain / nature / blueprint / midnight / sage / sunset。色調整 `hueDegrees` / `saturationPercent` / `brightnessPercent` も可 |

### マインドマップ以外のページ

| ツール | 説明 |
|---|---|
| `add_gallery_item` | ギャラリー (bookshelf) にタイル追加。`texts` で一括投入 (1 件ずつ呼ばせない) |
| `add_paint_text` | フリーノート (paint) に文字を書く。`texts` で一括。x/y 省略で上から縦に積む |
| `append_document_text` | ノート (paint / document) の末尾に段落を追記。`texts` で一括 |
| `add_video_editor_item` | 動画エディターのタイムラインに 1 項目。`kind` = text / video / image。`startMs` 省略でそのレイヤーの末尾、`durationMs` 既定 4000、`layer` 0 が最背面 |

### ファイル作成

| ツール | 説明 |
|---|---|
| `create_document_file` | 本物の文書ファイルを作って保存し、ページに貼る<br/>`kind` = xlsx / csv → `rows`<br/>docx / txt / md / pdf → `title` + `paragraphs` (pdf は `rows` も可)<br/>pptx → `slides:[{title, bullets:[…]}]`<br/>`pageId` は normal か bookshelf を渡すこと (paint / videoEditor はファイルタイルを持てない) |

### 開いているテキストファイル

| ツール | 説明 |
|---|---|
| `text_file_status` | アプリのテキストエディタで開いているファイル `{open, fileName, lineCount}` |
| `text_file_read` | 行番号付きで読む (`startLine` / `endLine` で範囲指定可) |
| `text_file_edit` | `edits` 配列で一括編集。`action` = replace / insert / delete / set_all。行番号は 1 始まり・**呼び出し前**の状態基準 (下から適用されるので前方の番号は崩れない) |

### アプリ機能の起動

| ツール | 説明 |
|---|---|
| `list_app_commands` | 起動できる機能の id + ラベル一覧 |
| `run_app_command` | id を指定して機能を開く (例: flashcards / silentCamera / calendar / qrReader) |

> ★ **バッチ引数を用意した理由**: 1 件ずつのツールしか無いと AI が途中で取りこぼす
> (4 個頼んで 1 個しか置かれない事故が実際に起きた)。

---

## 【6】`callTool` の実行フロー (代表例)

共通の戻り値:

```dart
_ok(data)  → {content:[{type:'text', text: 文字列 or jsonEncode}], isError:false}
_err(msg)  → {content:[{type:'text', text: msg}],                  isError:true}
```

### add_node (バッチ)

```mermaid
flowchart TD
    A{"args.nodes が配列で 1 件以上?"} -->|いいえ| S["単発形で 1 個だけ作る"]
    A -->|はい| B["配列を先頭から順に処理"]
    B --> C["provider.mcpAddNode(pageId, title, x?, y?, memo?, url?, colorValue?)"]
    C -->|"null (ページが無い)"| D["failed に積んで次へ"]
    C -->|成功| E["ids に追加"]
    E --> F{"親を決める"}
    F -->|"parentId 指定あり"| G["それを使う"]
    F -->|"parentIndex が 0 ≦ pi < ids.length-1"| H["ids[pi] を使う"]
    G --> I["provider.mcpConnectNodes(pageId, parent, id) でその場で接続"]
    H --> I
    I --> B
    D --> B
    B --> J{"ids が空?"}
    J -->|はい| K["_err('page not found')"]
    J -->|いいえ| L["_ok({nodeIds:[…], failed?:[…]})"]
```

### add_image_node

```mermaid
flowchart TD
    A{"imagePath がある?"} -->|はい| F
    A -->|"いいえ (imageBase64 あり)"| B["base64Decode → 書類フォルダ/mcp_images/ を作成"]
    B --> C["fileName の禁止文字を _ に置換<br/>拡張子が無ければ .png を付ける"]
    C --> D["ミリ秒_fileName で保存"]
    D --> F{"File(path).existsSync()"}
    F -->|いいえ| G["_err"]
    F -->|はい| H["provider.mcpAddImageNode(pageId, filePath, title?, x?, y?)"]
```

### generate_page_background

```mermaid
flowchart LR
    A["mcpGeneratePageBackground(pageId, prompt, opacityPercent?, fit?)"]
    A --> B["AI 画像生成<br/>(前払いクレジットから 1 枚分を消費)"]
    B --> C["保存 → 背景に設定"]
    C --> D["_ok({background: 保存パス})"]
    B -->|例外| E["_err('<e>')"]
```

### add_table_node

```mermaid
flowchart TD
    A{"rows が非空の配列?"} -->|いいえ| B["_err"]
    A -->|はい| C["2 次元配列に正規化<br/>(要素が配列でなければ 1 セルの行)"]
    C --> D["provider.mcpAddTableNode(pageId, rows, headerRow(既定true), x?, y?)"]
    D --> E{"title がある?"}
    E -->|はい| F["updateNodeCaption(id, title) で表の上に説明書き"]
    E -->|いいえ| G["_ok({nodeId, rows: 行数})"]
    F --> G
```

### run_app_command

`provider.mcpRunCommand(id)` を呼ぶ。失敗時のメッセージが親切になっている:

- 「id が違う (`list_app_commands` を見よ)」
- 「利用者本人しか始められない機能 (LAN 共有・クラウド同期・アプリロック/集中ロック)
  なので、ユーザーにボタンを押すよう伝えよ」

> ★ 危険な操作を AI に勝手に実行させないための線引き。

---

## 【7】アプリ内 MCP チャット (`_McpChatDialog`) のエージェントループ

```mermaid
flowchart TD
    A["ユーザーが送信"] --> B{"provider.hasActiveAiKey?"}
    B -->|false| B1["その場で AI 設定を開いて中断"]
    B -->|true| C["添付ファイル → [添付ファイル: 名前]+抽出テキストを質問に足す<br/>写真は AiInputImage として別に持つ"]
    C --> D["会話履歴に user メッセージを積む"]
    D --> E["ループ開始 (最大 24 往復)"]
    E --> F["① _systemPrompt() を組み立て"]
    F --> G["② prompt = systemPrompt + 会話履歴 + 'アシスタント:'"]
    G --> H["③ provider.askAi(prompt, images: 1 往復目だけ)"]
    H --> I["④ _parseToolCall(reply)"]
    I -->|"ツール呼び出しでない<br/>or 24 往復目"| Z["終了処理へ"]
    I -->|ツール呼び出し| J["args.pageId を _touchedPageIds に覚える"]
    J --> K["画面に「何をしているか」の行 (_toolLabel)"]
    K --> L["_tools.callTool(name, args) を直接呼ぶ<br/>← HTTP を通らない"]
    L -->|例外| M["{isError:true, text:'error: …'} を自前で作る"]
    L --> N{"create_page?"}
    M --> N
    N -->|はい| O["戻り値の pageId も _touchedPageIds に足す"]
    N -->|いいえ| P
    O --> P["画面には「完了 / 失敗」の 1 行だけ<br/>AI に渡す raw には本物の戻り値 (1200 文字で打ち切り)"]
    P --> F
    Z --> Z1["_touchedPageIds を mcpTidyPage(pid) で整列し直す"]
    Z1 --> Z2["上限で止まった場合は生 JSON でなく t('mcp.tooManySteps')"]
    Z2 --> Z3["説明文を画面と会話ログ (appendMcpChat) に記録"]
    Z3 --> Z4["refreshCreditBalance() → 「あと何トークン使えるか」を meta 行に"]
```

### `_systemPrompt()` に入るもの

- **アプリの説明書 (AGENTS.md)** — 同梱アセットから読み込む既定の前提知識
  (詳細は `read_app_doc` ツールで必要時だけ取り寄せる)
- `provider.mcpPreamble` (利用者が書き置いた前提) を最優先で先頭に
- 「あなたはマインドマップアプリを操作するアシスタントです」
- ツール定義 = `jsonEncode(McpServer.toolDefs)`
- 現在のページ一覧 = `jsonEncode(provider.mcpListPages())`
- ツールを使う時は説明文を付けず `{"tool":"名前","args":{…}}` だけ返す
- 返答は `provider.languageInstructionForAi()` の言語で、JSON や ID を並べず普通の文章で
- 座標 (x, y) は指定しない (アプリが後で並べる)
- 主題ノードは 1 つだけ、同名を重ねない
- `create_page` の戻り `pageId` をそのまま以降に使う
- 最後の説明文の前に `read_page` で実際の中身を確認し、本当に作られた物だけを説明する
- 作ったノードは必ず `connect_nodes` で親につなぐ (つながっていないノードは「根」扱いでバラバラに並ぶ)
- 比較・一覧・数値は `add_table_node` で表にする
- 背景の指示は `generate_page_background` を既定にする
- 機能を開く指示は `run_app_command`

> ★ 写真を毎回付けると同じ画像の分だけ何度も課金される (画像は入力トークンとして数えられる)。
> ★ 表示を人向けに変えても AI には本物の戻り値を渡さないと、結果が分からず同じ操作を繰り返す。
> ★ AI が決めた座標は当てにならず要素が離れて置かれるため、出来上がりを必ず整列し直す。

---

## 【8】安全のための線引き

- 待ち受けは **127.0.0.1 固定**。LAN・外部からは届かない。
- 外部接続は既定で不許可 (`mcp_external_allowed = false`)。許可を切ると即座に
  `_mcpServer.stop()` で待ち受けを畳む。
- 許可しても合言葉 (32 文字) を知らないと 401。合言葉は起動ごとに再生成。
- `run_app_command` は、利用者本人しか始めてはいけない機能
  (LAN 共有 / クラウド同期 / アプリロック / 集中ロック) を実行できない。
  `set_header_buttons` でも同じ id は置けず、戻り値の `blocked` に入る。
- **ページの消し過ぎを止める歯止め** (`mcpDeletePage`)。90 秒のあいだに
  MCP から消せるのは 2 枚まで。3 枚目からは「頼まれた以上に消している」
  として拒否し、利用者に確認するよう促す。
  = 「このページ消して」の 1 件で一覧を上から順に消していった事故の再発防止。
  説明文 (`isCurrent` / 範囲の指示) だけでは事故を防ぎきれないため、
  実行側にも線を引いてある。
- **AI が消したノードは Ctrl+Z で戻せる**。`mcpDeleteNode` は
  `_pushUndoForPage(pageId, coalesceKey:…)` で履歴を積む
  (`_pushUndo` は `currentPage` を控えるので、裏のページを触る MCP では使えない)。
  まとめ消しは 900ms の合流窓で 1 スナップショットにまとまり、Ctrl+Z 一回で全部戻る。
  = 「『テスト』が入ってるノード消して」で関係ない物まで巻き込んだ時の逃げ道。
- `mcpPageById(pageId)` は `pageId` が空文字の時「今開いているページ」にフォールバックする。
  AI が `create_page` の戻りを取り違えて空を渡し、「作成しました」とだけ言って
  何も起きない事故を防ぐため。

---

## 【9】接続の手順 (利用者向け)

```mermaid
flowchart TD
    A["⋮メニュー → MCP サーバー を ON"] --> B["「外部アプリからの接続を許可」も ON"]
    B --> C["表示された URL (合言葉付き) をコピー<br/>例: http://127.0.0.1:8765/mcp?token=xxxxxxxx"]
    C --> D["claude mcp add --transport http kamispec &quot;URL&quot;"]
    D --> E["Claude 側から tools/list が飛んでくる"]
    E --> F["「〇〇についてのマップを作って」と指示<br/>→ tools/call が飛び、アプリの画面がその場で書き換わる"]
```

> ※ アプリを再起動すると合言葉が変わるので、URL を登録し直す必要がある。
