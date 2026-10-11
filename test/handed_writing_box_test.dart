import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/app_settings.dart';
import 'package:writing_recogniser/handwriting/handed_writing_box.dart';
import 'package:writing_recogniser/settings/settings_controller.dart';

void main() {
  Future<Rect> boxFor(WidgetTester tester, AppSettings s) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      SettingsScope(
        controller: SettingsController(s),
        child: const MaterialApp(
          home: HandedWritingBox(child: SizedBox.expand(key: Key('box'))),
        ),
      ),
    );
    return tester.getRect(find.byKey(const Key('box')));
  }

  testWidgets('right hand: box on the left, leaving the right side free', (
    tester,
  ) async {
    final r = await boxFor(tester, const AppSettings(writingBoxPercent: 50));
    expect(r.left, 0);
    expect(r.width, 600);
  });

  testWidgets('left hand: box on the right', (tester) async {
    final r = await boxFor(
      tester,
      const AppSettings(writingHand: WritingHand.left, writingBoxPercent: 50),
    );
    expect(r.right, 1200);
    expect(r.width, 600);
  });

  testWidgets('100% uses the full width', (tester) async {
    final r = await boxFor(tester, const AppSettings(writingBoxPercent: 100));
    expect(r.width, 1200);
  });
}
