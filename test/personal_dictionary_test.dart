import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/feedback/personal_dictionary.dart';
import 'package:writing_recogniser/settings/dictionary_screen.dart';

void main() {
  test('what looks like shorthand', () {
    expect(PersonalDictionary.looksLikeShorthand('w/', 'with'), isTrue);
    expect(PersonalDictionary.looksLikeShorthand('b/c', 'because'), isTrue);
    expect(PersonalDictionary.looksLikeShorthand('govt', 'government'), isTrue);
    expect(PersonalDictionary.looksLikeShorthand('teh', 'the'), isFalse);
    expect(PersonalDictionary.looksLikeShorthand('bat', 'cat food'), isFalse);
    expect(PersonalDictionary.looksLikeShorthand('w/', 'without'), isTrue);
  });

  test('learned after the same correction twice, then written out', () {
    final d = PersonalDictionary();
    expect(d.learnFromCorrection('w/', 'with'), isFalse);
    expect(d.expand('tea w/ milk'), 'tea w/ milk');
    expect(d.learnFromCorrection('w/', 'with'), isTrue);
    expect(d.shorthand['w/']!.learned, isTrue);
    expect(d.expand('tea w/ milk, W/ sugar'), 'tea with milk, with sugar');
    d.addShorthand('approx', 'approximately');
    expect(d.expand('approx. 5'), 'approximately. 5');
  });

  test('removed shorthand isn\'t learned again from old corrections', () {
    final d = PersonalDictionary()..learnFromCorrection('b/c', 'because');
    d.removeShorthand('b/c');
    expect(d.learnFromCorrection('b/c', 'because'), isFalse);
  });

  test('kept and read back', () {
    final d = PersonalDictionary()
      ..addWord('Krebs')
      ..addShorthand('w/', 'with')
      ..learnFromCorrection('b/c', 'because');
    final back = PersonalDictionary()..load(d.toJson());
    expect(back.words, ['Krebs']);
    expect(back.shorthand['w/']!.full, 'with');
    // The correction seen once is remembered too.
    expect(back.learnFromCorrection('b/c', 'because'), isTrue);
    back.load('nonsense');
    expect(back.words, isEmpty);
  });

  testWidgets('words and shorthand added in Settings', (tester) async {
    PersonalDictionary? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: DictionaryScreen(
          load: () async => PersonalDictionary(),
          save: (d) async => saved = d,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'A word'), 'Krebs');
    await tester.tap(find.byTooltip('Add this word'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'w/'), 'b/c');
    await tester.enterText(find.widgetWithText(TextField, 'with'), 'because');
    await tester.tap(find.byTooltip('Add this shorthand'));
    await tester.pumpAndSettle();
    expect(saved!.words, ['Krebs']);
    expect(saved!.shorthand['b/c']!.full, 'because');
    expect(find.text('b/c  →  because'), findsOneWidget);
  });
}
