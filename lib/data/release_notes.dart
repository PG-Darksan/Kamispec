// ─── 更新内容 (リリースノート) ────────────────────────────────────────
//
// = ユーザー要望「アプリが新バージョンになる度に 1 度のみ起動時に
//   リリースノートが出るようにして欲しい」。
//
// ★ ここが**版の正**。 一番上の `build` が今の版で、 画面はこれと
//   prefs の `release_notes_seen_build` を比べて出すかどうかを決める
//   (`mind_map_screen.dart` の `_maybeShowReleaseNotes`)。
//   package_info_plus のような追加の部品は入れていない
//   (Windows の CMake まで触る事になるので、 定数 1 つで済ませる)。
//
// ★ **版を上げたらここに 1 件足す**。 `pubspec.yaml` の `version:` の
//   `+` の後ろと同じ数を `build` に入れる事。 足し忘れると、 その版では
//   何も出ない (壊れはしないが、 更新内容が伝わらない)。
//
// ★ 文は**表示の言語ごと**に持てる (= ユーザー要望「更新内容の所は多言語
//   対応するようにして欲しい」)。 `lines` の鍵は `appLanguage` と同じ
//   言語コード。 無い言語は `t()` と**同じ落とし方** (その言語 → 'en' →
//   'ja') にしてあるので、 全部を埋める必要は無い。 埋めておきたいのは
//   訳が揃っている 9 言語 (ja/en/zh/ko/es/fr/de/pt/ru)。 残り 21 言語は
//   英語が出る (アプリの他の文言と同じ扱い)。
//
// ★ 利用者に見せる文なので、 開発の言葉ではなく**何ができるようになったか**
//   で書く事。

class ReleaseNote {
  const ReleaseNote({
    required this.build,
    required this.date,
    required this.lines,
  });

  /// `pubspec.yaml` の `version: 1.0.0+<build>` と同じ数。
  final int build;

  /// 出した日 (`yyyy-MM-dd`)。 見出しに出すだけ。
  final String date;

  /// 言語コード → その言語で読む行。
  final Map<String, List<String>> lines;

  /// その言語で読む行。 無ければ en → ja の順に落とす (`t()` と同じ)。
  List<String> linesFor(String lang) =>
      lines[lang] ?? lines['en'] ?? lines['ja'] ?? const <String>[];
}

/// 画面に出す版の名前 (`pubspec.yaml` の `version:` の `+` の前)。
const String kAppVersionName = '1.0.0';

