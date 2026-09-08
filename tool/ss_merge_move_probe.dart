// Enter / Shift+Enter で選ぶ場所を上下に移す時、 結合したセルの内側へ
// 入らないか (= 入ると入力欄が出ないまま操作が効かなくなる) を確かめる道具。
//   dart run tool/ss_merge_move_probe.dart
//
// アプリ側 (_moveSelVert) と同じ計算をここに写して試す。

class Merge {
  final int r1, c1, r2, c2;
  const Merge(this.r1, this.c1, this.r2, this.c2);
  bool contains(int r, int c) => r >= r1 && r <= r2 && c >= c1 && c <= c2;
}

int rowCount = 10;
List<Merge> merges = const [];

Merge? mergeAt(int r, int c) {
  for (final m in merges) {
    if (m.contains(r, c)) return m;
  }
  return null;
}

/// アプリと同じ計算 (= _moveSelVert の中身)。
int moveSelVert(int selRow, int selCol, int d) {
  var next = (selRow + d).clamp(0, rowCount - 1);
  final mg = mergeAt(next, selCol);
  if (mg != null && next != mg.r1) {
    next = (d > 0 ? mg.r2 + 1 : mg.r1).clamp(0, rowCount - 1);
    final mg2 = mergeAt(next, selCol);
    if (mg2 != null && next != mg2.r1) next = mg2.r1;
  }
  return next;
}

int fails = 0;

void check(String label, int got, int want) {
  final ok = got == want;
  print('${ok ? '  OK  ' : ' FAIL '} $label  → $got (期待 $want)');
  if (!ok) fails++;
}

/// 行き着いた先が「結合の内側 (左上の行ではない)」 になっていないか。
void checkNotInside(String label, int row, int col) {
  final mg = mergeAt(row, col);
  final bad = mg != null && row != mg.r1;
  print('${bad ? ' FAIL ' : '  OK  '} $label  → 行 $row'
      '${bad ? ' は結合 ${mg.r1}..${mg.r2} の内側' : ''}');
  if (bad) fails++;
}

void main() {
  print('■ 結合が無い時は今までどおり 1 つずつ動く');
  merges = const [];
  check('4 から下', moveSelVert(4, 0, 1), 5);
  check('4 から上', moveSelVert(4, 0, -1), 3);
  check('一番下で下', moveSelVert(9, 0, 1), 9);
  check('一番上で上', moveSelVert(0, 0, -1), 0);

  print('\n■ A5:B7 (行 4..6) が結合されている時');
  merges = const [Merge(4, 0, 6, 1)];
  check('行 3 から下 → 結合の左上 (4)', moveSelVert(3, 0, 1), 4);
  check('結合の左上 (4) から下 → 結合の次 (7)', moveSelVert(4, 0, 1), 7);
  check('行 7 から上 → 結合の左上 (4)', moveSelVert(7, 0, -1), 4);
  check('結合の左上 (4) から上 → 3', moveSelVert(4, 0, -1), 3);
  check('結合していない列 (2) は素通り', moveSelVert(4, 2, 1), 5);
  for (var r = 0; r < rowCount; r++) {
    checkNotInside('行 $r から下', moveSelVert(r, 0, 1), 0);
    checkNotInside('行 $r から上', moveSelVert(r, 0, -1), 0);
  }

  print('\n■ 表の一番下まで結合されている時 (行 8..9)');
  merges = const [Merge(8, 0, 9, 0)];
  check('結合の左上 (8) から下 → 端で止まる', moveSelVert(8, 0, 1), 8);
  checkNotInside('端で押し戻された時', moveSelVert(8, 0, 1), 0);

  print('\n■ 結合が続いている時 (行 2..3 と 行 4..5)');
  merges = const [Merge(2, 0, 3, 0), Merge(4, 0, 5, 0)];
  check('行 1 から下 → 2', moveSelVert(1, 0, 1), 2);
  check('行 2 から下 → 4 (次の結合の左上)', moveSelVert(2, 0, 1), 4);
  check('行 4 から下 → 6', moveSelVert(4, 0, 1), 6);
  check('行 6 から上 → 4', moveSelVert(6, 0, -1), 4);
  check('行 4 から上 → 2 の内側 (3) ではなく 2', moveSelVert(4, 0, -1), 2);
  for (var r = 0; r < rowCount; r++) {
    checkNotInside('行 $r から下', moveSelVert(r, 0, 1), 0);
    checkNotInside('行 $r から上', moveSelVert(r, 0, -1), 0);
  }

  print('\n${fails == 0 ? 'すべて通った' : "$fails 件こけた"}');
}
