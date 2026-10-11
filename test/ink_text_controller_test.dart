import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/page_coordinates.dart';
import 'package:writing_recogniser/core/event_log.dart';
import 'package:writing_recogniser/core/feedback/correction.dart';
import 'package:writing_recogniser/core/feedback/correction_store.dart';
import 'package:writing_recogniser/core/ink.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/recognition/recognizer.dart';
import 'package:writing_recogniser/viewer/ink_text_controller.dart';
import 'package:writing_recogniser/viewer/page_text_labels.dart';

PageStroke letter(double x, double y, int t) => PageStroke(
  points: [
    PageInkPoint(x, y, t),
    PageInkPoint(x + 3, y + 10, t + 40),
    PageInkPoint(x + 6, y, t + 80),
  ],
);

List<PageStroke> word(double x, double y, int n, int t) => [
  for (var i = 0; i < n; i++) letter(x + i * 7, y, t + i * 200),
];

/// Reads a word as "w" plus its number of strokes; remembers what it was
/// sent.
class FakeEngine implements Recognizer {
  FakeEngine({this.ready = true});
  final bool ready;
  final calls = <(List<InkStroke>, RecognitionContext)>[];

  @override
  String get name => 'Fake';
  @override
  bool get onDevice => true;
  @override
  Future<RecognizerStatus> status() async => ready
      ? const RecognizerStatus(RecognizerState.ready)
      : const RecognizerStatus(RecognizerState.needsSetup, 'Add keys');
  @override
  Future<void> prepare({void Function(double? progress)? onProgress}) async {}
  @override
  Future<List<Candidate>> recognize(
    List<InkStroke> strokes,
    RecognitionContext context,
  ) async {
    calls.add((strokes, context));
    return [Candidate('w${strokes.length}'), const Candidate('alt')];
  }
}

class MemoryLog implements EventLog {
  final events = <LoggedEvent>[];
  @override
  Future<void> log(LoggedEvent e) async => events.add(e);
  @override
  Future<List<LoggedEvent>> ofType(String type) async =>
      events.where((e) => e.type == type).toList();
}

