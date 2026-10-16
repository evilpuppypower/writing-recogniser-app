import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/app_settings.dart';
import 'package:writing_recogniser/viewer/page_colours_dialog.dart';

void main() {
  Future<Future<PageColoursPick?>> open(
    WidgetTester tester, {
    PageColours byDefault = PageColours.light,
    PageColours? current,
    bool importing = false,
  }) async {
    late Future<PageColoursPick?> result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => result = askPageColours(
              context,
              byDefault: byDefault,
              current: current,
              importing: importing,
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('when importing: starts on Settings\' choice, can stop asking', (
    tester,
  ) async {
    final pick = await open(
      tester,
      byDefault: PageColours.dark,
      importing: true,
    );
    expect(find.text('How should this PDF look?'), findsOneWidget);
    // No "Same as Settings" or Cancel when importing.
    expect(find.text('Same as Settings'), findsNothing);
    expect(find.text('Cancel'), findsNothing);
    await tester.tap(find.text(PageColours.light.label));
    await tester.tap(find.text("Don't ask when I import a PDF"));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    final p = await pick;
    expect(p!.colours, PageColours.light);
    expect(p.stopAsking, isTrue);
  });

  testWidgets('later: starts on the PDF\'s own choice, can go back to '
      'Settings\'', (tester) async {
    final pick = await open(tester, current: PageColours.dark);
    expect(find.text('Same as Settings'), findsOneWidget);
    await tester.tap(find.text('Same as Settings'));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect((await pick)!.colours, isNull);
  });
}
