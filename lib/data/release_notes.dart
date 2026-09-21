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
