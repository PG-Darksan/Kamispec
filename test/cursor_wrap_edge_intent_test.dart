@TestOn('windows')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mindmap_app/services/cursor_wrap.dart';

/// 端に着いた時に飛ばすかどうかの判定 (= ユーザー要望「サブモニターに送るまでの
/// 時間が掛かり過ぎている」 で待ちを 220ms → 90ms に縮めた分、 意図せず
/// 「触れた瞬間に飛ぶ」 (b334 で直した不具合) へ戻していないかを確かめる)。
void main() {
  const fast = 2500.0; // 画面の外へ振り抜く動き
  const slow = 250.0; // ✕ を狙って止まりに行く動き

  group('勢い', () {
    test('勢いよく向かって来たら待たない', () {
      expect(
          CursorWrap.shouldRouteAtEdge(
              heldFor: Duration.zero,
              approachSpeed: fast,
              movingWindow: false),
          isTrue);
    });

    test('ゆっくり近付いた時は、 触れただけでは飛ばさない', () {
      expect(
          CursorWrap.shouldRouteAtEdge(
              heldFor: Duration.zero,
              approachSpeed: slow,
              movingWindow: false),
          isFalse);
      // 8ms 見回りの 1〜2 回分では、 まだ飛ばない。
      expect(
          CursorWrap.shouldRouteAtEdge(
              heldFor: const Duration(milliseconds: 16),
              approachSpeed: slow,
              movingWindow: false),
          isFalse);
    });

    test('ゆっくりでも押し当て続ければ飛ぶ', () {
      expect(
          CursorWrap.shouldRouteAtEdge(
              heldFor: const Duration(milliseconds: 90),
              approachSpeed: slow,
              movingWindow: false),
          isTrue);
    });

    test('待ちは b334 の 220ms より短くなっている', () {
      expect(
          CursorWrap.shouldRouteAtEdge(
              heldFor: const Duration(milliseconds: 120),
              approachSpeed: 0,
              movingWindow: false),
          isTrue);
    });
  });

  group('✕ へ向かっていそうな所', () {
    // ★ = 点検で判明した戻り: 「勢いよく向かって来たら待たない」 を足した
    //   事で、 ✕ を狙う動きでも即座に飛ぶようになっていた (= ユーザーが
    //   b334 で出した不具合そのもの)。
    test('勢いよく向かって来ても飛ばさない', () {
      expect(
          CursorWrap.shouldRouteAtEdge(
              heldFor: Duration.zero,
              approachSpeed: fast,
              movingWindow: false,
              nearCaption: true),
          isFalse);
    });

    test('普通の待ち (90ms) では、 まだ飛ばない', () {
      expect(
          CursorWrap.shouldRouteAtEdge(
              heldFor: const Duration(milliseconds: 90),
              approachSpeed: fast,
              movingWindow: false,
              nearCaption: true),
          isFalse);
    });

    test('b335 と同じだけ (220ms) 押し当てれば飛ぶ', () {
      expect(
          CursorWrap.shouldRouteAtEdge(
              heldFor: const Duration(milliseconds: 220),
              approachSpeed: 0,
              movingWindow: false,
              nearCaption: true),
          isTrue);
    });
  });

  group('窓を運んでいる時', () {
    test('勢いでは飛ばさない (端へ寄せて貼る操作を奪わない)', () {
      expect(
          CursorWrap.shouldRouteAtEdge(
              heldFor: Duration.zero, approachSpeed: fast, movingWindow: true),
          isFalse);
    });

    test('カーソルだけの時より長く押し当てる必要がある', () {
      expect(
          CursorWrap.shouldRouteAtEdge(
              heldFor: const Duration(milliseconds: 100),
              approachSpeed: fast,
              movingWindow: true),
          isFalse);
      expect(
          CursorWrap.shouldRouteAtEdge(
              heldFor: const Duration(milliseconds: 350),
              approachSpeed: 0,
              movingWindow: true),
          isTrue);
    });
  });

  group('どの辺へ向かっているか', () {
    // vx, vy は右/下を正とする。
    test('右へ動いていれば R だけが速い', () {
      expect(CursorWrap.approachSpeedFor('R', 2000, 0, 0, 0), 2000);
      // 右へ動いているのだから、 左へ向かう速さは正にならない。
      expect(CursorWrap.approachSpeedFor('L', 2000, 0, 0, 0),
          lessThanOrEqualTo(0.0));
      expect(CursorWrap.approachSpeedFor('T', 2000, 0, 0, 0), 0);
    });

    test('左/上は符号が逆', () {
      expect(CursorWrap.approachSpeedFor('L', -1800, 0, 0, 0), 1800);
      expect(CursorWrap.approachSpeedFor('T', 0, -1800, 0, 0), 1800);
      expect(CursorWrap.approachSpeedFor('B', 0, 1800, 0, 0), 1800);
    });

    test('縁で止められて最後の差が縮んでも、 1 つ前の回で拾える', () {
      // 着いた回は 3 画素分しか動けていない (= 30 画素/秒 相当) が、
      // 1 つ前の回は 3000 画素/秒 だった。
      expect(CursorWrap.approachSpeedFor('R', 30, 0, 3000, 0), 3000);
      expect(
          CursorWrap.shouldRouteAtEdge(
              heldFor: Duration.zero,
              approachSpeed: CursorWrap.approachSpeedFor('R', 30, 0, 3000, 0),
              movingWindow: false),
          isTrue);
    });

    test('知らない辺は 0', () {
      expect(CursorWrap.approachSpeedFor('X', 9999, 9999, 9999, 9999), 0);
    });
  });
}
