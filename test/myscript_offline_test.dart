import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/ink.dart';
import 'package:writing_recogniser/core/recognition/recognizer.dart';
import 'package:writing_recogniser/recognition/myscript_offline_recognizer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/myscript_offline');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  void answer(Object? Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(calls.clear);
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  final recognizer = MyScriptOfflineRecognizer(channel: channel);
  const strokes = [
    InkStroke([InkPoint(1, 2, 1000, 0.4), InkPoint(3, 4, 1010, 0.6)]),
    InkStroke([InkPoint(5, 6, 1100)]),
  ];

  test('flat stroke encoding: x, y, t, pressure per point', () {
    expect(encodeStrokesFlat(strokes), [
      [1.0, 2.0, 1000, 0.4, 3.0, 4.0, 1010, 0.6],
      [5.0, 6.0, 1100, 0.5],
    ]);
  });

  test('a busy page is packed for the engine quickly (owner: the pen froze '
      'while a full page was sent)', () {
    // 523 strokes of 300 samples, as on the owner's busiest page.
    final page = [
      for (var i = 0; i < 523; i++)
        InkStroke([
          for (var j = 0; j < 300; j++)
            InkPoint(i * 3.0 + j * 0.6, (j % 50) * 0.8, 1000 + j * 4, 0.5),
        ]),
    ];
    encodeStrokesFlat(page); // warm up
    final watch = Stopwatch()..start();
    final flat = encodeStrokesFlat(page);
    const StandardMethodCodec().encodeMethodCall(
      MethodCall('classify', {'strokes': flat}),
    );
    // About 0.4 s with a plain list of numbers on a desktop.
    expect(watch.elapsedMilliseconds, lessThan(300));
  });

  test('points closer than half a unit are left out, never the ends', () {
    final dense = InkStroke([
      for (var i = 0; i <= 100; i++) InkPoint(i * 0.1, 0, 1000 + i, 0.5),
    ]);
    final flat = encodeStrokesFlat([dense]).single;
    final xs = [for (var i = 0; i < flat.length; i += 4) flat[i]];
    expect(xs.first, 0);
    expect(xs.last, closeTo(10, 1e-9));
    expect(xs.length, inInclusiveRange(20, 22)); // every 0.5, not 101
    for (var i = 1; i < xs.length - 1; i++) {
      expect(xs[i] - xs[i - 1], greaterThanOrEqualTo(0.5 - 1e-9));
    }
    // Times and pressure stay with their points.
    expect(flat[2], 1000);
    expect(flat[3], 0.5);
  });

  test(
    'ready when the tablet side says so, and remembers the language',
    () async {
      answer((_) => {'state': 'ready', 'message': '', 'lang': 'en_GB'});
      final s = await recognizer.status();
      expect(s.isReady, isTrue);
      expect(recognizer.language, 'en_GB');
    },
  );

  test('missing certificate is reported in plain language', () async {
    answer(
      (_) => {
        'state': 'noCertificate',
        'message': "This build doesn't include the MyScript certificate.",
      },
    );
    final s = await recognizer.status();
    expect(s.state, RecognizerState.unavailable);
    expect(s.message, contains('certificate'));
  });

  test('not available off Android (no platform side)', () async {
    final s = await MyScriptOfflineRecognizer(
      channel: const MethodChannel('test/nothing_here'),
    ).status();
    expect(s.state, RecognizerState.unavailable);
  });

  test('recognize sends strokes and turns JIIX into candidates', () async {
    answer(
      (_) => jsonEncode({
        'type': 'Text',
        'label': 'hello world',
        'words': [
          {
            'label': 'hello',
            'candidates': ['hello', 'hullo'],
          },
          {'label': ' '},
          {
            'label': 'world',
            'candidates': ['world', 'word'],
          },
        ],
      }),
    );
    final c = await recognizer.recognize(strokes, const RecognitionContext());
    expect(calls.single.method, 'recognize');
    expect((calls.single.arguments as Map)['strokes'], hasLength(2));
    expect(c.map((c) => c.text), ['hello world', 'hullo world', 'hello word']);
  });

  test('engine errors become RecognitionException', () async {
    answer((_) => throw PlatformException(code: 'failed', message: 'boom'));
    expect(
      () => recognizer.recognize(strokes, const RecognitionContext()),
      throwsA(isA<RecognitionException>()),
    );
  });

  test('no strokes: no call, no candidates', () async {
    answer((_) => fail('should not be called'));
    expect(
      await recognizer.recognize(const [], const RecognitionContext()),
      isEmpty,
    );
    expect(calls, isEmpty);
  });
}
