import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/app_settings.dart';
import 'package:writing_recogniser/settings/settings_controller.dart';
import 'package:writing_recogniser/core/labeled_sample.dart';
import 'package:writing_recogniser/core/prompts.dart';
import 'package:writing_recogniser/core/sample_store.dart';
import 'package:writing_recogniser/handwriting/sample_recorder_screen.dart';

class MemoryStore implements SampleStore {
  final samples = <LabeledSample>[];

  @override
  Future<int> add(LabeledSample s) async {
    samples.add(s);
    return samples.length;
  }

  @override
  Future<List<LabeledSample>> all() async => samples;

  @override
  Future<int> count() async => samples.length;

  @override
  Future<void> delete(int id) async {}
}

void main() {
  late MemoryStore store;

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 2560);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      SettingsScope(
        controller: SettingsController(const AppSettings()),
        child: MaterialApp(home: SampleRecorderScreen(store: store)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> write(WidgetTester tester) async {
    final g = await tester.createGesture(kind: PointerDeviceKind.stylus);
    await g.down(const Offset(300, 900));
    await g.moveBy(const Offset(60, 20));
    await g.up();
    await tester.pump();
  }

  setUp(() => store = MemoryStore());

  testWidgets('copying a sentence saves it with the strokes', (tester) async {
    await pump(tester);
    expect(find.text(samplePrompts.first), findsOneWidget);
    expect(find.text('0 saved · goal 25'), findsOneWidget);

    await write(tester);
    await tester.tap(find.text('Save sample'));
    await tester.pumpAndSettle();

    expect(store.samples.single.text, samplePrompts.first);
    expect(store.samples.single.strokes, hasLength(1));
    expect(find.text('1 saved · goal 25'), findsOneWidget);
    // Moves on to the next sentence with a clean writing area.
    expect(find.text(samplePrompts[1]), findsOneWidget);
  });

  testWidgets('Save is disabled until something is written', (tester) async {
    await pump(tester);
    final save = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Save sample'),
    );
    expect(save.onPressed, isNull);
  });

  testWidgets('free writing asks what was written', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Free writing'));
    await tester.pumpAndSettle();
    await write(tester);
    await tester.tap(find.text('Save sample'));
    await tester.pumpAndSettle();

    expect(find.text('What did you write?'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'my own words');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(store.samples.single.text, 'my own words');
  });

  testWidgets('skip moves to the next sentence without saving', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(find.text(samplePrompts[1]), findsOneWidget);
    expect(store.samples, isEmpty);
  });
}
