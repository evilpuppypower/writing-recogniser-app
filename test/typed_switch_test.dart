import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/viewer/pdf_viewer_screen.dart';

void main() {
  testWidgets('the switch says what is showing, and switches', (tester) async {
    final typed = ValueNotifier(true);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TypedSwitchButton(showTyped: typed)),
      ),
    );
    expect(find.text('Showing typed text'), findsOneWidget);
    await tester.tap(find.byType(TypedSwitchButton));
    await tester.pump();
    expect(typed.value, isFalse);
    expect(find.text('Showing handwriting'), findsOneWidget);
    expect(
      find.byTooltip('Tap to show the typed text instead'),
      findsOneWidget,
    );
  });
}
