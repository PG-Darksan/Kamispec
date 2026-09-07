// マウスのボタン割り当ての控え (prefs に入る形) の見張り。
//
// ★ 左/右ボタンを受け付けない事を確かめるのが主目的。 万一そこへ割り当てが
//   入ると、 フックが押下を握り潰してパソコンを操作できなくなる。
import 'package:flutter_test/flutter_test.dart';
import 'package:mindmap_app/services/mouse_remap.dart';

void main() {
  test('書いて読み直しても同じ', () {
    const b = MouseKeyBinding(
        button: MouseButtonId.back, modifiers: 2 | 4, vk: 0x41);
    final back = MouseKeyBinding.fromJson(b.toJson());
    expect(back, isNotNull);
    expect(back!.button, MouseButtonId.back);
    expect(back.modifiers, 6);
    expect(back.vk, 0x41);
    expect(back.toWire(), [MouseButtonId.back, 6, 0x41]);
  });

  test('知らないボタンは受け付けない', () {
    // 0 = 左、 4 以降 = 無い物。 どちらも割り当ててはいけない。
    for (final bad in [0, 4, -1, 99]) {
      expect(MouseKeyBinding.fromJson({'b': bad, 'm': 0, 'k': 0x41}), isNull,
          reason: 'button=$bad が通ってしまった');
    }
  });

  test('壊れた控えは黙って捨てる', () {
    expect(MouseKeyBinding.fromJson(null), isNull);
    expect(MouseKeyBinding.fromJson('x'), isNull);
    expect(MouseKeyBinding.fromJson(<String, dynamic>{}), isNull);
    // キーが無い物も駄目。
    expect(MouseKeyBinding.fromJson({'b': MouseButtonId.middle}), isNull);
    // 修飾キーが無いのは既定 0 で通す。
    final ok =
        MouseKeyBinding.fromJson({'b': MouseButtonId.middle, 'k': 0x70});
    expect(ok?.modifiers, 0);
    expect(ok?.vk, 0x70);
  });
}