/// **新しい順**に並べる (先頭が今の版)。
const List<ReleaseNote> kReleaseNotes = <ReleaseNote>[
  ReleaseNote(
    build: 438,
    date: '2026-09-25',
    lines: <String, List<String>>{
      'ja': [
        'ターミナルがセキュリティソフトに止められてアプリごと落ちる事が'
            'あったのを直しました。開く時に余計なシェルを挟まないようにし、'
            '失敗した時の後始末も入れてあります。',
        '同じアカウントのままでも、CLI のタブを何枚でも開けるようにしました。'
            '新規タブから同じアカウントを選んでも、別の会話が始まります。',
        'CLI の更新が終わると、自動で探し直して新しいセッションを開くように'
            'なりました。端末に出た URL もクリックで開けます。',
        'ターミナルで使えるシェルの一覧に PowerShell 7 が出ないことが'
            'あったのを直しました。',
        'txt やマークダウンの編集画面のターミナルを、VS Code のように'
            '画面の下に開くようにしました。上の縁を掴むと高さを変えられます。',
        'マークダウンのページを、最後に読んでいた所から開くようにしました'
            '(タブごとに覚えます)。',
        'マークダウンの AI 欄を整理しました。見出しを「本文を書き出す」'
            '「チャット」に改め、上下の境界を動かせるようにし、'
            'ページを開くたびに勝手に出てくるのをやめました。',
        'マークダウンのチャット欄で改行できるようにし、モデルと推論の'
            '深さを選べるようにしました。過去のやり取りは上下キーで'
            '呼び出せます。',
        'マークダウンに本文の読み上げを付けました。',
        'CLI にマークダウンを頼んだ時、改行が「\\n」の文字のまま入って'
            '1 行の長文になっていたのを直しました。長い資料は自動で'
            '複数のタブに分かれます。',
        'フリーノートに AI で資料を作らせた時、文字が重なって崩れていたのを'
            '直しました。用紙の幅で折り返し、入り切らない分は次のタブへ'
            '続きます。崩れた下書きのタブも残りません。',
        'ページ一覧のメニューから、そのページのファイルの場所を'
            'エクスプローラーで開けるようにしました。',
        'ヘッダーを隠すと、ページ名の行やボタンの帯まで隠れるように'
            'しました。Esc か画面上端の中央にカーソルを持っていくと'
            '戻すボタンが出ます。',
        'ごみ箱の期限を 1 週間にしました。日数は自由に変えられ、'
            'ごみ箱を使わずそのまま消す設定も選べます。',
        'pptx や docx などを開いている時も Ctrl+Shift+E でページ一覧が'
            '開くようにしました。',
        '分割画面で、格納した親ノードを境界の向こうへ渡すと子が'
            '付いてこなかったのを直しました。',
        '新しいページに、今の一覧に無い古いテンプレート背景が'
            '付いてしまうのを直しました。',
        'マークダウンの目次が途中で切れていたのを直しました'
            '(項目が多い時は段組みになります)。',
        'ギャラリーで、ブロックの外の背景を長押しするとメニューが'
            '出るようにしました。スマホのメニューに範囲選択も足しました。',
        '要素の背景色と文字色の既定を、パソコンでも右クリックで'
            '決められるようにしました。',
      ],
      'en': [
        'Fixed the terminal being blocked by security software and taking the '
            'app down with it. It no longer goes through an extra shell, and '
            'failures now clean up after themselves.',
        'You can now open as many CLI tabs as you like on the same account — '
            'picking the same account from a new tab starts a new session.',
        'After a CLI update finishes, the app re-detects it and opens a fresh '
            'session automatically. URLs printed in the terminal are clickable.',
        'Fixed PowerShell 7 sometimes missing from the shell list.',
        'The terminal for txt and markdown editors now opens as a panel at the '
            'bottom, like VS Code. Drag its top edge to resize.',
        'Markdown pages reopen where you left off, remembered per tab.',
        'Tidied the markdown AI panel: the headings are now "Write the '
            'document" and "Chat", the divider between them can be dragged, '
            'and it no longer opens by itself every time.',
        'The markdown chat box accepts line breaks, lets you pick the model '
            'and reasoning depth, and recalls past messages with the arrow keys.',
        'Markdown pages can now read the text aloud.',
        'Fixed markdown written by a CLI arriving as one long paragraph with '
            r'literal "\n" in it. Long documents are split across tabs.',
        'Fixed AI-written free-note material overlapping itself. Text now '
            'wraps to the paper and continues on the next tab when it does not '
            'fit, and no broken draft tab is left behind.',
        'The page list menu can open a page\'s file location in the file '
            'manager.',
        'Hiding the header now hides the page-name row and button bars too. '
            'Press Esc or move the pointer to the top centre to bring them back.',
        'The trash now keeps deleted pages for a week. You can change the '
            'number of days, or turn the trash off entirely.',
        'Ctrl+Shift+E opens the page list while pptx, docx and other files are '
            'open.',
        'Fixed children being left behind when a container node was dragged '
            'across the split boundary.',
        'Fixed new pages getting an old template background that is no longer '
            'in the list.',
        'Fixed the markdown table of contents being cut off (it now flows into '
            'columns when there are many entries).',
        'Long-pressing the gallery background now opens the same menu as a '
            'right-click, and mobile menus gained range select.',
        'Element background and text colours can be pinned as the default with '
            'a right-click on desktop.',
      ],
    },
  ),
  ReleaseNote(
    build: 437,
    date: '2026-09-23',
    lines: <String, List<String>>{
      'ja': [
        'Claude Code / Codex CLI の画面を、アプリの外の窓として開けるように'
            'しました。CLI の一覧の上にある「別の窓で開く」から出せます。',
        'その窓を直に開くショートカットをデスクトップに作れるようにしました。'
            'ショートカットから始めると、マップのページを立ち上げずに'
            'CLI の画面だけが出ます。',
        '集中ロックの設定を整理しました。「ロック中に使える物」を'
            '3 択 (使わない / 調べ物だけ / 全部) に、ロック画面に置く物を'
            '1 行の札にまとめ、時刻での自動ロックは畳んであります。'
            '今までの設定はそのまま引き継がれます。',
        '集中ロックのショートカットを作れるようにしました。そこから始めると、'
            'ページを開かずにロック画面から始まります。',
        '「時刻で自動的に始める」を入にしたまま枠を 1 つも作っていないと、'
            '毎晩 22 時に勝手にロックが掛かっていたのを直しました。',
      ],
      'en': [
        'The Claude Code / Codex CLI view can now open as its own window '
            'outside the app, from "Open in its own window" above the CLI list.',
        'You can create a desktop shortcut straight to that window. Launching '
            'it opens only the CLI view — the map is never started.',
        'The focus-lock settings were tidied up: what you can still use while '
            'locked is now one choice of three (nothing / research only / '
            'everything), what appears on the lock screen is a single row of '
            'chips, and the schedule is folded away. Your existing settings '
            'carry over.',
        'You can create a shortcut for focus lock too; launching it starts the '
            'lock without opening the map.',
        'Fixed: leaving "start automatically at a set time" on without adding '
            'any time range locked the screen every night at 22:00.',
      ],
    },
  ),
  ReleaseNote(
    build: 436,
    date: '2026-09-22',
    lines: <String, List<String>>{
      'ja': [
        'Claude Code / Codex CLI の「考える深さ」 を「推論」 と書くように'
            'しました。 選択肢も言い換えるのをやめて、 その CLI が実際に'
            '受け取る値 (low / medium / high / xhigh / max など) を'
            'そのまま並べます。',
        '選んだモデルと推論が、 端末で開いた時にも効くようになりました。'
            ' これまでは 1 回聞くだけの問い合わせにしか効いておらず、'
            '端末では CLI 自身の設定 (例: gpt-5.6-sol の xhigh) で'
            '始まっていました。',
        'モデルと推論は CLI ごとに覚えるようにしました。 Claude Code で'
            '選んだモデルが Codex CLI へ渡ってしまう事が無くなります。',
        '推論を指定する口が無い相手 (Gemini CLI) では、 その欄を'
            '出さないようにしました。',
        'AI やターミナルの欄が点滅する不具合を直しました。'
            ' 「最新へ」 の札・「停止」 のボタン・文字を打つ位置の追従・'
            '焦点の奪い合いが、 出力のたびに画面を組み直していたのが原因です。',
      ],
      'en': [
        'The CLI setting is now called "Reasoning" instead of "thinking '
            'depth", and the choices are the values the CLI actually takes '
            '(low / medium / high / xhigh / max) rather than reworded labels.',
        'The model and reasoning you pick now also apply when you open the '
            'CLI in a terminal. Until now they only applied to one-shot '
            'questions, so the terminal started with the CLI\'s own config '
            '(for example gpt-5.6-sol at xhigh).',
        'The model and reasoning are remembered per CLI, so a model picked '
            'for Claude Code is no longer handed to Codex CLI.',
        'For a CLI with no reasoning switch (Gemini CLI) the row is hidden.',
        'Fixed the AI and terminal panes flickering. The "jump to latest" '
            'pill, the "stop" button, the typing-position follow and a focus '
            'tug-of-war were rebuilding the pane on every chunk of output.',
      ],
    },
  ),
  ReleaseNote(
    build: 435,
    date: '2026-09-21',
    lines: <String, List<String>>{
      'ja': [
        'CLI の画面に「ファイル」 ボタンを足しました。 画像や文書を選ぶと、'
            ' その道筋が打ちかけの文へ差し込まれます (送信はしません)。',
        '要素の色の並びに「背景」「文字」 と名札を付けました。',
        '文字色の数を増やして、 背景色と同じ幅・同じ列数にそろえました。',
        '自動操作の「手順を追加」 は、 窓ではなく手順一覧の下に選択肢を'
            '並べるようにしました。',
        'マークダウンの AI 欄を、 上に「書いてもらう」、 下にチャットの'
            '1 枚にしました。 相手 (API / Claude Code / Codex CLI、 チャットは'
            'ブラウザ版も) は上と下で別々に選べます。',
        'AI の相手の表記を「PC内AI」から「Claude Code」「Codex CLI」へ改め、'
            '一覧でも 2 つに分けて選べるようにしました。',
        'Claude Code と Codex CLI を Free プランでも使えるようにしました。'
            ' その代わり、 無料プランで開けるのは一覧の先頭 2 ページまでに'
            'なりました (作成は自由。 3 ページ目以降は鍵が掛かり、'
            'ピン留めや並べ替えで開ける枠を入れ替えられます)。',
        '端末で Ctrl+V を押すと、 写している画像をファイルにして'
            'その道筋を差し込むようにしました。 「クリア」 で打ちかけの行を'
            '全消しできます。',
        '「キュー / ステア」 をアプリ側で持つ形にしました。 キューの間は'
            'Enter で順番待ちへ溜まり、 考え終わってから渡ります'
            ' (Claude Code でも使えます)。',
        'AI アシスタントを左右に並べた時、 見出しとタブの帯を'
            '1 本にし、 右の端末を押せばそちらに打てるようにしました。'
            ' 欄の札には開いているフォルダーも出ます。',
        '同じフォルダーをもう一度開こうとした時は、 「既に開かれています」 と'
            '出して、 そのタブへ移るだけにしました。',
      ],
      'en': [
        'The CLI view has a "File" button. Pick an image or document and its '
            'path is inserted into what you are typing (nothing is sent).',
        'The node colour rows are labelled "fill" and "text".',
        'More text colours were added so that row matches the width of the '
            'fill colours.',
        'In automation, "add a step" now lists the kinds under the step list '
            'instead of opening a dialog.',
        'The Markdown AI pane is now one column: "write for me" on top, chat '
            'below, each with its own engine (API, Claude Code, Codex CLI, and '
            'the browser versions for chat).',
        'The AI engines are named "Claude Code" and "Codex CLI" instead of '
            '"PC AI", and they are listed separately.',
        'Claude Code and Codex CLI now work on the free plan. In exchange, the '
            'free plan can open the first 2 pages of the list; creating pages '
            'is unlimited, and pinning or reordering changes which 2 are open.',
        'Ctrl+V in the terminal writes a clipboard image to a file and inserts '
            'its path. A "Clear" button wipes the line you are typing.',
        'Queue/steer is now handled by the app, so it works with Claude Code '
            'too: while queued, Enter parks the line and sends it once the CLI '
            'is done thinking.',
        'When the assistant is split side by side, the header and tab strip '
            'span both panes, and clicking the right pane types there.',
        'Opening a folder that is already open switches to that tab instead of '
            'starting a second one.',
      ],
    },
  ),
  ReleaseNote(
    build: 434,
    date: '2026-09-21',
    lines: <String, List<String>>{
      'ja': [
        '左右に並べている時、 札の並び順どおりに左右へ置くようにしました。'
            ' 右の札を押したのに左側が入れ替わる事が無くなります。',
        'リンクの線の既定を 4 にしました。',
        'リンクの色に白を足し、 黒と白を先頭に寄せました。',
        'リンクの設定を畳むと、 横長の帯ではなく小さなアイコン 1 つに'
            'なります。',
      ],
      'en': [
        'When two panes are side by side, they now follow the order of the '
            'tabs, so tapping the right-hand tab no longer replaces the left '
            'pane.',
        'Link lines default to 4.',
        'White was added to the link colours, and black and white moved to '
            'the front.',
        'Collapsing the link settings now leaves a small icon instead of a '
            'wide bar.',
      ],
    },
  ),
  ReleaseNote(
    build: 433,
    date: '2026-09-21',
    lines: <String, List<String>>{
      'ja': [
        '自動操作で「このページへ飛んで」 が効かなかったのを直しました。'
            ' ページ移動を WebView 自身に頼むようにし、 移れたかどうかも'
            '確かめて、 駄目なら理由を出します。',
        'リンクの線を既定で太くしました (2.0 → 3.5)。',
        'モバイルでリンクを押しやすくしました (当たり判定を 14 → 30 px)。',
        'リンクの設定を畳むと、 小さなアイコン 1 つになります。',
        'ページ背景にブループリントを戻し、 初回起動の既定にしました。',
      ],
      'en': [
        'Fixed "go to this page" doing nothing in automation. Navigation is '
            'now done by the WebView itself, and the step checks that it '
            'actually moved.',
        'Link lines are thicker by default (2.0 to 3.5).',
        'Links are easier to tap on mobile (hit area 14 to 30 px).',
        'Collapsing the link settings now leaves a single small icon.',
        'The blueprint page background is back, and is the first-launch '
            'default.',
      ],
    },
  ),
  ReleaseNote(
    build: 432,
    date: '2026-09-21',
    lines: <String, List<String>>{
      'ja': [
        'パスワードを預ける所の言い回しを分かりやすくしました'
            ' (「秘密」「合言葉」 → 「パスワード」「呼び名」)。',
        'パスワードを預ける画面を、 画面の中央ではなく押したボタンの'
            'すぐ下に出すようにしました。',
        'PC 内 AI の一覧を、 CLI ごとにその下へモデルが並ぶ形にしました。'
            ' どちらの設定なのかが一目で分かり、 モデルを選ぶだけで'
            'その CLI へ切り替わります。',
        'この欄を開いた時に、 使える CLI とログイン中のアカウントを'
            '先に調べるようにしました (Codex CLI が候補に出ないことが'
            'ありました)。',
      ],
      'en': [
        'The password store uses plainer wording.',
        'It now opens just under the button instead of in the middle of the '
            'screen.',
        'The on-device AI list nests the models of each CLI under it, so it '
            'is '
            'clear which one they belong to, and picking a model switches to '
            'that CLI.',
        'Available CLIs and their signed-in accounts are looked up when the '
            'panel opens (Codex CLI could be missing from the list).',
      ],
    },
  ),
  ReleaseNote(
    build: 431,
    date: '2026-09-21',
    lines: <String, List<String>>{
      'ja': [
        '自動操作で合言葉を預けられるようにしました。 手順には'
            ' {{secret:名前}} としか書かれず、 中身は打ち込む直前に入るので'
            ' AI にも手順の控えにも残りません (Windows の仕組みで包んで保存)。',
        '自動操作で使う AI を、 CLI と API のどちらか一方だけが選ばれた'
            '状態にしました。',
        '使う CLI を Claude Code / Codex CLI から選べるようにし、'
            ' ログイン中のアカウントも並べて出すようにしました。',
        '「CLI の設定のまま」 を「指定しない (◯◯ の設定のまま)」 に直して、'
            ' 何を指しているか分かるようにしました。',
      ],
      'en': [
        'Secrets can be stored for automation. A flow only contains '
            '{{secret:name}}; the value is filled in as it is typed, so it '
            'never reaches the AI or the saved flow (sealed with Windows '
            'DPAPI on disk).',
        'The automation AI picker now shows either CLI or API as selected, '
            'never both.',
        'You can choose which CLI to use (Claude Code / Codex CLI), with the '
            'signed-in account shown next to each.',
        '"Leave it to the CLI" is now spelled out as "no model (use <CLI> '
            'settings)".',
      ],
    },
  ),
  ReleaseNote(
    build: 430,
    date: '2026-09-21',
    lines: <String, List<String>>{
      'ja': [
        'オートクリッカーを、 画面録画の操作窓と同じ**横一列の帯**にしました。'
            ' 枠を外したので画面のどこにでも置けます。',
        'スワイプの始点と終点を、 ポインタで続けて控えられるようにしました。',
        'CLI のアカウントは、 ログイン名が読めた物だけを重複なく並べます'
            ' (「既定」 や「a1」 は出しません)。 新しいタブの一覧でも'
            ' 1 つの時から選べます。',
        '札の上で右クリックすると一覧が 2 枚重なっていたのを直しました。',
        '「下に分割」 を選んでいるのに上側に開いてしまう不具合を直しました'
            ' (ターミナルで選んだ開き方が効いていなかったのも直しました)。',
        '端末や AI の画面を、 右クリックから 3 枚・4 枚に増やせるように'
            ' しました。',
        '再生速度の上限を UI の配置設定に並べ、 速度バーの右に置きました。'
            ' 数値でも決められます。',
        '自動操作を左右 2 列で使う時、 要らなくなった高さ調整の帯を'
            ' 消しました。',
        '右クリックからのページ削除を、 ページが 1 枚の時も出すように'
            ' しました (ヘッダーの ⋮ と同じ)。',
        '背景のあるページを動かす時の重さを取りました。',
      ],
      'en': [
        'The auto clicker is now a horizontal bar like the screen-recording '
            'window, with no frame, so it can sit anywhere on screen.',
        'A swipe can capture its start and end points with the pointer, one '
            'after the other.',
        'CLI accounts are listed only when their sign-in name could be read, '
            'with duplicates removed.',
        'Right-clicking a tab no longer opens two stacked menus.',
        'Choosing "split bottom" no longer opens the pane at the top.',
        'Terminals and AI panes can be grown to three or four from the '
            'right-click menu.',
        'The playback-speed ceiling is now a placeable item next to the speed '
            'bar, and can be typed as a number.',
        'The height-drag strip is gone from the two-column automation page.',
        'Delete-this-page is offered from the right-click menu even when only '
            'one page is left.',
        'Panning a page with a background is no longer heavy.',
      ],
    },
  ),
  ReleaseNote(
    build: 429,
    date: '2026-09-21',
    lines: <String, List<String>>{
      'ja': [
        'モバイルの YouTube で、 動画以外を隠すボタンの印を目から枠の印に'
            '変えました。',
        '隠した後は、 ヘッダーが居た帯のどこを押しても戻せるようになりました'
            ' (小さな点を狙わなくて済みます)。',
        '再生速度の上限を 2 倍 / 3 倍 / 4 倍 / 5 倍の 4 択にしました。'
            ' 狭い画面でも入り切ります。',
        '上限のボタンの印を、 UI 配置のボタンと別の物にしました。',
        '右クリック (長押し) から、 このページを削除できるようになりました。',
      ],
      'en': [
        'On mobile YouTube, the button that hides everything but the video '
            'no longer uses an eye icon.',
        'Once hidden, tapping anywhere along the band where the header was '
            'brings it back (no more aiming at a small spot).',
        'The playback-speed ceiling is now a choice of 2x, 3x, 4x or 5x, so '
            'it fits on a narrow screen.',
        'The ceiling button no longer shares its icon with the layout button.',
        'Right-click (or long-press) can now delete the current page.',
      ],
    },
  ),
  ReleaseNote(
    build: 428,
    date: '2026-09-21',
    lines: <String, List<String>>{
      'ja': [
        'オートクリッカーを動作パレットにしました。 クリック・スワイプ・'
            'ホイール・連打・スクショなどを札にして、 押すだけで出せます。',
        'パレットを常に手前の別窓へ出せるようにしました。 他のアプリを'
            '触っている間も消えずに押せます。',
        '押す先は座標で指定する形に一本化しました (カーソルから取り込む口も'
            '残してあります)。',
        '端末や AI の画面を、 左右 3 枚・4 枚まで並べられるようにしました。',
        '背景が画面の比率に入り切らない時、 動かすと少しずつ違う所が'
            '見えるようになりました (モバイルの縦長画面向け)。',
        'モバイルで Google 検索のヘッダーを隠した後、 上の細い帯から'
            '戻せるようにしました。',
        '「クリック手順」 のボタンを廃止しました (手順を組む所は自動操作の'
            'ページです)。 仮想デスクトップの項目も無くしました。',
        '自動操作のページを、 広い画面では左右 2 列で使えるようにしました。',
        'ログイン中のアカウントが同じ名前で並んだ時に、 番号で見分けが'
            '付くようにしました。',
      ],
      'en': [
        'The auto clicker is now an action palette. Click, swipe, wheel, '
            'repeat click and screenshot become cards you can fire with a tap.',
        'The palette can be sent to its own always-on-top window, so it stays '
            'usable while another app has focus.',
        'Targets are now given as coordinates (a button to read them from the '
            'cursor is still there).',
        'Terminals and AI panes can now be placed three and four across.',
        'When a background does not fit the screen ratio, moving around now '
            'reveals the rest of it (for tall phone screens).',
        'After hiding the Google search header on mobile, a slim bar at the '
            'top brings it back.',
        'The "click steps" button was removed (steps are built on the '
            'automation page). The virtual desktop entry is gone too.',
        'The automation page now uses two columns on a wide screen.',
        'Accounts that resolve to the same name are now numbered so they can '
            'be told apart.',
      ],
    },
  ),
  ReleaseNote(
    build: 427,
    date: '2026-09-21',
    lines: <String, List<String>>{
      'ja': [
        'AI アシスタントのタブを 1 本の帯にまとめました。 会話のタブも端末の'
            'タブと同じように動かせて、 入り切らない時は帯の中が横に流れます。',
        'タブを増やす「+」 を帯の右端に固定しました。',
        'ターミナルのボタンを右クリックすると、 開くシェルを選べます'
            ' (このパソコンに入っている物だけを並べます)。',
        'シェルのタブで「フォルダーを選ぶ」 を押すと、 その場で cd して'
            'そのフォルダーへ移ります。',
        'CLI のタブを右クリックすると、 ログイン中のアカウントが分かり、'
            '別のアカウントで開き直せます。',
        'Ctrl+W でタブを閉じられるようにしました。 処理をしていないタブは'
            '確認なしで閉じます。',
        '左右に並べる時、 足りない幅を自動で広げるようにしました'
            ' (端末どうしでも両方が出ます)。',
        'AI (API) にも、 編集を許すフォルダーを渡せるようにしました。',
        'codex の画面の下に、 キューとステアを入れ替えるボタンを付けました。',
      ],
      'en': [
        'The assistant tabs are now one strip. Conversation tabs can be '
            'dragged like terminal tabs, and the strip scrolls when they no '
            'longer fit.',
        'The "+" for a new tab is pinned to the right edge of the strip.',
        'Right-clicking the terminal button lets you pick which shell opens '
            '(only the ones installed on this PC are listed).',
        'Picking a folder from a shell tab now runs cd and moves that shell '
            'into the folder.',
        'Right-clicking a CLI tab shows which account is signed in and lets '
            'you reopen the tab with another one.',
        'Ctrl+W closes the current tab. Tabs with nothing running close '
            'without asking.',
        'Splitting left and right now widens the panel to the width it needs, '
            'so both panes really appear (terminals included).',
        'AI (API) can now be given a folder it is allowed to edit.',
        'A button to swap queue and steer was added below the codex view.',
      ],
    },
  ),
  ReleaseNote(
    build: 426,
    date: '2026-09-20',
    lines: <String, List<String>>{
      'ja': [
        'ページに背景を敷いている時は、 後ろのマス目線を描かなくなりました。',
        '背景にする画像を選ぶと、 編集画面を挟まずそのまま反映されます。',
        '背景を画面より大きく描くようにしました。 動かすと違う所が見えます。',
        '「背景を自作」 をやめました (テンプレート・画像・AI で作る道は残っています)。',
        '境界を跨いでデータを渡すモードの間は、 端で画面が追ってこなくなりました。',
        'アプリ固定中にボタンを押すと残り時間が出ます。 手動の解除を切っている時は、'
            ' 長押しの案内ではなく「解除は無効です」 と出ます。',
        'この更新内容が、 表示の言語で読めるようになりました。',
      ],
      'en': [
        'The grid behind the page is no longer drawn while a background is set.',
        'Picking a background image now applies it straight away, with no '
            'editor in between.',
        'The background is drawn larger than the screen, so scrolling reveals '
            'a different part of it.',
        'The "make your own background" option was removed (templates, your '
            'own images and AI generation are still there).',
        'While the cross-boundary transfer mode is on, the view no longer '
            'chases the edge as you drag.',
        'Pressing the button while the app is pinned now shows the time left. '
            'If manual unlocking is turned off, it says so instead of telling '
            'you to long-press.',
        'These release notes now follow your display language.',
      ],
      'zh': [
        '设置了页面背景时，不再绘制背后的方格线。',
        '选择背景图片后会直接生效，中途不再打开编辑画面。',
        '背景绘制得比屏幕更大，滚动时会看到不同的部分。',
        '移除了“自制背景”项（模板、自选图片、AI 生成仍然保留）。',
        '在跨越边界传输数据的模式下，拖动时画面不再追随边缘。',
        '固定应用期间按下按钮会显示剩余时间。若已关闭手动解除，会提示“无法解除”'
            '而不是提示长按。',
        '更新内容现在会按显示语言显示。',
      ],
      'ko': [
        '페이지에 배경을 깔았을 때 뒤의 모눈선을 그리지 않습니다.',
        '배경 이미지를 고르면 편집 화면을 거치지 않고 바로 적용됩니다.',
        '배경을 화면보다 크게 그립니다. 움직이면 다른 부분이 보입니다.',
        '"배경 직접 만들기" 항목을 없앴습니다 (템플릿·이미지·AI 생성은 그대로입니다).',
        '경계를 넘어 데이터를 옮기는 모드에서는 가장자리에서 화면이 따라오지 않습니다.',
        '앱 고정 중에 버튼을 누르면 남은 시간이 표시됩니다. 수동 해제를 꺼 두면 '
            '길게 누르라는 안내 대신 "해제할 수 없습니다" 라고 나옵니다.',
        '업데이트 내용이 표시 언어로 나옵니다.',
      ],
      'es': [
        'Ya no se dibuja la cuadricula de fondo cuando la pagina tiene un fondo.',
        'Al elegir una imagen de fondo se aplica al momento, sin pasar por el '
            'editor.',
        'El fondo se dibuja mas grande que la pantalla: al desplazarte ves otra '
            'parte.',
        'Se quito la opcion de crear tu propio fondo (siguen las plantillas, tus '
            'imagenes y la generacion con IA).',
        'Con el modo de transferencia entre paneles activo, la vista ya no sigue '
            'el borde al arrastrar.',
        'Al pulsar el boton con la app fijada se muestra el tiempo restante. Si '
            'el desbloqueo manual esta desactivado, se indica en lugar de pedir '
            'una pulsacion larga.',
        'Estas notas ahora siguen el idioma de la interfaz.',
      ],
      'fr': [
        'La grille de fond n est plus dessinee lorsque la page a un arriere-plan.',
        'Choisir une image d arriere-plan l applique immediatement, sans passer '
            'par l editeur.',
        'L arriere-plan est dessine plus grand que l ecran : en faisant defiler, '
            'vous en voyez une autre partie.',
        'L option de creer son propre arriere-plan a ete retiree (modeles, images '
            'et generation par IA restent disponibles).',
        'Avec le mode de transfert entre panneaux, la vue ne suit plus le bord '
            'pendant le glisser.',
        'Appuyer sur le bouton quand l application est epinglee affiche le temps '
            'restant. Si le deverrouillage manuel est desactive, cela est '
            'indique au lieu de demander un appui long.',
        'Ces notes suivent desormais la langue d affichage.',
      ],
      'de': [
        'Das Raster im Hintergrund wird nicht mehr gezeichnet, wenn die Seite '
            'einen Hintergrund hat.',
        'Ein gewaehltes Hintergrundbild wird sofort uebernommen, ohne den Editor '
            'dazwischen.',
        'Der Hintergrund wird groesser als der Bildschirm gezeichnet: beim '
            'Scrollen sehen Sie einen anderen Ausschnitt.',
        'Die Option "eigenen Hintergrund erstellen" wurde entfernt (Vorlagen, '
            'eigene Bilder und KI-Erzeugung bleiben).',
        'Im Modus zum Uebergeben ueber die Grenze folgt die Ansicht beim Ziehen '
            'nicht mehr dem Rand.',
        'Ein Druck auf die Taste bei angehefteter App zeigt die Restzeit. Ist das '
            'manuelle Entsperren aus, wird das gesagt statt zum langen Druecken '
            'aufzufordern.',
        'Diese Hinweise folgen jetzt der Anzeigesprache.',
      ],
      'pt': [
        'A grade ao fundo deixa de ser desenhada quando a pagina tem um fundo.',
        'Escolher uma imagem de fundo aplica na hora, sem passar pelo editor.',
        'O fundo e desenhado maior que a tela: ao rolar, voce ve outra parte.',
        'A opcao de criar o proprio fundo foi removida (modelos, suas imagens e '
            'geracao por IA continuam).',
        'Com o modo de transferencia entre paineis ligado, a vista nao segue mais '
            'a borda ao arrastar.',
        'Pressionar o botao com o app fixado mostra o tempo restante. Se o '
            'desbloqueio manual estiver desligado, isso e informado em vez de '
            'pedir um toque longo.',
        'Estas notas agora seguem o idioma da interface.',
      ],
      'ru': [
        'Setka na fone bolshe ne risuetsya, kogda u stranitsy est fon.',
        'Vybrannoe fonovoe izobrazhenie primenyaetsya srazu, bez redaktora.',
        'Fon risuetsya krupnee ekrana: pri prokrutke vidno druguyu ego chast.',
        'Punkt "sozdat svoy fon" udalen (shablony, svoi izobrazheniya i '
            'generatsiya AI ostayutsya).',
        'V rezhime peredachi cherez granitsu vid bolshe ne sleduet za krayem pri '
            'peretaskivanii.',
        'Nazhatie knopki pri zakreplennom prilozhenii pokazyvaet ostavsheesya '
            'vremya. Esli ruchnaya razblokirovka otklyuchena, ob etom soobshchayut '
            'vmesto pros by uderzhivat knopku.',
        'Eti zametki teper sleduyut yazyku interfeysa.',
      ],
    },
  ),
  ReleaseNote(
    build: 425,
    date: '2026-09-20',
    lines: <String, List<String>>{
      'ja': [
        'PC内AI の最初の画面を、 広い画面では中央に寄せて読みやすくしました。',
        'CLI を開くたびにフォルダーを聞かれるのをやめました。 既定は今開いて'
            'いるページの置き場で、 変えたい時だけ一覧の下の欄から選べます。',
        'CLI が作業フォルダーの外 (.claude / .codex / .gemini の中の '
            'AGENTS.md など) も読めるようにしました。',
        'アカウントを足す時の名前の入力をやめました。 札にはログインした'
            'アカウント名がそのまま出ます。',
        'CLI を起こす時に道筋を 8.3 形式 (PROGRA~1) へ縮めるのをやめました。'
            ' セキュリティソフトに咎められる原因の 1 つでした。',
        '版が上がった時に、 この更新内容を 1 度だけ出すようにしました。'
            ' 設定の「更新内容」 からいつでも読み返せます。',
        '開発者からのお知らせを受け取れるようにしました。',
      ],
      'en': [
        'The first screen of On-device AI is now centred on wide displays.',
        'The CLI no longer asks which folder to use every time you open it. '
            'It defaults to the folder of the page you have open, and you can '
            'change it from the row at the bottom of the list.',
        'The CLI can now read files outside the working folder, such as the '
            'AGENTS.md inside .claude / .codex / .gemini.',
        'Adding an account no longer asks you to type a name — the label shows '
            'the account you signed in with.',
        'Paths are no longer shortened to 8.3 form (PROGRA~1) when starting a '
            'CLI; that was one of the things security software objected to.',
        'Release notes like this one now appear once after each update, and can '
            'be reopened any time from Settings.',
        'You can now receive announcements from the developer.',
      ],
    },
  ),
  ReleaseNote(
    build: 424,
    date: '2026-09-20',
    lines: <String, List<String>>{
      'ja': [
        'ターミナルのボタンを右クリック (長押し) すると、 全画面 / フローティング'
            ' / 左右上下の分割から開き方を選べます。',
        'テキストとマークダウンの編集画面からもターミナルを開けます。',
      ],
      'en': [
        'Right-click (long-press) the terminal button to choose how it opens: '
            'full screen, floating, or split to any side.',
        'The terminal can also be opened from the text and Markdown editors.',
      ],
    },
  ),
  ReleaseNote(
    build: 423,
    date: '2026-09-20',
    lines: <String, List<String>>{
      'ja': [
        'AI (API) の画面を全画面にできるようにし、 文字を中央に寄せました。',
        'CLI のタブを終わらせた後の画面の移り方を直しました。',
      ],
      'en': [
        'The AI (API) view can now go full screen, with text centred.',
        'Fixed where the view goes after a CLI tab ends.',
      ],
    },
  ),
];

/// 今の版 (= 一覧の先頭)。 一覧が空なら 0。
int get kCurrentAppBuild =>
    kReleaseNotes.isEmpty ? 0 : kReleaseNotes.first.build;
