import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/ink.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/recognition/recognizer.dart';
import 'package:writing_recogniser/core/stroke_grouping.dart';
import 'package:writing_recogniser/recognition/jiix.dart';
import 'package:writing_recogniser/viewer/ink_text_controller.dart';

PageStroke letter(double x, double y, int t) => PageStroke(
  points: [
    PageInkPoint(x, y, t),
    PageInkPoint(x + 3, y + 10, t + 40),
    PageInkPoint(x + 6, y, t + 80),
  ],
);

/// "w o r d" with gaps of 8 pt between letters 10 pt high: today's rules
/// cut it into pieces (a gap over 6 pt starts a new word).
List<PageStroke> spaced(double x, int n, int t, {double step = 14}) => [
  for (var i = 0; i < n; i++) letter(x + i * step, 700, t + i * 200),
];

/// Reads a whole line as one word ("line" and its number of strokes), or can't
/// ([lines] false: null, so words are read one by one).
class FakeLineEngine implements Recognizer, LineRecognizer {
  FakeLineEngine({this.lines = true});
  final bool lines;
  final lineCalls = <List<InkStroke>>[];
  final wordCalls = <List<InkStroke>>[];

  @override
  String get name => 'Fake';
  @override
  bool get onDevice => true;
  @override
  Future<RecognizerStatus> status() async =>
      const RecognizerStatus(RecognizerState.ready);
  @override
  Future<void> prepare({void Function(double? progress)? onProgress}) async {}
  @override
  Future<List<Candidate>> recognize(
    List<InkStroke> strokes,
    RecognitionContext context,
  ) async {
    wordCalls.add(strokes);
    return [Candidate('w${strokes.length}')];
  }

  @override
  Future<List<LineWord>?> recognizeLine(
    List<InkStroke> strokes,
    RecognitionContext context,
  ) async {
    lineCalls.add(strokes);
    if (!lines) return null;
    return [
      LineWord(
        ['line${strokes.length}', 'other'],
        [for (var i = 0; i < strokes.length; i++) i],
      ),
    ];
  }
}

