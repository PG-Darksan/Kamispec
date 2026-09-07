// 低水準マウスフック (WH_MOUSE_LL) の受け口が、 GetMessageW で待っている
// isolate の中から本当に呼ばれるかを実測する。
//
//   dart run tool/mouse_hook_probe.dart
//
// ★ ここで作るのは「握り潰すだけ」 のフック。 キーは一切送らないので、
//   手前のアプリに文字が入る事はない。 試しに送る中ボタンの押下も、
//   フックが握り潰すのでどこにも届かない。
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

typedef _HookProcNative = IntPtr Function(Int32, UintPtr, IntPtr);

int _hits = 0;
int _mid = 0;
SendPort? _report;
int Function(int, int, int, int)? _callNext;

int _proc(int nCode, int wParam, int lParam) {
  if (nCode >= 0) {
    _hits++;
    if (wParam == 0x0207 || wParam == 0x0208) {
      _mid++;
      _report?.send(['mid', _mid]);
      return 1; // 握り潰す
    }
  }
  return _callNext?.call(0, nCode, wParam, lParam) ?? 0;
}

void _loop(List<Object?> args) {
  final send = args[0] as SendPort;
  _report = send;
  final user32 = DynamicLibrary.open('user32.dll');
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  _callNext = user32.lookupFunction<IntPtr Function(IntPtr, Int32, UintPtr, IntPtr),
      int Function(int, int, int, int)>('CallNextHookEx');
  final setHook = user32.lookupFunction<
      IntPtr Function(
          Int32, Pointer<NativeFunction<_HookProcNative>>, IntPtr, Uint32),
      int Function(int, Pointer<NativeFunction<_HookProcNative>>, int,
          int)>('SetWindowsHookExW');
  final unhook = user32
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'UnhookWindowsHookEx');
  final getModuleHandle = kernel32.lookupFunction<IntPtr Function(Pointer<Uint16>),
      int Function(Pointer<Uint16>)>('GetModuleHandleW');
  final getCurrentThreadId = kernel32
      .lookupFunction<Uint32 Function(), int Function()>('GetCurrentThreadId');
  final getMessage = user32.lookupFunction<
      Int32 Function(Pointer<Uint8>, IntPtr, Uint32, Uint32),
      int Function(Pointer<Uint8>, int, int, int)>('GetMessageW');

  final proc = Pointer.fromFunction<_HookProcNative>(_proc, 0);
  final h = setHook(14, proc, getModuleHandle(nullptr), 0);
  send.send(['hook', h != 0]);
  if (h == 0) return;
  send.send(['tid', getCurrentThreadId()]);
  final msg = calloc<Uint8>(48);
  try {
    while (getMessage(msg, 0, 0, 0) > 0) {}
  } finally {
    send.send(['hits', _hits, _mid]);
    unhook(h);
    calloc.free(msg);
  }
}

Future<void> main() async {
  final log = StringBuffer();
  final rp = ReceivePort();
  var hookOk = false;
  var midSeen = 0;
  var tid = 0;
  rp.listen((m) {
    if (m is! List) return;
    if (m[0] == 'hook') hookOk = m[1] as bool;
    if (m[0] == 'tid') tid = (m[1] as num).toInt();
    if (m[0] == 'mid') midSeen = (m[1] as num).toInt();
    if (m[0] == 'hits') {
      log.writeln('callback が呼ばれた回数 = ${m[1]} (うち中ボタン ${m[2]})');
    }
  });
  await Isolate.spawn(_loop, [rp.sendPort]);
  await Future<void>.delayed(const Duration(milliseconds: 800));
  log.writeln('SetWindowsHookEx 成功 = $hookOk / thread = $tid');

  // 中ボタンの押下/離しを 3 組ぶん流し込む。
  final user32 = DynamicLibrary.open('user32.dll');
  final sendInput = user32.lookupFunction<
      Uint32 Function(Uint32, Pointer<Uint8>, Int32),
      int Function(int, Pointer<Uint8>, int)>('SendInput');
  const inputSize = 40;
  final buf = calloc<Uint8>(inputSize * 2);
  // INPUT_MOUSE(0) / dwFlags は 8+16 = 24 バイト目
  //   MOUSEINPUT: dx(4) dy(4) mouseData(4) dwFlags(4) time(4) extra(8)
  Pointer<Uint32>.fromAddress(buf.address).value = 0;
  Pointer<Uint32>.fromAddress(buf.address + 8 + 12).value = 0x0020; // MDOWN
  Pointer<Uint32>.fromAddress(buf.address + inputSize).value = 0;
  Pointer<Uint32>.fromAddress(buf.address + inputSize + 8 + 12).value =
      0x0040; // MUP
  for (var i = 0; i < 3; i++) {
    sendInput(2, buf, inputSize);
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }
  calloc.free(buf);
  await Future<void>.delayed(const Duration(milliseconds: 400));
  log.writeln('中ボタンを 3 回流し込んだ結果、 受け取った押下/離し = $midSeen '
      '(期待値 6)');

  // WM_QUIT で片付ける。
  final post = user32.lookupFunction<Int32 Function(Uint32, Uint32, IntPtr, IntPtr),
      int Function(int, int, int, int)>('PostThreadMessageW');
  post(tid, 0x0012, 0, 0);
  await Future<void>.delayed(const Duration(milliseconds: 600));
  rp.close();

  final f = File('build/mouse_hook_probe.txt');
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(log.toString());
  stdout.writeln('wrote ${f.path}');
  exit(0);
}
