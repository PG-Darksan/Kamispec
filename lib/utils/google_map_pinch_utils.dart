import 'dart:math' as math;

/// Whether [rawUrl] is a Google Maps or Google Earth page.
///
/// Google frequently redirects Maps to a country-specific domain such as
/// `google.co.jp`, so matching only `*.google.com` is not sufficient.
bool isGoogleMapOrEarthUrl(String rawUrl) {
  final uri = Uri.tryParse(rawUrl);
  if (uri == null ||
      (uri.scheme != 'https' && uri.scheme != 'http') ||
      uri.host.isEmpty) {
    return false;
  }

  final host = uri.host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
  final path = uri.path.toLowerCase();
  final googleHost = RegExp(
    r'(^|\.)google\.(?:com|[a-z]{2,3}|co\.[a-z]{2}|com\.[a-z]{2})$',
  ).hasMatch(host);
  if (!googleHost) return false;

  final firstLabel = host.split('.').first;
  return firstLabel == 'maps' ||
      firstLabel == 'earth' ||
      path == '/maps' ||
      path.startsWith('/maps/');
}

/// Converts cumulative trackpad scale updates into discrete map zoom steps.
///
/// Flutter's [PointerPanZoomUpdateEvent.scale] is cumulative from the start
/// of a gesture. Ratios between successive samples are accumulated in log
/// space, making zoom-in and zoom-out symmetric. Roughly eight percent scale
/// change produces one Google Maps/Earth zoom step.
({int steps, double remainder}) accumulateGoogleMapZoomSteps({
  required double previousScale,
  required double currentScale,
  required double remainder,
  double scalePerStep = 1.08,
  int maxStepsPerUpdate = 4,
}) {
  if (!previousScale.isFinite ||
      !currentScale.isFinite ||
      !remainder.isFinite ||
      previousScale <= 0 ||
      currentScale <= 0 ||
      !scalePerStep.isFinite ||
      scalePerStep <= 1 ||
      maxStepsPerUpdate < 1) {
    return (steps: 0, remainder: 0);
  }

  var nextRemainder =
      remainder + math.log(currentScale / previousScale);
  final threshold = math.log(scalePerStep);
  var steps = (nextRemainder / threshold).truncate();
  steps = steps.clamp(-maxStepsPerUpdate, maxStepsPerUpdate);
  nextRemainder -= steps * threshold;
  return (steps: steps, remainder: nextRemainder);
}
