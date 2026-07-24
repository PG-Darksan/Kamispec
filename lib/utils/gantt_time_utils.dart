/// Pure time calculations used by the Gantt chart.
///
/// A blocked interval repeats every day. Its start is inclusive and its end is
/// exclusive. For example, `12:00-13:00` blocks 12:00 but not 13:00.
class GanttBlockedInterval {
  /// Minutes since midnight in the range 0 through 1439.
  final int startMinute;

  /// Minutes since midnight in the range 0 through 1440.
  ///
  /// `1440` is accepted so that an interval can end explicitly at 24:00.
  final int endMinute;

  const GanttBlockedInterval({
    required this.startMinute,
    required this.endMinute,
  })  : assert(startMinute >= 0 && startMinute < _minutesPerDay),
        assert(endMinute >= 0 && endMinute <= _minutesPerDay);

  factory GanttBlockedInterval.fromJson(Map<Object?, Object?> json) {
    final start = _readJsonMinute(json, 's');
    final end = _readJsonMinute(json, 'e');
    if (start < 0 || start >= _minutesPerDay) {
      throw FormatException(
        'Blocked interval start must be between 0 and 1439: $start',
      );
    }
    if (end < 0 || end > _minutesPerDay) {
      throw FormatException(
        'Blocked interval end must be between 0 and 1440: $end',
      );
    }
    return GanttBlockedInterval(startMinute: start, endMinute: end);
  }

  /// Whether this interval continues through midnight into the next day.
  bool get spansMidnight => startMinute > endMinute;

  /// Equal endpoints represent an empty interval, not an all-day interval.
  bool get isEmpty => startMinute == endMinute;

  /// A compact, locale-neutral label suitable for the current Gantt UI.
  String get label =>
      '${_formatMinute(startMinute)}–${_formatMinute(endMinute)}';

  /// Whether [value] falls in this daily recurring interval.
  bool contains(DateTime value) {
    if (isEmpty) return false;
    final minute = value.hour * 60 + value.minute;
    if (spansMidnight) {
      return minute >= startMinute || minute < endMinute;
    }
    return minute >= startMinute && minute < endMinute;
  }

  Map<String, int> toJson() => <String, int>{
        's': startMinute,
        'e': endMinute,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GanttBlockedInterval &&
          startMinute == other.startMinute &&
          endMinute == other.endMinute;

  @override
  int get hashCode => Object.hash(startMinute, endMinute);

  @override
  String toString() => 'GanttBlockedInterval($label)';
}

/// A contiguous run of effective columns in the Gantt time axis.
///
/// [startIndex] is inclusive and [endIndexExclusive] is exclusive, so the
/// values can be used directly for bar placement:
///
/// `left = startIndex * columnWidth`
/// `width = columnCount * columnWidth`
class GanttColumnSegment {
  final int startIndex;
  final int endIndexExclusive;

  const GanttColumnSegment({
    required this.startIndex,
    required this.endIndexExclusive,
  })  : assert(startIndex >= 0),
        assert(endIndexExclusive >= startIndex);

  int get columnCount => endIndexExclusive - startIndex;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GanttColumnSegment &&
          startIndex == other.startIndex &&
          endIndexExclusive == other.endIndexExclusive;

  @override
  int get hashCode => Object.hash(startIndex, endIndexExclusive);

