import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/app_settings.dart';
import 'package:writing_recogniser/core/event_log.dart';
import 'package:writing_recogniser/core/pen_tools.dart';
import 'package:writing_recogniser/recognition/myscript_keys.dart';
import 'package:writing_recogniser/settings/settings_controller.dart';
import 'package:writing_recogniser/settings/settings_screen.dart';
import 'package:writing_recogniser/viewer/pen_tools_controller.dart';

const mb = 1024 * 1024;

void main() {
  late SettingsController settings;
  late List<AppSettings> saved;
  late List<int> trims;
  late int clears;
  late FakeKeys keys;
  late PenToolsController pens;
  late Set<String> inkIds;
  late int inkDeletes;
  late List<(String, String)> savedFiles;

  Future<void> pumpScreen(WidgetTester tester) async {
    // Tablet-sized screen so the whole settings list is visible.
    tester.view.physicalSize = const Size(1600, 5000);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      SettingsScope(
        controller: settings,
        child: MaterialApp(
          home: SettingsScreen(
            cacheInfo: () async => (count: 2, bytes: 550 * mb),
            trimCache: (keep) async => trims.add(keep),
            clearCache: () async => clears++,
            myScriptKeys: keys,
            loadPenTools: () async => pens,
            inkDocuments: () async => inkIds,
            deleteAllInk: () async => inkDeletes++,
            loadDiagnostics: () async => (
              [
                LoggedEvent(
                  type: 'diagnostic',
                  at: DateTime.utc(2026, 1, 2),
                  data: const {'area': 'export', 'result': 'failed'},
                ),
              ],
              null,
            ),
            saveFile: (name, mime, bytes) async {
              savedFiles.add((name, utf8.decode(bytes)));
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    saved = [];
    trims = [];
    clears = 0;
    keys = FakeKeys();
    pens = PenToolsController();
    inkIds = {};
    inkDeletes = 0;
    savedFiles = [];
    settings = SettingsController(
      const AppSettings(),
      onSave: (s) async => saved.add(s),
    );
  });

  testWidgets('shows current settings and storage use', (tester) async {
    await pumpScreen(tester);
    await tester.scrollUntilVisible(
      find.text('Now using 550 MB for 2 PDFs.'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.text('Keep copies of the last 3 PDFs (plus any you pin)'),
      findsOneWidget,
    );
    expect(find.text('Now using 550 MB for 2 PDFs.'), findsOneWidget);
    // The slim bar is the default.
    await tester.scrollUntilVisible(
      find.textContaining('thin see-through bar'),
      -200, // above the storage use
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('thin see-through bar'), findsOneWidget);
  });

  testWidgets('smoothness graphs switch on, and are not saved', (tester) async {
    await pumpScreen(tester);
    final tile = find.widgetWithText(SwitchListTile, 'Show smoothness graphs');
    await tester.scrollUntilVisible(
      tile,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    // Fully on screen (not half under the edge) before tapping.
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(settings.showSmoothnessGraphs, isTrue);
    expect(saved, isEmpty);
  });

  testWidgets('saves a diagnostic report to send Claude', (tester) async {
    await pumpScreen(tester);
    final tile = find.text('Save diagnostic report');
    await tester.scrollUntilVisible(
      tile,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    // Fully on screen (not half under the edge) before tapping.
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(savedFiles.single.$1, startsWith('diagnostics-'));
    expect(savedFiles.single.$2, contains('export  {"result":"failed"}'));
    expect(find.textContaining('Saved the diagnostic report'), findsOneWidget);
  });

  testWidgets('the pen toolbar position is chosen in Settings', (tester) async {
    await pumpScreen(tester);
    expect(find.text('Where the pen toolbar sits'), findsOneWidget);
    await tester.tap(find.text('Right side'));
    await tester.pumpAndSettle();
    expect(pens.value.dock, ToolbarDock.right);
  });

  testWidgets('writing hand and pressure strength are saved', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.text('Left hand'));
    await tester.pumpAndSettle();
    expect(saved.last.writingHand, WritingHand.left);
    expect(find.textContaining('sits on the right'), findsOneWidget);
    expect(
      find.textContaining('How much thickness can change'),
      findsOneWidget,
    );
  });

  testWidgets('pressure on/off shows a live example; off hides the sliders', (
    tester,
  ) async {
    await pumpScreen(tester);
    expect(
      find.text(
        'Example, a 2 pt pen: light press 1.2 pt · normal 2 pt · '
        'hard press 2.8 pt',
      ),
      findsOneWidget,
    );
    expect(
      find.text('How much thickness can change: ±40% (standard)'),
      findsOneWidget,
    );
    await tester.tap(find.text('Pressure changes line thickness'));
    await tester.pumpAndSettle();
    expect(saved.last.pressureOn, isFalse);
    expect(find.textContaining('How much thickness'), findsNothing);
    expect(find.byType(PressureExample), findsNothing);
  });

  testWidgets('arrow trim slider shows its setting', (tester) async {
    await pumpScreen(tester);
    expect(
      find.text('Arrows: ignore the last 70 ms of the line if it hooks'),
      findsOneWidget,
    );
  });

  testWidgets('app colour, message colours and scroll tab mode are saved', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tester.tap(find.text('Orange'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Match the theme'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide'));
    await tester.pumpAndSettle();

    expect(settings.value.appColour, AppColour.orange);
    expect(settings.value.messageStyle, MessageStyle.matching);
    expect(settings.value.scrollTabIdle, ScrollTabIdle.hidden);
    expect(saved.last, settings.value);
    expect(find.textContaining('it fades out'), findsOneWidget);
  });

  testWidgets('moving the slider changes the limit and trims on release', (
    tester,
  ) async {
    await pumpScreen(tester);
    // Drag the slider all the way left: limit 1.
    // The storage slider sits just under its title.
    await tester.scrollUntilVisible(
      find.textContaining('Imported PDFs are copied'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    final storageSlider = find.descendant(
      of: find.ancestor(
        of: find.textContaining('Imported PDFs are copied'),
        matching: find.byType(ListTile),
      ),
      matching: find.byType(Slider),
    );
    await tester.ensureVisible(storageSlider);
    await tester.pumpAndSettle();
    await tester.drag(storageSlider, const Offset(-1000, 0));
    await tester.pumpAndSettle();

    expect(settings.value.cachedPdfLimit, 1);
    expect(
      find.text('Keep copies of the last 1 PDFs (plus any you pin)'),
      findsOneWidget,
    );
    expect(trims, [1]);
  });

  testWidgets('Delete ALL asks first, with a warning naming the size', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tester.scrollUntilVisible(
      find.text('Delete ALL stored copies'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Delete ALL stored copies'));
    await tester.pumpAndSettle();
    expect(find.text('Delete ALL stored copies?'), findsOneWidget);
    expect(find.textContaining('all 2 stored copies (550 MB)'), findsOneWidget);
    expect(find.textContaining('including pinned ones'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(clears, 0);

    await tester.tap(find.text('Delete ALL stored copies'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete ALL'));
    await tester.pumpAndSettle();
    expect(clears, 1);
  });

  testWidgets('Delete ALL keeps your ink unless you tick to delete it', (
    tester,
  ) async {
    inkIds = {'a', 'b'};
    await pumpScreen(tester);
    await tester.scrollUntilVisible(
      find.text('Keep my ink when a stored PDF is deleted'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.text('Keep my ink when a stored PDF is deleted'),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.text('Delete ALL stored copies'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Delete ALL stored copies'));
    await tester.pumpAndSettle();
    expect(find.text('Also delete my ink on 2 PDFs'), findsOneWidget);
    await tester.tap(find.text('Delete ALL'));
    await tester.pumpAndSettle();
    expect((clears, inkDeletes), (1, 0), reason: 'ink kept by default');

    await tester.tap(find.text('Delete ALL stored copies'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Also delete my ink on 2 PDFs'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete ALL'));
    await tester.pumpAndSettle();
    expect((clears, inkDeletes), (2, 1));
  });

  testWidgets('slim bar opacity slider only shows for the slim option', (
    tester,
  ) async {
    await pumpScreen(tester);
    // Slim is the default, so the slider shows straight away.
    expect(find.text('Slim bar: 55% solid'), findsOneWidget);
    await tester.tap(find.text('Always show'));
    await tester.pumpAndSettle();
    expect(find.text('Slim bar: 55% solid'), findsNothing);
    await tester.tap(find.text('Shrink to a slim bar'));
    await tester.pumpAndSettle();
    expect(find.text('Slim bar: 55% solid'), findsOneWidget);

    final slider = find.byType(Slider).first;
    await tester.drag(slider, const Offset(-1000, 0));
    await tester.pumpAndSettle();
    expect(settings.value.slimTabOpacityPercent, 15);
    expect(find.text('Slim bar: 15% solid'), findsOneWidget);
  });

  testWidgets('"Ask before deleting a single copy" can be turned back on', (
    tester,
  ) async {
    settings = SettingsController(
      const AppSettings(confirmDeleteCopy: false),
      onSave: (s) async => saved.add(s),
    );
    await pumpScreen(tester);
    await tester.scrollUntilVisible(
      find.text('Ask before deleting a single copy'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Ask before deleting a single copy'));
    await tester.pumpAndSettle();
    expect(settings.value.confirmDeleteCopy, isTrue);
  });

  testWidgets('recognition pause slider changes the setting', (tester) async {
    await pumpScreen(tester);
    // Learned automatically at first; the slider is for when that's off.
    final learn = find.text('Learn how long I pause');
    await tester.scrollUntilVisible(
      learn,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Recognise after a 0.8 s pause'), findsNothing);
    await tester.ensureVisible(learn);
    await tester.pumpAndSettle();
    await tester.tap(learn);
    await tester.pumpAndSettle();
    expect(settings.value.autoPause, isFalse);
    final title = find.text('Recognise after a 0.8 s pause');
    await tester.scrollUntilVisible(
      title,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    final slider = find.descendant(
      of: find.ancestor(of: title, matching: find.byType(ListTile)),
      matching: find.byType(Slider),
    );
    await tester.drag(slider, const Offset(1000, 0));
    await tester.pumpAndSettle();
    expect(settings.value.recognitionPauseMs, 2000);
    expect(find.text('Recognise after a 2.0 s pause'), findsOneWidget);
  });

  testWidgets('MyScript keys can be entered and removed', (tester) async {
    await pumpScreen(tester);
    final tile = find.text('MyScript keys');
    await tester.scrollUntilVisible(
      tile,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('Not set'), findsOneWidget);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Application key'),
      'app ',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'HMAC key'),
      'secret',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(keys.keys?.applicationKey, 'app ');
    expect(find.textContaining('Stored only on this tablet'), findsOneWidget);

    await tester.tap(tile);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove keys'));
    await tester.pumpAndSettle();
    expect(keys.keys, isNull);
  });

  testWidgets('About shows the MIT licence and credit, and opens the '
      'licences page', (tester) async {
    await pumpScreen(tester);
    await tester.scrollUntilVisible(
      find.text('About and open source licences'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('made by evilpuppypower'), findsOneWidget);
    await tester.ensureVisible(find.text('About and open source licences'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('About and open source licences'));
    await tester.pumpAndSettle();
    expect(find.textContaining('MIT licence.'), findsWidgets);
  });
}

class FakeKeys extends MyScriptKeyStore {
  MyScriptKeys? keys;

  @override
  Future<MyScriptKeys?> load() async => keys;

  @override
  Future<bool> save(MyScriptKeys k) async {
    keys = k;
    return true;
  }

  @override
  Future<void> clear() async => keys = null;
}
