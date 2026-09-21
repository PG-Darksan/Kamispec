// 「秘密の控え」 の検分。
//
// ★ = ユーザー要望「AI にパスワードを直接平文で渡さずに渡す仕組み」。
//   ここが黙って失敗すると、 合言葉が保存されないのに保存されたように
//   見える (= 一番たちが悪い)。 包んで → 開いて → 元に戻るかを確かめる。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mindmap_app/services/secret_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('包んで開くと元に戻る (Windows の DPAPI)', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    expect(SecretStore.supported, isTrue,
        reason: 'この検分は Windows で走らせる前提');
    const name = '検分用';
    const value = r'P@ssw0rd! 日本語もある 123';
    expect(await SecretStore.put(name, value), isTrue);
    expect(await SecretStore.names(), contains(name));
    expect(await SecretStore.read(name), value);
    await SecretStore.remove(name);
    expect(await SecretStore.names(), isNot(contains(name)));
  });

  test('控えの中身は平文では入っていない', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const value = 'SuperSecret12345';
    await SecretStore.put('x', value);
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('automation_secrets_v1') ?? '';
    expect(raw, isNotEmpty);
    expect(raw.contains(value), isFalse,
        reason: '包んだはずの値がそのまま控えに出ている');
  });

  test('{{secret:名前}} が打ち込む直前に中身へ変わる', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SecretStore.put('会社メール', 'hunter2');
    expect(await SecretStore.expand('{{secret:会社メール}}'), 'hunter2');
    expect(await SecretStore.expand('前 {{ secret : 会社メール }} 後'),
        '前 hunter2 後');
    // 預かっていない名前は、 そのまま残す (= 勝手に空にしない)。
    expect(await SecretStore.expand('{{secret:無い}}'), '{{secret:無い}}');
    // 記録用は伏せ字になる。
    expect(SecretStore.mask('{{secret:会社メール}}'), '********');
  });
}
