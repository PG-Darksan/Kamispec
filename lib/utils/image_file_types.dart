/// 「絵のファイル」 の拡張子と、 絵を選ぶダイアログをまとめた場所。
///
/// ★ 利用者の報告「ページ背景画像が jpe 形式に対応していない」。
///   真因は file_picker の Windows 実装で、 FileType.image を渡すと
///   'Images (*.bmp,*.gif,*.jpeg,*.jpg,*.png)' という固定のフィルタに
///   変換されてしまう。 そのため .jpe / .jfif / .webp のファイルは
///   ダイアログの一覧にそもそも出て来ず、 選べなかった。
///   (選びさえすれば Image.file は中身で復号するので表示はできる)
///
/// 直し方: デスクトップでは FileType.custom + 自前の拡張子一覧を渡す。
///   モバイル (Android/iOS) は MIME の 'image/*' の方が広いので
///   FileType.image のまま触らない。
///
/// 併せて、 アプリ中に散らばっていた「絵かどうか」 の判定 (拡張子の集合)
/// もこの一覧に寄せる。 画面・部品・模型 (model)・MCP の判定がずれると、
/// ノードの当たり判定や接続点が描画とずれるため、 必ずここを見るようにする。
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:file_picker/file_picker.dart';

/// 絵として開ける拡張子 (すべて小文字・ドット無し)。
///
/// node_widget.dart の isImageAttach / models/mind_map_node.dart の
/// visualHeight / services/mcp_server.dart の _kImageExts は、
/// この集合と必ず同じ物を指すこと。
const Set<String> kImageFileExts = <String>{
  'jpg',
  'jpeg',
  'jpe',
  'jfif',
  'png',
  'gif',
  'webp',
  'bmp',
};

/// ファイル選択ダイアログの allowedExtensions 用 (並び順は表示用)。
///
/// const の一覧に足したい時は
///   `const ['pdf', ...kImagePickerExts]`
/// のように広げて使える。
const List<String> kImagePickerExts = <String>[
  'jpg',
  'jpeg',
  'jpe',
  'jfif',
  'png',
  'gif',
  'webp',
  'bmp',
];

/// パスや URL から拡張子 (小文字・ドット無し) を取り出す。
///
/// '?'・'#' 以降は落とす。 拡張子が無ければ '' を返す
/// (`split('.').last` だと、 拡張子の無いパスでフルパスがそのまま
///  返ってしまうのでこちらを使う)。
String fileExtOf(String path) {
  var s = path;
  final q = s.indexOf('?');
  if (q >= 0) s = s.substring(0, q);
  final h = s.indexOf('#');
  if (h >= 0) s = s.substring(0, h);
  final slash = s.lastIndexOf(RegExp(r'[\\/]'));
  final name = slash >= 0 ? s.substring(slash + 1) : s;
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

/// 拡張子 (ドット有無どちらでも可) が絵か。
bool isImageFileExt(String ext) {
  var e = ext.toLowerCase();
  if (e.startsWith('.')) e = e.substring(1);
  return kImageFileExts.contains(e);
}

/// パスが絵のファイルか。
bool isImageFilePath(String path) => isImageFileExt(fileExtOf(path));

/// 絵の Content-Type。 分からない物は null。
String? imageMimeForExt(String ext) {
  var e = ext.toLowerCase();
  if (e.startsWith('.')) e = e.substring(1);
  switch (e) {
    case 'jpg':
    case 'jpeg':
    case 'jpe':
    case 'jfif':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'gif':
      return 'image/gif';
    case 'webp':
      return 'image/webp';
    case 'bmp':
      return 'image/bmp';
  }
  return null;
}

/// 生成 AI (Gemini / OpenAI / Claude) が画像として受け取れる拡張子。
///
/// ★ 各社が公表している画像の型は png / jpeg / webp / gif (加えて Gemini の
///   heic / heif) で、 **bmp は入っていない**。 共通一覧 [kImageFileExts] は
///   「アプリが絵として扱う物」 なので bmp も含むが、 AI へ送る経路で
///   image/bmp をそのまま渡すと相手側で弾かれる。 API へ渡す時は必ず
///   この一覧 / [aiImageMimeForExt] で絞るか、 png に焼き直してから渡す事。
///   (ブラウザ版 AI へ D&D / 貼り付けで渡す経路は相手が普通の Web ページな
///    ので bmp のままで良い。 ここで絞るのは API に送る時だけ)
const Set<String> kAiImageFileExts = <String>{
  'jpg',
  'jpeg',
  'jpe',
  'jfif',
  'png',
  'gif',
  'webp',
};

/// AI に送る時の絵の Content-Type。 AI が受け取れない形 (bmp 等) は null。
String? aiImageMimeForExt(String ext) {
  var e = ext.toLowerCase();
  if (e.startsWith('.')) e = e.substring(1);
  if (!kAiImageFileExts.contains(e)) return null;
  return imageMimeForExt(e);
}

/// jpe / jfif / jpg を jpeg にそろえる (Office の書類は拡張子で
/// Content-Type が決まるため、 見慣れない綴りのまま入れると壊れる)。
String normalizeImageExtForOffice(String ext) {
  final e = ext.toLowerCase();
  if (e == 'jpg' || e == 'jpe' || e == 'jfif') return 'jpeg';
  return e;
}

bool get _isDesktopPicker =>
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

/// 絵を選ぶダイアログ。 FilePicker.platform.pickFiles(type: FileType.image)
/// の代わりに必ずこれを使う。
///
/// ★ Windows の FileType.image は file_picker が固定フィルタを組むので
///   .jpe / .jfif / .webp が一覧に出ない。 デスクトップは FileType.custom +
///   kImagePickerExts、 モバイルは今までどおり FileType.image。
Future<FilePickerResult?> pickImageFiles({
  String? dialogTitle,
  bool allowMultiple = false,
  bool withData = false,
  String? initialDirectory,
}) {
  final desktop = _isDesktopPicker;
  return FilePicker.platform.pickFiles(
    dialogTitle: dialogTitle,
    allowMultiple: allowMultiple,
    withData: withData,
    initialDirectory: initialDirectory,
    type: desktop ? FileType.custom : FileType.image,
    allowedExtensions: desktop ? kImagePickerExts : null,
  );
}
