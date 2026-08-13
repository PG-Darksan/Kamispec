// 有料プランが必要な機能に触れた時の「誘導モーダル」 の共通入口
// (= ユーザー要望: 有料プランが必要な機能にアクセスしようとした時は誘導
// モーダルが表示されるように)。
//
// 実体のモーダル (プラン選択・購入導線付き) は `mind_map_screen.dart` の
// `_showPaywallDialog` にあり、 そこから起動時にこのフックへ登録される。
// 各ウィジェットは `showPaywallModal(context, message)` を呼ぶだけでよい。
import 'package:flutter/material.dart';

/// 画面側が登録する実装 (bodyOverride 付きでプラン誘導モーダルを開く)。
void Function(BuildContext context, String message)? paywallPresenter;

/// 有料プラン誘導モーダルを表示する。 未登録の環境では簡易ダイアログ。
void showPaywallModal(BuildContext context, String message) {
  final presenter = paywallPresenter;
  if (presenter != null) {
    presenter(context, message);
    return;
  }
  showDialog<void>(
    context: context,
    builder: (dctx) => AlertDialog(
      backgroundColor: const Color(0xFF2A2A3E),
      title: const Row(children: [
        Icon(Icons.workspace_premium_rounded, color: Color(0xFFFFB347)),
        SizedBox(width: 8),
        Text('Pro / Max', style: TextStyle(color: Colors.white, fontSize: 15)),
      ]),
      content: Text(message,
          style: const TextStyle(color: Colors.white70, fontSize: 13)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dctx).pop(),
          child: const Text('OK', style: TextStyle(color: Colors.white70)),
        ),
      ],
    ),
  );
}
