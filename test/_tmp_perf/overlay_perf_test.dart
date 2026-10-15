import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/page_coordinates.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/stroke_grouping.dart';
import 'package:writing_recogniser/core/typed_text.dart';
import 'package:writing_recogniser/viewer/ink_text_controller.dart';
import 'package:writing_recogniser/viewer/label_fade.dart';
import 'package:writing_recogniser/viewer/page_ink_layer.dart';
import 'package:writing_recogniser/viewer/page_text_labels.dart';
import 'package:writing_recogniser/viewer/page_typed_text.dart';

import '../ink_text_controller_test.dart' show FakeEngine;

int _t = 0;
PageStroke stroke(double x, double y, int pts) {
  final r = math.Random(x.toInt() * 31 + y.toInt());
  return PageStroke(
    points: [
      for (var i = 0; i < pts; i++)
        PageInkPoint(
          x + i * 6 / pts + r.nextDouble(),
          y + 10 * math.sin(i / 3),
          _t += 8,
          0.5,
        ),
    ],
  );
}

List<PageStroke> page(int words, {int strokesPerWord = 4, int pts = 40}) {
  final out = <PageStroke>[];
  for (var w = 0; w < words; w++) {
    final x = 60.0 + (w % 6) * 80, y = 740.0 - (w ~/ 6) * 30;
    for (var s = 0; s < strokesPerWord; s++) {
      out.add(stroke(x + s * 9, y, pts));
    }
    _t += 1000;
  }
  return out;
}

void main() {
  test('pure-Dart costs per call', () {
    for (final n in [10, 50]) {
      final p = page(n);
      final sw = Stopwatch()..start();
      for (var i = 0; i < 20; i++) {
        groupStrokes(p);
      }
      final g = sw.elapsedMicroseconds / 20;
      sw.reset();
      for (var i = 0; i < 20; i++) {
        typedLines(p);
      }
      final tl = sw.elapsedMicroseconds / 20;
      // ignore: avoid_print
      print(
        'words=$n strokes=${p.length} segs=${p.length * 39} '
        'groupStrokes=${g.toStringAsFixed(0)}us typedLines(no typed)=${tl.toStringAsFixed(0)}us',
      );
    }
  });

  test('pdfrx-style width jitter while panning', () {
    // rectExternal.width = (right*z+tx) - (left*z+tx)
    const z = 1.37;
    const left = 0.0, right = 612 * 1.6;
    final widths = <double>{};
    for (var tx = -300.0; tx < 0; tx += 0.731) {
      widths.add((right * z + tx) - (left * z + tx));
    }
    final widths2 = <double>{};
    const left2 = 8.0;
    for (var tx = -300.0; tx < 0; tx += 0.731) {
      widths2.add((right * z + tx) - (left2 * z + tx));
    }
    // ignore: avoid_print
    print(
      'distinct widths over 410 pan steps: ${widths.length} / ${widths2.length}',
    );
  });

  for (final n in [0, 10, 50]) {
    testWidgets('scroll frames with $n words', (tester) async {
      final engine = FakeEngine();
      final text = InkTextController(engine: engine);
      final strokes = page(n);
      final ink = DocumentInkController();
      ink.ink.setPage(1, strokes);
      ink.ink.setPage(2, page(n));
      final showTyped = ValueNotifier(true);
      final fade = LabelFade();
      final top = ValueNotifier(0.0);
      final dx = ValueNotifier(0.0);
      final zoom = ValueNotifier(1.37);
      var stable = false;
      var overlayBuilds = 0;
      final g = PageGeometry(width: 612, height: 792);
      List<Widget> overlays(int pageNo, Rect r) {
        overlayBuilds++;
        return [
          Positioned.fill(
            child: GestureDetector(
              onTapUp: (_) {},
              child: PageInkLayer(
                pageNumber: pageNo,
                geometry: g,
                viewWidth: r.width,
                controller: ink,
                showTyped: showTyped,
                wordsRead: text,
                isRead: (id) => text
                    .wordsOn(pageNo)
                    .any((w) => w.key.split(',').contains(id)),
                onPenHover: (_) {},
              ),
            ),
          ),
          Positioned.fill(
            child: Builder(
              builder: (context) => PageTextLabels(
                pageNumber: pageNo,
                geometry: g,
                viewWidth: r.width,
                text: text,
                strokes: () => ink.ink.strokesOn(pageNo),
                onDoubleTap: (_) {},
                skip: (w) =>
                    showTyped.value &&
                    mostlyConverted(
                      w.key,
                      convertedStrokeIds(ink.ink.strokesOn(pageNo)),
                    ),
                refresh: Listenable.merge([ink, showTyped]),
                shown: fade,
              ),
            ),
          ),
          Positioned.fill(
            child: PageTypedText(
              pageNumber: pageNo,
              geometry: g,
              viewWidth: r.width,
              controller: ink,
              showTyped: showTyped,
            ),
          ),
        ];
      }

      await tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: Listenable.merge([top, dx, zoom]),
            builder: (context, _) => Stack(
              children: [
                for (final p in [1, 2])
                  () {
                    const z = 1.37;
                    final r = Rect.fromLTRB(
                      8 * z + dx.value,
                      top.value + (p - 1) * 1100,
                      612 * 1.6 * z + dx.value,
                      top.value + (p - 1) * 1100 + 1000,
                    );
                    return Positioned(
                      key: ValueKey(p),
                      left: r.left,
                      top: r.top,
                      width: r.width,
                      height: r.height,
                      child: Stack(children: overlays(p, r)),
                    );
                  }(),
              ],
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      // ignore: avoid_print
      print('words read p1=${text.wordsOn(1).length}');
      final boundaries = tester
          .renderObjectList<RenderObject>(find.byType(RepaintBoundary))
          .whereType<RenderRepaintBoundary>()
          .toList();
      int paints() => boundaries.fold(
        0,
        (a, b) => a + b.debugSymmetricPaintCount + b.debugAsymmetricPaintCount,
      );
      Future<double> run(void Function(int i) step) async {
        overlayBuilds = 0;
        final p0 = paints();
        final sw = Stopwatch()..start();
        for (var i = 0; i < 120; i++) {
          step(i);
          await tester.pump(const Duration(milliseconds: 16));
        }
        final per = sw.elapsedMicroseconds / 120;
        if (false) for (final b in boundaries) {
          final c = b.debugSymmetricPaintCount + b.debugAsymmetricPaintCount;
          // ignore: avoid_print
          print(
            '    rb ${b.debugCreator.toString().split('\n').first.substring(0, math.min(160, b.debugCreator.toString().split('\n').first.length))} paints=$c',
          );
        }
        // ignore: avoid_print
        print(
          '  overlayBuilds=$overlayBuilds rbPaints=${paints() - p0} '
          'us/frame=${per.toStringAsFixed(0)}',
        );
        return per;
      }

      // ignore: avoid_print
      print('n=$n vertical scroll:');
      await run((i) => top.value -= 7.3);
      // ignore: avoid_print
      print('n=$n diagonal scroll (zoomed):');
      await run((i) {
        top.value -= 7.3;
        dx.value -= 0.731;
      });
      // ignore: avoid_print
      print('n=$n vertical scroll, height snapped (no ULP jitter):');
      stable = true;
      await run((i) => top.value -= 7.3);
      stable = false;
      // ignore: avoid_print
      print('n=$n pinch zoom (viewWidth changes every frame):');
      await run((i) => zoom.value += 0.003);
      fade.dispose();
      text.dispose();
    });
  }
}
