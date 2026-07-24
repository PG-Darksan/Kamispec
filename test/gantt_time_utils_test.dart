import 'package:flutter_test/flutter_test.dart';
import 'package:mindmap_app/utils/gantt_time_utils.dart';

void main() {
  group('GanttBlockedInterval', () {
    test('supports value equality, labels, and JSON round trips', () {
      const interval = GanttBlockedInterval(startMinute: 60, endMinute: 150);

      expect(interval.label, '01:00–02:30');
      expect(interval.toJson(), <String, int>{'s': 60, 'e': 150});
      expect(
        GanttBlockedInterval.fromJson(interval.toJson()),
        interval,
      );
      expect(
        const GanttBlockedInterval(startMinute: 60, endMinute: 150).hashCode,
        interval.hashCode,
      );
    });

    test('contains uses start-inclusive and end-exclusive boundaries', () {
      const interval =
          GanttBlockedInterval(startMinute: 12 * 60, endMinute: 13 * 60);
      final day = DateTime(2026, 7, 24);

      expect(interval.contains(day.add(const Duration(hours: 12))), isTrue);
      expect(
        interval.contains(
          day.add(const Duration(hours: 12, minutes: 59)),
        ),
        isTrue,
      );
      expect(interval.contains(day.add(const Duration(hours: 13))), isFalse);
    });

    test('contains supports intervals spanning midnight', () {
      const interval =
          GanttBlockedInterval(startMinute: 22 * 60, endMinute: 6 * 60);
      final day = DateTime(2026, 7, 24);

      expect(interval.spansMidnight, isTrue);
      expect(interval.contains(day.add(const Duration(hours: 23))), isTrue);
      expect(interval.contains(day.add(const Duration(hours: 2))), isTrue);
      expect(interval.contains(day.add(const Duration(hours: 6))), isFalse);
      expect(interval.contains(day.add(const Duration(hours: 12))), isFalse);
    });

    test('equal endpoints represent an empty interval', () {
      const interval = GanttBlockedInterval(startMinute: 300, endMinute: 300);

      expect(interval.isEmpty, isTrue);
      expect(interval.contains(DateTime(2026, 7, 24, 5)), isFalse);
      expect(normalizeGanttBlockedIntervals(<GanttBlockedInterval>[interval]),
          isEmpty);
    });

    test('rejects malformed JSON values', () {
      expect(
        () => GanttBlockedInterval.fromJson(
          <String, Object?>{'s': 12.5, 'e': 60},
        ),
        throwsFormatException,
      );
      expect(
        () => GanttBlockedInterval.fromJson(
          <String, Object?>{'s': -1, 'e': 60},
        ),
        throwsFormatException,
      );
      expect(
        () => GanttBlockedInterval.fromJson(
          <String, Object?>{'s': 60, 'e': 1441},
        ),
        throwsFormatException,
      );
    });
  });

  group('normalizeGanttBlockedIntervals', () {
    test('merges overlapping and adjacent intervals', () {
      final normalized = normalizeGanttBlockedIntervals(
        const <GanttBlockedInterval>[
          GanttBlockedInterval(startMinute: 60, endMinute: 120),
          GanttBlockedInterval(startMinute: 90, endMinute: 180),
          GanttBlockedInterval(startMinute: 180, endMinute: 240),
        ],
      );

      expect(
        normalized,
        const <GanttBlockedInterval>[
          GanttBlockedInterval(startMinute: 60, endMinute: 240),
        ],
      );
    });

    test('merges overlap across midnight into one overnight interval', () {
      final normalized = normalizeGanttBlockedIntervals(
        const <GanttBlockedInterval>[
          GanttBlockedInterval(startMinute: 22 * 60, endMinute: 6 * 60),
          GanttBlockedInterval(startMinute: 5 * 60, endMinute: 8 * 60),
        ],
      );

      expect(
        normalized,
        const <GanttBlockedInterval>[
          GanttBlockedInterval(startMinute: 22 * 60, endMinute: 8 * 60),
        ],
      );
    });

    test('joins adjacent ranges across midnight', () {
      final normalized = normalizeGanttBlockedIntervals(
        const <GanttBlockedInterval>[
          GanttBlockedInterval(startMinute: 22 * 60, endMinute: 1440),
          GanttBlockedInterval(startMinute: 0, endMinute: 60),
        ],
      );

      expect(
        normalized,
        const <GanttBlockedInterval>[
          GanttBlockedInterval(startMinute: 22 * 60, endMinute: 60),
        ],
      );
    });

    test('recognizes a normalized full-day interval', () {
      final normalized = normalizeGanttBlockedIntervals(
        const <GanttBlockedInterval>[
          GanttBlockedInterval(startMinute: 0, endMinute: 12 * 60),
          GanttBlockedInterval(startMinute: 12 * 60, endMinute: 1440),
        ],
      );

      expect(
        normalized,
        const <GanttBlockedInterval>[
          GanttBlockedInterval(startMinute: 0, endMinute: 1440),
        ],
      );
    });
  });

  group('ganttTaskSegments', () {
    final day = DateTime(2026, 7, 24);
    final columns = List<DateTime>.generate(
      10,
      (index) => day.add(Duration(hours: 9 + index)),
    );

    test('returns continuous segments around multiple blocked ranges', () {
      final segments = ganttTaskSegments(
        columns: columns,
        start: columns.first,
        end: columns.last,
        blocked: const <GanttBlockedInterval>[
          GanttBlockedInterval(startMinute: 12 * 60, endMinute: 13 * 60),
          GanttBlockedInterval(startMinute: 15 * 60, endMinute: 16 * 60),
        ],
      );

      expect(
        segments,
        const <GanttColumnSegment>[
          GanttColumnSegment(startIndex: 0, endIndexExclusive: 3),
          GanttColumnSegment(startIndex: 4, endIndexExclusive: 6),
          GanttColumnSegment(startIndex: 7, endIndexExclusive: 10),
        ],
      );
      expect(
        ganttActiveColumnCount(
          columns: columns,
          start: columns.first,
          end: columns.last,
          blocked: const <GanttBlockedInterval>[
            GanttBlockedInterval(startMinute: 12 * 60, endMinute: 13 * 60),
            GanttBlockedInterval(startMinute: 15 * 60, endMinute: 16 * 60),
          ],
        ),
        8,
      );
    });

    test('only includes columns inside the inclusive task range', () {
      final segments = ganttTaskSegments(
        columns: columns,
        start: columns[1],
        end: columns[6],
        blocked: const <GanttBlockedInterval>[
          GanttBlockedInterval(startMinute: 12 * 60, endMinute: 13 * 60),
        ],
      );

      expect(
        segments,
        const <GanttColumnSegment>[
          GanttColumnSegment(startIndex: 1, endIndexExclusive: 3),
          GanttColumnSegment(startIndex: 4, endIndexExclusive: 7),
        ],
      );
    });

    test('a partial-minute overlap excludes the whole hourly column', () {
      final segments = ganttTaskSegments(
        columns: columns,
        start: columns.first,
        end: columns[5],
        blocked: const <GanttBlockedInterval>[
          GanttBlockedInterval(
            startMinute: 12 * 60 + 30,
            endMinute: 13 * 60 + 30,
          ),
        ],
      );

      expect(
        segments,
        const <GanttColumnSegment>[
          GanttColumnSegment(startIndex: 0, endIndexExclusive: 3),
          GanttColumnSegment(startIndex: 5, endIndexExclusive: 6),
        ],
      );
      expect(
        isGanttHourColumnBlocked(columns[3], const <GanttBlockedInterval>[
          GanttBlockedInterval(
            startMinute: 12 * 60 + 30,
            endMinute: 13 * 60 + 30,
          ),
        ]),
        isTrue,
      );
      expect(
        isGanttHourColumnBlocked(columns[4], const <GanttBlockedInterval>[
          GanttBlockedInterval(
            startMinute: 12 * 60 + 30,
            endMinute: 13 * 60 + 30,
          ),
        ]),
        isTrue,
      );
    });

    test('returns no segment when the whole task is blocked', () {
      final segments = ganttTaskSegments(
        columns: columns,
        start: columns[2],
        end: columns[4],
        blocked: const <GanttBlockedInterval>[
          GanttBlockedInterval(startMinute: 11 * 60, endMinute: 14 * 60),
        ],
      );

      expect(segments, isEmpty);
      expect(
        ganttActiveColumnCount(
          columns: columns,
          start: columns[2],
          end: columns[4],
          blocked: const <GanttBlockedInterval>[
            GanttBlockedInterval(startMinute: 11 * 60, endMinute: 14 * 60),
          ],
        ),
        0,
      );
    });

    test('splits columns correctly for an overnight blocked interval', () {
      final overnightColumns = List<DateTime>.generate(
        11,
        (index) => DateTime(2026, 7, 24, 21).add(Duration(hours: index)),
      );

      final segments = ganttTaskSegments(
        columns: overnightColumns,
        start: overnightColumns.first,
        end: overnightColumns.last,
        blocked: const <GanttBlockedInterval>[
          GanttBlockedInterval(startMinute: 22 * 60, endMinute: 6 * 60),
        ],
      );

      expect(
        segments,
        const <GanttColumnSegment>[
          GanttColumnSegment(startIndex: 0, endIndexExclusive: 1),
          GanttColumnSegment(startIndex: 9, endIndexExclusive: 11),
        ],
      );
      expect(
        ganttActiveColumnCount(
          columns: overnightColumns,
          start: overnightColumns.first,
          end: overnightColumns.last,
          blocked: const <GanttBlockedInterval>[
            GanttBlockedInterval(startMinute: 22 * 60, endMinute: 6 * 60),
          ],
        ),
        3,
      );
    });

    test('returns an empty result for an invalid task range', () {
      expect(
        ganttTaskSegments(
          columns: columns,
          start: columns[5],
          end: columns[2],
          blocked: const <GanttBlockedInterval>[],
        ),
        isEmpty,
      );
    });
  });
}