void main() {
  const pause = Duration(milliseconds: 500);

  testWidgets('words are recognised after the pause, in reading order', (
    tester,
  ) async {
    final engine = FakeEngine();
    final log = MemoryLog();
    final c = InkTextController(engine: engine, eventLog: log);
    final page = [
      ...word(100, 700, 3, 0),
      ...word(135, 700, 2, 1000),
      ...word(100, 670, 4, 2000),
    ];
    c.inkChanged(1, page, pause);
    await tester.pump(const Duration(milliseconds: 400));
    expect(engine.calls, isEmpty); // still within the pause
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(c.wordsOn(1).map((w) => w.text), ['w3', 'w2', 'w4']);
    expect(c.textOf(1), 'w3 w2\nw4');
    expect(c.wordsOn(1).first.alternatives, ['alt']);
    expect(engine.calls[1].$2.preContext, 'w3');
    expect(log.events, hasLength(3));
    expect(log.events.first.engine, 'Fake');
    // Written at a 10 pt letter height, sent at about 50 px.
    final ys = engine.calls.first.$1.first.points.map((p) => p.y);
    expect(ys.reduce((a, b) => a > b ? a : b), closeTo(50, 1e-9));
    c.dispose();
  });

  testWidgets('only the changed word is sent again', (tester) async {
    final engine = FakeEngine();
    final c = InkTextController(engine: engine);
    final page = [...word(100, 700, 3, 0), ...word(135, 700, 2, 1000)];
    c.inkChanged(1, page, pause);
    await tester.pump(pause);
    await tester.pumpAndSettle();
    expect(engine.calls, hasLength(2));
    c.inkChanged(1, [...page, letter(149, 700, 9000)], pause);
    await tester.pump(pause);
    await tester.pumpAndSettle();
    expect(engine.calls, hasLength(3));
    expect(c.textOf(1), 'w3 w3');
    expect(engine.calls.last.$2.preContext, 'w3');
    c.dispose();
  });

  testWidgets('erasing a word removes its text', (tester) async {
    final engine = FakeEngine();
    final c = InkTextController(engine: engine);
    final page = [...word(100, 700, 3, 0), ...word(135, 700, 2, 1000)];
    c.inkChanged(1, page, pause);
    await tester.pump(pause);
    await tester.pumpAndSettle();
    c.inkChanged(1, page.sublist(0, 3), pause);
    await tester.pump(pause);
    await tester.pumpAndSettle();
    expect(c.textOf(1), 'w3');
    c.dispose();
  });

  testWidgets('saved ink is recognised when its page is first shown', (
    tester,
  ) async {
    final engine = FakeEngine();
    final c = InkTextController(engine: engine);
    c.ensure(2, word(100, 700, 2, 0));
    await tester.pumpAndSettle();
    expect(c.textOf(2), 'w2');
    c.ensure(2, word(100, 700, 2, 0)); // already done: nothing sent
    await tester.pumpAndSettle();
    expect(engine.calls, hasLength(1));
    c.dispose();
  });

  testWidgets('an engine that is not set up says why and sends nothing', (
    tester,
  ) async {
    final engine = FakeEngine(ready: false);
    final c = InkTextController(engine: engine);
    c.inkChanged(1, word(100, 700, 2, 0), pause);
    await tester.pump(pause);
    await tester.pumpAndSettle();
    expect(engine.calls, isEmpty);
    expect(c.problem, 'Add keys');
    c.dispose();
  });

  testWidgets('labels show each word under its ink', (tester) async {
    final c = InkTextController(engine: FakeEngine());
    final strokes = [...word(100, 700, 3, 0), ...word(100, 670, 2, 2000)];
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 306,
            height: 396,
            child: PageTextLabels(
              pageNumber: 1,
              geometry: PageGeometry(width: 612, height: 792),
              viewWidth: 306,
              text: c,
              strokes: () => strokes,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('w3'), findsOneWidget);
    expect(find.text('w2'), findsOneWidget);
    // Labels sit above their word: "w3" ink starts at PDF y 710, which is
    // view y (792 - 710) / 2 = 41 inside the 306 x 396 box.
    final box = tester.getTopLeft(find.byType(PageTextLabels));
    expect(tester.getBottomLeft(find.text('w3')).dy - box.dy, lessThan(41));
    // The first line's label sits above the second line's.
    expect(
      tester.getTopLeft(find.text('w3')).dy,
      lessThan(tester.getTopLeft(find.text('w2')).dy),
    );
    c.dispose();
  });

  testWidgets('underlines are not read as words', (tester) async {
    final engine = FakeEngine();
    final c = InkTextController(engine: engine);
    final page = [
      ...word(100, 700, 3, 0),
      const PageStroke(
        points: [
          PageInkPoint(98, 696, 5000),
          PageInkPoint(130, 695.5, 5050),
          PageInkPoint(160, 696, 5100),
        ],
      ),
    ];
    c.inkChanged(1, page, pause);
    await tester.pump(pause);
    await tester.pumpAndSettle();
    expect(c.textOf(1), 'w3');
    expect(engine.calls.single.$1, hasLength(3)); // the underline wasn't sent
    c.dispose();
  });

  group('corrections', () {
    testWidgets('a correction shows at once, is saved with its ink, and the '
        'same misreading is swapped next time', (tester) async {
      final store = _MemoryCorrections();
      final log = MemoryLog();
      final c = InkTextController(
        engine: FakeEngine(),
        corrections: store,
        eventLog: log,
        documentId: 'doc',
      );
      c.inkChanged(1, word(100, 700, 3, 0), pause);
      await tester.pump(pause);
      await tester.pumpAndSettle();
      final w = c.wordsOn(1).single;
      expect(w.text, 'w3');

      await c.correct(1, w, 'fox');
      expect(c.textOf(1), 'fox');
      expect(c.wordsOn(1).single.corrected, isTrue);
      expect(c.wordsOn(1).single.alternatives.first, 'w3');
      expect(store.saved.single.recognized, 'w3');
      expect(store.saved.single.corrected, 'fox');
      expect(store.saved.single.strokes, hasLength(3)); // the word's ink
      expect(log.events.last.type, 'correction');

      // The same word written again on another page: swapped and marked.
      c.inkChanged(2, word(100, 700, 3, 50000), pause);
      await tester.pump(pause);
      await tester.pumpAndSettle();
      final again = c.wordsOn(2).single;
      expect(again.text, 'fox');
      expect(again.autoReplaced, isTrue);
      expect(again.engineReading, 'w3');

      // Undoing the swap restores the engine's word and learns nothing.
      await c.correct(2, again, 'w3');
      expect(c.textOf(2), 'w3');
      expect(store.saved, hasLength(1));
      c.dispose();
    });

    testWidgets('saved corrections apply from when the PDF opens', (
      tester,
    ) async {
      final store = _MemoryCorrections()
        ..saved.add(
          CorrectionRecord(
            recognized: 'w2',
            corrected: 'dog',
            at: DateTime(2026),
          ),
        );
      final c = InkTextController(engine: FakeEngine(), corrections: store);
      await c.loadCorrections();
      c.inkChanged(1, word(100, 700, 2, 0), pause);
      await tester.pump(pause);
      await tester.pumpAndSettle();
      expect(c.textOf(1), 'dog');
      c.dispose();
    });

    testWidgets('"not writing" stops a group being read', (tester) async {
      final engine = FakeEngine();
      final c = InkTextController(engine: engine);
      final page = [...word(100, 700, 3, 0), ...word(135, 700, 2, 1000)];
      c.inkChanged(1, page, pause);
      await tester.pump(pause);
      await tester.pumpAndSettle();
      c.markNotWriting(1, c.wordsOn(1).last);
      expect(c.textOf(1), 'w3');
      final calls = engine.calls.length;
      c.inkChanged(1, page, pause); // same ink again: still ignored
      await tester.pump(pause);
      await tester.pumpAndSettle();
      expect(c.textOf(1), 'w3');
      expect(engine.calls.length, calls);
      c.dispose();
    });

    testWidgets('readNow reads a page straight away and waits for it', (
      tester,
    ) async {
      final engine = FakeEngine();
      final c = InkTextController(engine: engine);
      final page = [...word(100, 700, 3, 0), ...word(135, 700, 2, 1000)];
      final words = await tester.runAsync(() => c.readNow(2, page));
      expect(words!.map((w) => w.text), ['w3', 'w2']);
      final calls = engine.calls.length;
      // Again with the same ink: nothing new is sent.
      await tester.runAsync(() => c.readNow(2, page));
      expect(engine.calls.length, calls);
      c.dispose();
    });

    testWidgets('readNow gives no words when the engine is not set up', (
      tester,
    ) async {
      final c = InkTextController(engine: FakeEngine(ready: false));
      final words = await tester.runAsync(
        () => c.readNow(1, word(100, 700, 2, 0)),
      );
      expect(words, isEmpty);
      expect(c.problem, 'Add keys');
      c.dispose();
    });

    testWidgets('"not writing" lasts when the PDF is reopened (task 2.4c)', (
      tester,
    ) async {
      // First visit: mark the second group as not writing, on the ink.
      final ink = DocumentInk();
      for (final s in [...word(100, 700, 3, 0), ...word(135, 700, 2, 1000)]) {
        ink.add(1, s);
      }
      final first = InkTextController(engine: FakeEngine());
      first.inkChanged(1, ink.strokesOn(1), pause);
      await tester.pump(pause);
      await tester.pumpAndSettle();
      final drawing = first.wordsOn(1).last;
      expect(ink.markNotWriting(1, drawing.key.split(',').toSet()), isTrue);
      first.dispose();

      // Saved and reopened: a fresh controller doesn't read it.
      final saved = DocumentInk.fromJson(ink.toJson());
      final engine = FakeEngine();
      final reopened = InkTextController(engine: engine);
      reopened.inkChanged(1, saved.strokesOn(1), pause);
      await tester.pump(pause);
      await tester.pumpAndSettle();
      expect(reopened.textOf(1), 'w3');
      expect(engine.calls, hasLength(1), reason: 'the drawing is not sent');
      reopened.dispose();
    });
  });
}

class _MemoryCorrections implements CorrectionStore {
  final saved = <CorrectionRecord>[];
  @override
  Future<void> add(CorrectionRecord c) async => saved.add(c);
  @override
  Future<List<CorrectionRecord>> all() async => saved;
}
