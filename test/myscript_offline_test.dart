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
