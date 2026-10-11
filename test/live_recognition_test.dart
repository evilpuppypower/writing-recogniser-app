import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/app_settings.dart';
import 'package:writing_recogniser/core/event_log.dart';
import 'package:writing_recogniser/core/ink.dart';
import 'package:writing_recogniser/core/recognition/recognizer.dart';
import 'package:writing_recogniser/handwriting/live_recognition_screen.dart';
import 'package:writing_recogniser/settings/settings_controller.dart';

class FakeEngine implements Recognizer {
  FakeEngine(
    this.name, {
    this.ready = true,
    this.fail = false,
    this.cloud = false,
  });

  @override
  final String name;
  bool ready;
  final bool fail;
  final bool cloud;
  int calls = 0;
  int prepares = 0;
  List<InkStroke>? lastStrokes;

  @override
  bool get onDevice => !cloud;

  @override
  Future<RecognizerStatus> status() async => ready
      ? const RecognizerStatus(RecognizerState.ready)
      : const RecognizerStatus(RecognizerState.needsDownload, 'Needs model');

  @override
  Future<void> prepare({void Function(double? p)? onProgress}) async {
    prepares++;
    ready = true;
  }

  @override
  Future<List<Candidate>> recognize(
    List<InkStroke> strokes,
    RecognitionContext context,
  ) async {
    calls++;
    lastStrokes = strokes;
    if (fail) throw const RecognitionException('Engine broke');
    return const [Candidate('hello'), Candidate('hallo'), Candidate('hells')];
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
  late MemoryLog log;

  Future<void> pump(WidgetTester tester, List<Recognizer> engines) async {
    tester.view.physicalSize = const Size(1600, 2560);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      SettingsScope(
        controller: SettingsController(
          const AppSettings(recognitionPauseMs: 800),
        ),
        child: MaterialApp(
          home: LiveRecognitionScreen(engines: engines, eventLog: log),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> write(WidgetTester tester) async {
    final g = await tester.createGesture(kind: PointerDeviceKind.stylus);
    await g.down(const Offset(300, 1000));
    await g.moveBy(const Offset(80, 10));
    await g.up();
    await tester.pump();
  }

  setUp(() => log = MemoryLog());

  testWidgets('recognises after the pause and shows guesses and latency', (
    tester,
  ) async {
    final engine = FakeEngine('Fake');
    await pump(tester, [engine]);
    await write(tester);

    await tester.pump(const Duration(milliseconds: 700));
    expect(engine.calls, 0, reason: 'not before the pause is over');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(engine.calls, 1);
    expect(engine.lastStrokes, hasLength(1));
    expect(find.text('hello'), findsOneWidget);
    expect(find.textContaining('hallo'), findsOneWidget);
    expect(
      find.textContaining('from lifting the pen to this text'),
      findsOneWidget,
    );
    expect(find.textContaining('Waiting for the pause'), findsOneWidget);
    expect(log.events.single.engine, 'Fake');
    expect(log.events.single.data['top'], 'hello');
    expect(log.events.single.latencyMs, isNotNull);
    expect(log.events.single.data['engineMs'], isNotNull);
    expect(log.events.single.data['waitMs'], greaterThanOrEqualTo(0));
  });

  testWidgets('writing again before the pause ends waits for the new stroke', (
    tester,
  ) async {
    final engine = FakeEngine('Fake');
    await pump(tester, [engine]);
    await write(tester);
    await tester.pump(const Duration(milliseconds: 500));
    await write(tester);
    await tester.pump(const Duration(milliseconds: 500));
    expect(engine.calls, 0);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(engine.calls, 1);
    expect(engine.lastStrokes, hasLength(2));
  });

  testWidgets('an engine that needs a download offers the button', (
    tester,
  ) async {
    final engine = FakeEngine('Fake', ready: false);
    await pump(tester, [engine]);
    expect(find.text('Needs model'), findsOneWidget);
    await tester.tap(find.text('Download model (about 20 MB)'));
    await tester.pumpAndSettle();
    expect(engine.prepares, 1);
    expect(find.textContaining('Write with the pen'), findsOneWidget);
  });

  testWidgets('engine errors are shown, not crashed on', (tester) async {
    await pump(tester, [FakeEngine('Fake', fail: true)]);
    await write(tester);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.textContaining('Engine broke'), findsOneWidget);
    expect(log.events, isEmpty);
  });

  testWidgets('with two engines you can switch between them', (tester) async {
    final a = FakeEngine('Alpha');
    final b = FakeEngine('Beta', cloud: true);
    await pump(tester, [a, b]);
    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    await write(tester);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(a.calls, 0);
    expect(b.calls, 1);
    expect(find.byTooltip('Sends pen strokes to a server'), findsOneWidget);
  });
}