  @override
  String toString() => 'GanttColumnSegment($startIndex, $endIndexExclusive)';
}

/// Merges overlapping and adjacent blocked intervals into a canonical list.
///
/// Overnight intervals are expanded for merging and are joined back across
/// midnight when possible. Empty intervals are discarded. The returned list
/// is sorted by [GanttBlockedInterval.startMinute].
List<GanttBlockedInterval> normalizeGanttBlockedIntervals(
  Iterable<GanttBlockedInterval> intervals,
) {
  final expanded = <_MinuteRange>[];
  for (final interval in intervals) {
    expanded.addAll(_expandBlockedInterval(interval));
  }
  if (expanded.isEmpty) return const <GanttBlockedInterval>[];

  expanded.sort((a, b) {
    final byStart = a.start.compareTo(b.start);
    return byStart != 0 ? byStart : a.end.compareTo(b.end);
  });

  final merged = <_MinuteRange>[];
  for (final next in expanded) {
    if (merged.isEmpty || next.start > merged.last.end) {
      merged.add(next);
      continue;
    }
    final current = merged.removeLast();
    merged.add(_MinuteRange(current.start, _max(current.end, next.end)));
  }

  if (merged.length == 1 &&
      merged.single.start == 0 &&
      merged.single.end == _minutesPerDay) {
    return const <GanttBlockedInterval>[
      GanttBlockedInterval(startMinute: 0, endMinute: _minutesPerDay),
    ];
  }

  final normalized = <GanttBlockedInterval>[];
  final joinsAcrossMidnight = merged.length >= 2 &&
      merged.first.start == 0 &&
      merged.last.end == _minutesPerDay;

  if (joinsAcrossMidnight) {
    for (var i = 1; i < merged.length - 1; i++) {
      normalized.add(
        GanttBlockedInterval(
          startMinute: merged[i].start,
          endMinute: merged[i].end,
        ),
      );
    }
    normalized.add(
      GanttBlockedInterval(
        startMinute: merged.last.start,
        endMinute: merged.first.end,
      ),
    );
  } else {
    for (final range in merged) {
      normalized.add(
        GanttBlockedInterval(
          startMinute: range.start,
          endMinute: range.end,
        ),
      );
    }
  }

  normalized.sort((a, b) => a.startMinute.compareTo(b.startMinute));
  return List<GanttBlockedInterval>.unmodifiable(normalized);
}

/// Returns whether the one-hour column starting at [column] overlaps a blocked
/// interval.
///
/// Because the chart is currently hour-based, even a partial overlap excludes
/// the whole column. Thus a `12:30-13:30` interval excludes both the 12:00 and
/// 13:00 columns.
bool isGanttHourColumnBlocked(
  DateTime column,
  Iterable<GanttBlockedInterval> blocked,
) {
  final normalized = normalizeGanttBlockedIntervals(blocked);
  return _isHourColumnBlockedByNormalized(column, normalized);
}

/// Builds the effective contiguous bar segments for a task.
///
/// [columns] are the hour starts shown by the Gantt axis. [start] and [end]
/// are both inclusive to match the current Gantt task storage and rendering
/// semantics. Columns outside the task or overlapping a blocked interval are
/// omitted. Remaining adjacent column indexes are coalesced into segments.
List<GanttColumnSegment> ganttTaskSegments({
  required List<DateTime> columns,
  required DateTime start,
  required DateTime end,
  required Iterable<GanttBlockedInterval> blocked,
}) {
  if (columns.isEmpty || end.isBefore(start)) {
    return const <GanttColumnSegment>[];
  }

  final normalized = normalizeGanttBlockedIntervals(blocked);
  final result = <GanttColumnSegment>[];
  int? runStart;

  for (var i = 0; i < columns.length; i++) {
    final column = columns[i];
    final insideTask = !column.isBefore(start) && !column.isAfter(end);
    final active =
        insideTask && !_isHourColumnBlockedByNormalized(column, normalized);

    if (active) {
      runStart ??= i;
    } else if (runStart != null) {
      result.add(
        GanttColumnSegment(startIndex: runStart, endIndexExclusive: i),
      );
      runStart = null;
    }
  }

  if (runStart != null) {
    result.add(
      GanttColumnSegment(
        startIndex: runStart,
        endIndexExclusive: columns.length,
      ),
    );
  }

  return List<GanttColumnSegment>.unmodifiable(result);
}

/// Counts task columns left after removing all blocked time.
int ganttActiveColumnCount({
  required List<DateTime> columns,
  required DateTime start,
  required DateTime end,
  required Iterable<GanttBlockedInterval> blocked,
}) =>
    ganttTaskSegments(
      columns: columns,
      start: start,
      end: end,
      blocked: blocked,
    ).fold(0, (total, segment) => total + segment.columnCount);

const int _minutesPerDay = 24 * 60;

class _MinuteRange {
  final int start;
  final int end;

  const _MinuteRange(this.start, this.end);
}

List<_MinuteRange> _expandBlockedInterval(
  GanttBlockedInterval interval,
) {
  if (interval.isEmpty) return const <_MinuteRange>[];
  if (!interval.spansMidnight) {
    return <_MinuteRange>[
      _MinuteRange(interval.startMinute, interval.endMinute),
    ];
  }
  return <_MinuteRange>[
    if (interval.endMinute > 0) _MinuteRange(0, interval.endMinute),
    _MinuteRange(interval.startMinute, _minutesPerDay),
  ];
}

bool _isHourColumnBlockedByNormalized(
  DateTime column,
  List<GanttBlockedInterval> normalized,
) {
  if (normalized.isEmpty) return false;
  final start = column.hour * 60 + column.minute;
  final end = start + 60;
  final columnRanges = end <= _minutesPerDay
      ? <_MinuteRange>[_MinuteRange(start, end)]
      : <_MinuteRange>[
          _MinuteRange(start, _minutesPerDay),
          _MinuteRange(0, end - _minutesPerDay),
        ];

  for (final interval in normalized) {
    for (final blockedRange in _expandBlockedInterval(interval)) {
      for (final columnRange in columnRanges) {
        if (columnRange.start < blockedRange.end &&
            blockedRange.start < columnRange.end) {
          return true;
        }
      }
    }
  }
  return false;
}

int _readJsonMinute(Map<Object?, Object?> json, String key) {
  final value = json[key];
  if (value is! num || !value.isFinite || value != value.roundToDouble()) {
    throw FormatException('Blocked interval "$key" must be an integer.');
  }
  return value.toInt();
}

String _formatMinute(int minute) {
  if (minute == _minutesPerDay) return '24:00';
  final hour = minute ~/ 60;
  final min = minute % 60;
  return '${hour.toString().padLeft(2, '0')}:'
      '${min.toString().padLeft(2, '0')}';
}

int _max(int a, int b) => a > b ? a : b;
