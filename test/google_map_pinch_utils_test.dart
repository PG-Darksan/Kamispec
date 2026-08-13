import 'package:flutter_test/flutter_test.dart';
import 'package:mindmap_app/utils/google_map_pinch_utils.dart';

void main() {
  group('isGoogleMapOrEarthUrl', () {
    test('recognizes Maps and Earth on global and country domains', () {
      expect(
        isGoogleMapOrEarthUrl('https://www.google.com/maps/place/Tokyo'),
        isTrue,
      );
      expect(
        isGoogleMapOrEarthUrl('https://maps.google.co.jp/?q=Tokyo'),
        isTrue,
      );
      expect(
        isGoogleMapOrEarthUrl('https://earth.google.com/web/'),
        isTrue,
      );
      expect(
        isGoogleMapOrEarthUrl('https://www.google.de/maps'),
        isTrue,
      );
    });

    test('does not affect normal or lookalike pages', () {
      expect(isGoogleMapOrEarthUrl('https://www.google.com/search?q=map'),
          isFalse);
      expect(isGoogleMapOrEarthUrl('https://google.example/maps'), isFalse);
      expect(isGoogleMapOrEarthUrl('not a url'), isFalse);
    });
  });

  group('accumulateGoogleMapZoomSteps', () {
    test('accumulates small scale changes before emitting a step', () {
      final first = accumulateGoogleMapZoomSteps(
        previousScale: 1,
        currentScale: 1.04,
        remainder: 0,
      );
      expect(first.steps, 0);

      final second = accumulateGoogleMapZoomSteps(
        previousScale: 1.04,
        currentScale: 1.09,
        remainder: first.remainder,
      );
      expect(second.steps, 1);
      expect(second.remainder.abs(), lessThan(mathLog108));
    });

    test('uses opposite signs for zoom in and zoom out', () {
      expect(
        accumulateGoogleMapZoomSteps(
          previousScale: 1,
          currentScale: 1.2,
          remainder: 0,
        ).steps,
        greaterThan(0),
      );
      expect(
        accumulateGoogleMapZoomSteps(
          previousScale: 1,
          currentScale: 0.8,
          remainder: 0,
        ).steps,
        lessThan(0),
      );
    });

    test('rejects invalid scale input', () {
      expect(
        accumulateGoogleMapZoomSteps(
          previousScale: 0,
          currentScale: 1,
          remainder: 3,
        ),
        (steps: 0, remainder: 0),
      );
    });
  });
}

const double mathLog108 = 0.0769610411361284;
