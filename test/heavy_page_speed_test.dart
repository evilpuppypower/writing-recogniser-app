import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/ink_classifier.dart';
import 'package:writing_recogniser/core/page_coordinates.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/page_recognition.dart';
import 'package:writing_recogniser/core/stroke_grouping.dart';
import 'package:writing_recogniser/core/typed_text.dart';
import 'package:writing_recogniser/viewer/page_ink_layer.dart';

/// A page with [words] handwritten words (owner: heavy pages hold about 300
/// words; 600 and 1000 to stretch it), 20 words a line, 5 strokes of 24
/// points each, written in order; [typed] marks every word converted.
List<PageStroke> page(int words, {bool typed = false}) {
  final out = <PageStroke>[];
  final rnd = math.Random(words);
  var t = 1000000;
  for (var w = 0; w < words; w++) {
    final x0 = 30.0 + (w % 20) * 27, y0 = 790.0 - (w ~/ 20) * 15;
    for (var s = 0; s < 5; s++) {
      final h = 4 + rnd.nextDouble() * 2;
      out.add(
        PageStroke(
          typedGroup: typed ? 'g$w' : null,
          typedText: typed && s == 0 ? 'word' : null,
          points: [
            for (var i = 0; i < 24; i++)
              PageInkPoint(
                x0 + s * 4 + i * 0.15,
                y0 + h / 2 + h / 2 * math.sin(i / 3),
                t += 5,
                0.5,
              ),
          ],
        ),
      );
      t += 150;
    }
    t += 300;
  }
  return out;
}

/// Milliseconds per call of [f] (after two warm-up calls).
double timeOf(void Function() f, {int reps = 5}) {
  f();
  f();
  final sw = Stopwatch()..start();
  for (var i = 0; i < reps; i++) {
    f();
  }
  return sw.elapsedMicroseconds / reps / 1000;
}

void report(String what, int words, double ms) {
  // ignore: avoid_print
  print(
    'speed: ${what.padRight(36)} $words words  ${ms.toStringAsFixed(1)} ms',
  );
}

void main() {
  // Limits are far above what's measured (tests run unoptimised, and on
  // shared machines): they catch something growing out of hand, e.g.
  // work that grows with the square of the ink.
  for (final n in [300, 600, 1000]) {
    group('$n words', () {
      final strokes = page(n);

      test('grouped into the right lines and words, quickly', () {
        late List<InkLine> lines;
        final ms = timeOf(() => lines = groupStrokes(strokes));
        report('grouping', n, ms);
        expect(lines, hasLength(n ~/ 20));
        expect(lines.fold(0, (a, l) => a + l.words.length), n);
        expect(ms, lessThan(n * 1.0));
      });

      test('sorting writing from drawing, quickly', () {
        late List<InkKind> kinds;
        final ms = timeOf(() {
          final shape = const ShapeInkClassifier().classifySync(strokes);
          kinds = reconcileKinds(strokes, shape, shape: shape);
        });
        report('writing or drawing', n, ms);
        expect(kinds.every((k) => k == InkKind.writing), isTrue);
        expect(ms, lessThan(n * 0.5));
      });

      test('planning what to read after one more stroke, quickly', () {
        final known = {
          for (final k in planRecognition(strokes, const {}).keys) k: 'word',
        };
        final more = [
          ...strokes,
          PageStroke(
            points: [
              for (var i = 0; i < 24; i++)
                PageInkPoint(560 + i * 0.15, 790.0 + 2, 9000000000 + i * 5),
            ],
          ),
        ];
        late RecognitionPlan plan;
        final ms = timeOf(() => plan = planRecognition(more, known));
        report('planning after a stroke', n, ms);
        expect(plan.jobs, hasLength(1));
        expect(ms, lessThan(n * 1.0));
      });

      test('converted text isn\'t laid out again for new writing', () {
        final typed = page(n, typed: true);
        final first = typedLines(typed);
        expect(first, hasLength(n ~/ 20));
        // One more stroke, not converted: a new list, the same lines.
        final ms = timeOf(
          () => typedLines([...typed, strokes.first]),
          reps: 20,
        );
        report('typed text after a stroke', n, ms);
        expect(identical(typedLines([...typed, strokes.first]), first), isTrue);
        expect(ms, lessThan(5));
      });

      test('the eraser checks the page quickly', () {
        final ink = DocumentInk()..setPage(1, [...strokes]);
        final ms = timeOf(() => ink.eraseAt(1, 5, 5, 3), reps: 50);
        report('eraser move', n, ms);
        expect(ms, lessThan(n * 0.02));
        // And still erases what it touches.
        final p = strokes[n].points[10];
        expect(ink.eraseAt(1, p.x, p.y, 0.5), isNotEmpty);
      });

      testWidgets('writing one more stroke doesn\'t redraw the page', (
        tester,
      ) async {
        final ctl = DocumentInkController(
          DocumentInk()..setPage(1, [...strokes]),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 612,
                height: 792,
                child: PageInkLayer(
                  pageNumber: 1,
                  geometry: PageGeometry(width: 612, height: 792),
                  viewWidth: 612,
                  controller: ctl,
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        final pen = await tester.createGesture(kind: PointerDeviceKind.stylus);
        final sw = Stopwatch();
        const strokesWritten = 10;
        for (var k = 0; k < strokesWritten; k++) {
          final at = Offset(60.0 + k * 40, 500);
          await pen.down(at);
          await pen.moveTo(at + const Offset(10, 12));
          await tester.pump(const Duration(milliseconds: 16));
          await pen.up();
          sw.start();
          await tester.pump(const Duration(milliseconds: 16));
          sw.stop();
        }
        final ms = sw.elapsedMicroseconds / strokesWritten / 1000;
        report('page drawn after a stroke', n, ms);
        expect(
          ctl.ink.strokesOn(1),
          hasLength(strokes.length + strokesWritten),
        );
        expect(tester.takeException(), isNull);
        expect(ms, lessThan(n * 0.1));
        // Once settled, from a ready-made image again; then strokes in
        // the middle of the page change (only their piece is drawn again).
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        sw.reset();
        sw.start();
        ctl.recolour(1, {strokes[n].id, strokes[n + 1].id}, 0xFFCC0000);
        await tester.pump();
        sw.stop();
        report(
          'page drawn after recolouring',
          n,
          sw.elapsedMicroseconds / 1000,
        );
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    });
  }
}
