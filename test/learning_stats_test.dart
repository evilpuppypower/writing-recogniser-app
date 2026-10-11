import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/event_log.dart';
import 'package:writing_recogniser/core/learning_stats.dart';

LoggedEvent read(
  String word,
  DateTime at, {
  required String engine,
  String? shown,
  bool swapped = false,
  int latency = 400,
}) => LoggedEvent(
  type: 'recognition',
  at: at,
  latencyMs: latency,
  data: {
    'page': 1,
    'doc': 'd',
    'word': word,
    'engineText': engine,
    'text': shown ?? engine,
    'autoReplaced': swapped,
  },
);

LoggedEvent fix(String word, DateTime at, String to, {bool undo = false}) =>
    LoggedEvent(
      type: 'correction',
      at: at,
      data: {
        'page': 1,
        'doc': 'd',
        'word': word,
        'corrected': to,
        'undo': undo,
      },
    );

void main() {
  // Monday 5 Jan 2026, and the Monday after.
  final week1 = DateTime(2026, 1, 5, 12);
  final week2 = DateTime(2026, 1, 12, 12);

  test('engine alone vs with corrections, repeated words, swaps', () {
    final s = LearningStats.fromEvents([
      // Week 1: "moved" misread as "mad" and corrected; "the" right.
      read('a', week1, engine: 'mad'),
      fix('a', week1.add(const Duration(seconds: 5)), 'moved'),
      read('b', week1.add(const Duration(minutes: 1)), engine: 'the'),
      // Week 2: "moved" misread again, but swapped and kept.
      read(
        'c',
        week2,
        engine: 'mad',
        shown: 'moved',
        swapped: true,
        latency: 600,
      ),
      // A swap the user undid: the engine was right.
      read(
        'd',
        week2.add(const Duration(minutes: 1)),
        engine: 'made',
        shown: 'moved',
        swapped: true,
      ),
      fix('d', week2.add(const Duration(minutes: 2)), 'made', undo: true),
    ]);

    expect(s.words, hasLength(4));
    // Engine alone got "a" and "c" wrong; shown got "a" and "d" wrong.
    expect(s.engineAlone.wrongWords, 2);
    expect(s.withCorrections.wrongWords, 2);
    // Repeated words: only "c" ("moved" again). Engine wrong, shown right.
    expect(s.repeatedWords, hasLength(1));
    expect(s.repeatedImprovement, 1.0);
    expect((s.swaps, s.swapsUndone), (2, 1));
    expect(s.medianLatencyMs, 400);
    expect(
      [for (final w in s.weeks) (w.words, w.corrections)],
      [(2, 1), (2, 1)],
    );
    expect(s.weeks.first.correctionsPer100, 50);
  });

  test('"not writing" removes a word; old entries without ids are skipped', () {
    final s = LearningStats.fromEvents([
      read('a', week1, engine: 'tick'),
      LoggedEvent(
        type: 'not_writing',
        at: week1.add(const Duration(seconds: 3)),
        data: const {'page': 1, 'doc': 'd', 'word': 'a'},
      ),
      LoggedEvent(type: 'recognition', at: week1, data: const {'text': 'old'}),
    ]);
    expect(s.words, isEmpty);
    expect(s.weeks.single.words, 0);
    expect(s.repeatedImprovement, isNull);
    expect(s.medianLatencyMs, isNull);
  });

  test('a word read again counts once, with its newest reading', () {
    final s = LearningStats.fromEvents([
      read('a', week1, engine: 'cat'),
      read('a', week1.add(const Duration(seconds: 9)), engine: 'cart'),
    ]);
    expect(s.words.single.engine, 'cart');
    expect(s.weeks.single.words, 1, reason: 'counted once');
  });

  test('CSV: one row per word, quoted where needed', () {
    final s = LearningStats.fromEvents([
      read('a', week1, engine: 'hello, world'),
    ]);
    final lines = s.toCsv().trim().split('\n');
    expect(lines, hasLength(2));
    expect(lines.first, startsWith('time,engine read,shown,final'));
    expect(lines.last, contains('"hello, world"'));
    expect(lines.last, startsWith('2026-01-05 12:00:00'));
  });
}
