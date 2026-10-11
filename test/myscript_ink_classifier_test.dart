import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/ink.dart';
import 'package:writing_recogniser/core/ink_classifier.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/recognition/myscript_ink_classifier.dart';

InkStroke s(double x0, double y0, double x1, double y1) =>
    InkStroke([InkPoint(x0, y0, 0), InkPoint(x1, y1, 10)]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A word (two strokes) on the left and an underline below it, in px.
  final ink = [s(0, 0, 40, 30), s(50, 0, 90, 30), s(0, 60, 90, 62)];

  // MyScript's answer for it, in millimetres (half the px numbers).
  final jiix = jsonEncode({
    'type': 'Raw Content',
    'elements': [
      {
        'type': 'Text',
        'bounding-box': {'x': 0, 'y': 0, 'width': 45, 'height': 15},
        'words': [
          {'label': 'hi'},
        ],
      },
      {
        'type': 'Drawing',
        'bounding-box': {'x': 0, 'y': 30, 'width': 45, 'height': 1},
      },
    ],
  });

  test('reads text and drawings from MyScript and matches our strokes', () {
    expect(kindsFromJiix(jiix, ink), [
      InkKind.writing,
      InkKind.writing,
      InkKind.drawing,
    ]);
  });

  test('strokes MyScript leaves out count as writing', () {
    final only = jsonEncode({
      'elements': [
        {
          'type': 'Drawing',
          'bounding-box': {'x': 0, 'y': 30, 'width': 45, 'height': 1},
        },
      ],
    });
    final kinds = kindsFromJiix(only, ink)!;
    expect(kinds.last, InkKind.drawing);
  });

  test('unreadable answers give null', () {
    expect(kindsFromJiix('not json', ink), isNull);
    expect(kindsFromJiix('{}', ink), isNull);
  });

  test('falls back to the shape check when MyScript is unavailable', () async {
    const channel = MethodChannel('test/myscript');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'no_classifier', message: 'no files');
        });
    final c = MyScriptInkClassifier(channel: channel);
    final kinds = await c.classify([
      const PageStroke(
        points: [PageInkPoint(0, 700, 0), PageInkPoint(3, 710, 9)],
      ),
      const PageStroke(
        points: [PageInkPoint(0, 690, 0), PageInkPoint(200, 690, 9)],
      ),
    ]);
    expect(kinds, [InkKind.writing, InkKind.drawing]);
    expect(c.problem, 'no files');
  });
}