void main() {
  const pause = Duration(milliseconds: 500);

  testWidgets('a whole line goes to the engine, which says where words are', (
    tester,
  ) async {
    final engine = FakeLineEngine();
    final c = InkTextController(engine: engine);
    final page = spaced(100, 4, 0);
    // Today's rules alone would cut this into several words.
    expect(groupStrokes(page).single.words.length, greaterThan(1));
    c.inkChanged(1, page, pause);
    await tester.pump(pause);
    await tester.pumpAndSettle();
    expect(engine.lineCalls, hasLength(1));
    expect(engine.wordCalls, isEmpty);
    expect(c.wordsOn(1).map((w) => w.text), ['line4']);
    expect(c.wordsOn(1).single.alternatives, ['other']);
    // Nothing changed: not read again (the engine's words are kept).
    c.inkChanged(1, [...page], pause);
    await tester.pump(pause);
    await tester.pumpAndSettle();
    expect(engine.lineCalls, hasLength(1));
    // More writing on the line: the whole line is read again.
    c.inkChanged(1, [...page, letter(156, 700, 9000)], pause);
    await tester.pump(pause);
    await tester.pumpAndSettle();
    expect(engine.lineCalls, hasLength(2));
    expect(c.wordsOn(1).map((w) => w.text), ['line5']);
    c.dispose();
  });

  testWidgets('if the engine can\'t read the line, words are read one by one', (
    tester,
  ) async {
    final engine = FakeLineEngine(lines: false);
    final c = InkTextController(engine: engine);
    c.inkChanged(1, spaced(100, 3, 0, step: 7), pause);
    await tester.pump(pause);
    await tester.pumpAndSettle();
    expect(engine.lineCalls, hasLength(1));
    expect(engine.wordCalls, hasLength(1));
    expect(c.wordsOn(1).map((w) => w.text), ['w3']);
    c.dispose();
  });

  testWidgets('strokes marked "One word" stay one word', (tester) async {
    final engine = _SplitEngine();
    final c = InkTextController(engine: engine);
    final page = [
      for (final s in spaced(100, 4, 0)) s.copyWith(manualWord: 'm'),
    ];
    c.inkChanged(1, page, pause);
    await tester.pump(pause);
    await tester.pumpAndSettle();
    expect(c.wordsOn(1).map((w) => w.text), ['abcd']);
    c.dispose();
  });

  testWidgets('strokes marked as a sentence are read in one go, even '
      'written on two lines', (tester) async {
    final engine = FakeLineEngine();
    final c = InkTextController(engine: engine);
    final page = [
      ...spaced(100, 2, 0),
      // A second line, below.
      for (var i = 0; i < 2; i++) letter(100 + i * 14.0, 660, 2000 + i * 200),
    ];
    final marked = [for (final s in page) s.copyWith(manualLine: 'm')];
    c.inkChanged(1, marked, pause);
    await tester.pump(pause);
    await tester.pumpAndSettle();
    expect(engine.lineCalls.map((l) => l.length), [4]);
    c.dispose();
  });

  testWidgets('writing already read is read again as one sentence once '
      'marked', (tester) async {
    final engine = FakeLineEngine();
    final c = InkTextController(engine: engine);
    final page = [
      ...spaced(100, 2, 0),
      for (var i = 0; i < 2; i++) letter(100 + i * 14.0, 660, 2000 + i * 200),
    ];
    c.inkChanged(1, page, pause);
    await tester.pump(pause);
    await tester.pumpAndSettle();
    expect(engine.lineCalls.map((l) => l.length), [2, 2]);
    // Marked as one sentence: the words go and are read again together.
    final ids = {for (final s in page) s.id};
    c.readAgain(1, ids);
    final marked = [for (final s in page) s.copyWith(manualLine: 'm')];
    c.inkChanged(1, marked, pause);
    await tester.pump(pause);
    await tester.pumpAndSettle();
    expect(engine.lineCalls.map((l) => l.length), [2, 2, 4]);
    expect(c.wordsOn(1), hasLength(1));
    c.dispose();
  });

  test('the engine\'s words are matched to strokes by their boxes', () {
    // Two strokes on the left, one on the right; 0.5 mm per point.
    const strokes = [
      InkStroke([InkPoint(0, 0, 0), InkPoint(10, 20, 1)]),
      InkStroke([InkPoint(12, 0, 2), InkPoint(20, 20, 3)]),
      InkStroke([InkPoint(60, 0, 4), InkPoint(80, 20, 5)]),
    ];
    final words = jiixLineWords(
      {
        'label': 'hi you',
        'words': [
          {
            'label': 'hi',
            'candidates': ['hi', 'hl'],
            'bounding-box': {'x': 0, 'y': 0, 'width': 10, 'height': 10},
          },
          {'label': ' '},
          {
            'label': 'you',
            'bounding-box': {'x': 30, 'y': 0, 'width': 10, 'height': 10},
          },
        ],
      },
      strokes,
      mmPerX: 0.5,
      mmPerY: 0.5,
    )!;
    expect(words.map((w) => w.candidates.first), ['hi', 'you']);
    expect(words.first.candidates, ['hi', 'hl']);
    expect(words.map((w) => w.strokes), [
      [0, 1],
      [2],
    ]);
    // No boxes in the answer: can't match, so null (read word by word).
    expect(
      jiixLineWords(
        {
          'words': [
            {'label': 'hi'},
          ],
        },
        strokes,
        mmPerX: 0.5,
        mmPerY: 0.5,
      ),
      isNull,
    );
  });

  test('grouping keeps words the engine found', () {
    final page = spaced(100, 4, 0);
    final hints = {for (final s in page) s.id: 'one'};
    final words = groupStrokes(page, hints: hints).single.words;
    expect(words.single.strokes, [0, 1, 2, 3]);
    // A new stroke without a hint is a word of its own.
    final more = [...page, letter(170, 700, 9000)];
    expect(groupStrokes(more, hints: hints).single.words, hasLength(2));
  });

  testWidgets('a corrected word survives its line being read again', (
    tester,
  ) async {
    final engine = _SplitEngine();
    final c = InkTextController(engine: engine);
    final page = spaced(100, 2, 0);
    c.inkChanged(1, page, pause);
    await tester.pump(pause);
    await tester.pumpAndSettle();
    await c.correct(1, c.wordsOn(1).first, 'hello');
    c.inkChanged(1, [...page, letter(128, 700, 9000)], pause);
    await tester.pump(pause);
    await tester.pumpAndSettle();
    expect(c.wordsOn(1).map((w) => w.text), ['hello', 'b', 'c']);
    expect(c.wordsOn(1).first.corrected, isTrue);
    c.dispose();
  });

  testWidgets('a page read word by word before is read once more by line', (
    tester,
  ) async {
    final engine = FakeLineEngine();
    final c = InkTextController(engine: engine);
    final page = spaced(100, 4, 0);
    // Saved by an older version: pieces read one by one.
    final pieces = groupStrokes(page).single.words;
    c.restore(
      1,
      jsonEncode({
        'seen': [for (final s in page) s.id],
        'words': [
          for (final w in pieces)
            RecognizedWord(
              text: 'gib',
              alternatives: const [],
              box: w.box,
              line: 0,
              key: [for (final i in w.strokes) page[i].id].join(','),
            ).toJson(),
        ],
      }),
    );
    c.inkChanged(1, page, pause);
    await tester.pump(pause);
    await tester.pumpAndSettle();
    expect(engine.lineCalls, hasLength(1));
    expect(c.wordsOn(1).map((w) => w.text), ['line4']);
    // And only once.
    c.inkChanged(1, [...page], pause);
    await tester.pump(pause);
    await tester.pumpAndSettle();
    expect(engine.lineCalls, hasLength(1));
    c.dispose();
  });

  testWidgets('an unsound answer is ignored: words are read one by one', (
    tester,
  ) async {
    final engine = _BrokenEngine();
    final c = InkTextController(engine: engine);
    c.inkChanged(1, spaced(100, 3, 0, step: 7), pause);
    await tester.pump(pause);
    await tester.pumpAndSettle();
    expect(engine.wordCalls, hasLength(1));
    expect(c.wordsOn(1).map((w) => w.text), ['w3']);
    c.dispose();
  });

  test('boxes in other units are fitted onto the ink', () {
    const strokes = [
      InkStroke([InkPoint(0, 0, 0), InkPoint(10, 20, 1)]),
      InkStroke([InkPoint(60, 0, 4), InkPoint(80, 20, 5)]),
    ];
    // Boxes ten times too big, and moved: still matched by position.
    final words = jiixLineWords(
      {
        'words': [
          {
            'label': 'a',
            'bounding-box': {'x': 500, 'y': 500, 'width': 50, 'height': 100},
          },
          {
            'label': 'b',
            'bounding-box': {'x': 800, 'y': 500, 'width': 100, 'height': 100},
          },
        ],
      },
      strokes,
      mmPerX: 0.5,
      mmPerY: 0.5,
    )!;
    expect(words.map((w) => w.strokes), [
      [0],
      [1],
    ]);
  });
}

/// Answers with a word that has no strokes and one with a stroke that
/// isn't there.
class _BrokenEngine extends FakeLineEngine {
  @override
  Future<List<LineWord>?> recognizeLine(
    List<InkStroke> strokes,
    RecognitionContext context,
  ) async {
    lineCalls.add(strokes);
    return [
      const LineWord(['x'], []),
      const LineWord(['y'], [0, 99]),
    ];
  }
}

/// Splits a line into one word per stroke, reading them "a", "b", ...
class _SplitEngine extends FakeLineEngine {
  @override
  Future<List<LineWord>?> recognizeLine(
    List<InkStroke> strokes,
    RecognitionContext context,
  ) async => [
    for (var i = 0; i < strokes.length; i++)
      LineWord([String.fromCharCode(97 + i)], [i]),
  ];
}
