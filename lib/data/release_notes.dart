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
// ★ 文は ja と en の 2 つだけ持つ。 30 言語ぶん書くのは現実的でないので、
//   `t()` と同じ考え方で「その言語が無ければ en、 それも無ければ ja」 に
//   落とす。 利用者に見せる文なので、 開発の言葉ではなく**何ができるように
//   なったか**で書く事。

class ReleaseNote {
  const ReleaseNote({
    required this.build,
    required this.date,
    required this.ja,
    required this.en,
  });

  /// `pubspec.yaml` の `version: 1.0.0+<build>` と同じ数。
  final int build;

  /// 出した日 (`yyyy-MM-dd`)。 見出しに出すだけ。
  final String date;

  final List<String> ja;
  final List<String> en;

  /// その言語で読む行。 無ければ en → ja の順に落とす。
  List<String> linesFor(String lang) {
    if (lang == 'ja') return ja.isNotEmpty ? ja : en;
    return en.isNotEmpty ? en : ja;
  }
}

/// 画面に出す版の名前 (`pubspec.yaml` の `version:` の `+` の前)。
const String kAppVersionName = '1.0.0';

/// **新しい順**に並べる (先頭が今の版)。
const List<ReleaseNote> kReleaseNotes = <ReleaseNote>[
  ReleaseNote(
    build: 425,
    date: '2026-09-20',
    ja: [
      'PC内AI の最初の画面を、 広い画面では中央に寄せて読みやすくしました。',
      'CLI を開くたびにフォルダーを聞かれるのをやめました。 既定は今開いて'
          'いるページの置き場で、 変えたい時だけ一覧の下の欄から選べます。',
      'CLI が作業フォルダーの外 (`.claude` / `.codex` / `.gemini` の中の '
          'AGENTS.md など) も読めるようにしました。',
      'アカウントを足す時の名前の入力をやめました。 札にはログインした'
          'アカウント名がそのまま出ます。',
      'CLI を起こす時に道筋を 8.3 形式 (`PROGRA~1`) へ縮めるのをやめました。'
          ' セキュリティソフトに咎められる原因の 1 つでした。',
      '版が上がった時に、 この更新内容を 1 度だけ出すようにしました。'
          ' 設定の「更新内容」 からいつでも読み返せます。',
      '開発者からのお知らせを受け取れるようにしました。',
    ],
    en: [
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
      'Release notes like this one now appear once after each update.',
      'You can now receive announcements from the developer.',
    ],
  ),
  ReleaseNote(
    build: 424,
    date: '2026-09-20',
    ja: [
      'こまかな不具合を直しました。',
    ],
    en: [
      'Small fixes.',
    ],
  ),
  ReleaseNote(
    build: 423,
    date: '2026-09-20',
    ja: [
      'AI (API) の画面を全画面にできるようにし、 文字を中央に寄せました。',
      'CLI のタブを終わらせた後の画面の移り方を直しました。',
      '仮想デスクトップとクリック手順まわりを足しました。',
    ],
    en: [
      'The AI (API) view can now go full screen, with text centred.',
      'Fixed where the view goes after a CLI tab ends.',
      'Added virtual desktops and click sequences.',
    ],
  ),
  ReleaseNote(
    build: 418,
    date: '2026-09-19',
    ja: [
      'ギャラリーで消した後の並びがすぐ整うようにしました。',
      'パソコンの設定が、 画面を閉じた後も保たれるようにしました。',
      '見た目の設定を開いた時の重さを直しました。',
    ],
    en: [
      'The gallery now tidies itself right after you delete something.',
      'PC settings are kept after you close the screen.',
      'Fixed the slowdown when opening the appearance settings.',
    ],
  ),
  ReleaseNote(
    build: 417,
    date: '2026-09-19',
    ja: [
      'CLI が上限に当たった時に、 解けるまで待てるようにしました。',
      'スマホの YouTube を 2 段の作りにし、 再生を安定させました。',
      '分割の入れ子と拡大率の位置を直しました。',
    ],
    en: [
      'The CLI can now wait for a usage limit to lift.',
      'YouTube on phones now has a two-row layout and plays more reliably.',
      'Fixed nested splits and the position of the zoom control.',
    ],
  ),
];

/// 今の版 (= 一覧の先頭)。 一覧が空なら 0。
int get kCurrentAppBuild =>
    kReleaseNotes.isEmpty ? 0 : kReleaseNotes.first.build;
