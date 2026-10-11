import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:writing_recogniser/core/app_settings.dart';
import 'package:writing_recogniser/main.dart';
import 'package:writing_recogniser/settings/settings_controller.dart';

void main() {
  testWidgets('Home screen offers the file picker and settings', (
    tester,
  ) async {
    await tester.pumpWidget(
      WritingRecogniserApp(settings: SettingsController(const AppSettings())),
    );

    expect(find.text('Writing Recogniser'), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, 'Open a PDF from this tablet'),
      findsOneWidget,
    );
    expect(find.text('Build: local build'), findsOneWidget);
    expect(find.byTooltip('Settings'), findsOneWidget);
  });
}
