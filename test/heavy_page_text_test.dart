import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/ink.dart';
import 'package:writing_recogniser/core/page_coordinates.dart';
import 'package:writing_recogniser/core/stroke_grouping.dart';
import 'package:writing_recogniser/viewer/ink_text_controller.dart';
import 'package:writing_recogniser/viewer/page_text_labels.dart';

import 'ink_text_controller_test.dart' show FakeEngine;

/// A heavy page's saved words (owner, 2026-10-24: about 380 words on a page
/// of 700 strokes, 170 points a stroke, lagged): [n] words of 2 strokes.
String heavyPage(int n, {int points = 170, bool seen = true}) {
  var t = 0;
  return jsonEncode({
    'seen': [
      if (seen)
        for (var i = 0; i < n * 2; i++) 's$i',
    ],
    'words': [
      for (var w = 0; w < n; w++)
        RecognizedWord(
          text: 'word$w',
          alternatives: const ['a', 'b'],
          box: InkBox(
            20.0 + (w % 20) * 28,
            780.0 - (w ~/ 20) * 30,
            40.0 + (w % 20) * 28,
            790.0 - (w ~/ 20) * 30,
          ),
          line: w ~/ 20,
          key: 'k$w',
          ink: [
            for (var s = 0; s < 2; s++)
              InkStroke([
                for (var i = 0; i < points; i++)
                  InkPoint(w * 3.0 + i * 0.1, s * 2.0 + i * 0.05, t += 5, 0.5),
              ]),
          ],
        ).toJson(),
    ],
  });
}

double msOf(void Function() f) {
  final sw = Stopwatch()..start();
  f();
  return sw.elapsedMicroseconds / 1000;
}

void main() {
  // Limits are far above what's measured (tests run unoptimised, on shared
  // machines): they catch the whole page being encoded again on each save.
  group('saving a heavy page\'s words', () {
    final json = heavyPage(380);

    test('read in the background, saved as before', () async {
      final c = InkTextController(engine: FakeEngine());
      await c.restoreAll({1: json, 2: 'not JSON'});
      final plain = InkTextController(engine: FakeEngine())..restore(1, json);
      expect(c.wordsOn(1), hasLength(380));
      expect(c.pageJson(1), plain.pageJson(1));
      expect(c.pageJson(2), isNull, reason: 'unreadable: read again');
    });

    test('a save after one word changed encodes only that word', () async {
      final c = InkTextController(engine: FakeEngine());
      await c.restoreAll({1: json});
      c.pageJson(1);
      final word = c.wordsOn(1)[7];
      c.confirm(1, word);
      late String saved;
      final ms = msOf(() => saved = c.pageJson(1)!);
      // ignore: avoid_print
      print('speed: save after one word changed  ${ms.toStringAsFixed(1)} ms');
      expect(ms, lessThan(150));
      final words = (jsonDecode(saved) as Map)['words'] as List;
      final w = words.firstWhere((w) => w['key'] == word.key) as Map;
      expect(w['checked'], isTrue);
      expect(words, hasLength(380));
    });
  });

  testWidgets('a heavy page\'s labels: one changed word is redrawn quickly, '
      'and kept labels call the current double-tap', (tester) async {
    final c = InkTextController(engine: FakeEngine())
      // Not read from any strokes: the labels' page has none to check.
      ..restore(1, heavyPage(380, points: 2, seen: false));
    final tapped = <String>[];
    Widget labels(String who) => MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 612,
          height: 792,
          child: PageTextLabels(
            above: false,
            showUnsure: true,
            pageNumber: 1,
            geometry: PageGeometry(width: 612, height: 792),
            viewWidth: 612,
            text: c,
            strokes: () => const [],
            onDoubleTap: (w) => tapped.add('$who ${w.text}'),
          ),
        ),
      ),
    );
    await tester.pumpWidget(labels('first'));
    await tester.pump();
    final times = <double>[];
    for (var i = 0; i < 4; i++) {
      c.confirm(1, c.wordsOn(1)[i * 10]);
      final sw = Stopwatch()..start();
      await tester.pump();
      times.add(sw.elapsedMicroseconds / 1000);
    }
    times.sort();
    // ignore: avoid_print
    print(
      'speed: labels after one word changed  ${times[1].toStringAsFixed(1)} ms',
    );
    expect(times[1], lessThan(60));
    expect(find.text('word0'), findsOneWidget);
    // The parent rebuilt with a new callback: a label kept from before
    // calls the new one.
    await tester.pumpWidget(labels('second'));
    await tester.pump();
    final at = tester.getCenter(find.text('word5'));
    final g = await tester.createGesture(kind: PointerDeviceKind.touch);
    await g.down(at);
    await g.up();
    await tester.pump(const Duration(milliseconds: 50));
    await g.down(at);
    await g.up();
    await tester.pumpAndSettle();
    expect(tapped, ['second word5']);
  });
}
