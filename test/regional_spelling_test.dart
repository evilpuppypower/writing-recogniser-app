import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/app_settings.dart';
import 'package:writing_recogniser/core/feedback/correction.dart';
import 'package:writing_recogniser/core/feedback/feedback_layer.dart';
import 'package:writing_recogniser/core/feedback/regional_spelling.dart';
import 'package:writing_recogniser/core/recognition/recognizer.dart';

class _Inner implements FeedbackLayer {
  List<String> got = const [];
  @override
  FeedbackResult apply(List<Candidate> c, FeedbackContext x) {
    got = [for (final k in c) k.text];
    return FeedbackResult(c);
  }

  @override
  void learn(CorrectionRecord c) {}
  @override
  void used(String w, {String previousWord = ''}) {}
  @override
  void undone(String e, String s) {}
}

void main() {
  final table = SpellingTable.parse(
    'color\tcolour\tcolour\n'
    'organize\torganise\torganize\n'
    'traveled\ttravelled\ttravelled\n'
    'bad line\n',
  );

  test('words are put into the chosen English, keeping their case', () {
    expect(table.length, 3);
    expect(table.respell('color', EnglishSpelling.british), 'colour');
    expect(table.respell('Color', EnglishSpelling.british), 'Colour');
    expect(table.respell('COLOR', EnglishSpelling.british), 'COLOUR');
    expect(table.respell('colour', EnglishSpelling.american), 'color');
    expect(table.respell('organize', EnglishSpelling.canadian), 'organize');
    expect(table.respell('organise', EnglishSpelling.canadian), 'organize');
    // Punctuation and other words stay as they are.
    expect(
      table.respell('"Color," he traveled.', EnglishSpelling.british),
      '"Colour," he travelled.',
    );
    expect(table.respell('hello', EnglishSpelling.british), 'hello');
  });

  test('the tablet\'s English follows its region, British otherwise', () {
    expect(
      settledSpelling(EnglishSpelling.tablet, 'US'),
      EnglishSpelling.american,
    );
    expect(
      settledSpelling(EnglishSpelling.tablet, 'ca'),
      EnglishSpelling.canadian,
    );
    expect(
      settledSpelling(EnglishSpelling.tablet, 'GB'),
      EnglishSpelling.british,
    );
    expect(
      settledSpelling(EnglishSpelling.tablet, null),
      EnglishSpelling.british,
    );
    expect(
      settledSpelling(EnglishSpelling.american, 'GB'),
      EnglishSpelling.american,
    );
  });

  test('readings are respelt before the user\'s corrections, without '
      'repeats; nothing changes while the table loads', () {
    final inner = _Inner();
    var spelling = EnglishSpelling.british;
    SpellingTable? loaded;
    final layer = RegionalSpelling(
      inner,
      spelling: () => spelling,
      table: () => loaded,
    );
    const ctx = FeedbackContext();
    layer.apply(const [Candidate('color'), Candidate('colour')], ctx);
    expect(inner.got, ['color', 'colour'], reason: 'table not loaded yet');
    loaded = table;
    layer.apply(const [
      Candidate('color'),
      Candidate('colour'),
      Candidate('collar'),
    ], ctx);
    expect(inner.got, ['colour', 'collar']);
    spelling = EnglishSpelling.american;
    layer.apply(const [Candidate('colour')], ctx);
    expect(inner.got, ['color']);
  });

  test('the bundled table has the common words, and leaves out words with '
      'two meanings', () {
    final t = SpellingTable.parse(
      File('assets/spellings.tsv').readAsStringSync(),
    );
    expect(t.length, greaterThan(10000));
    for (final (us, gb) in [
      ('color', 'colour'),
      ('favorite', 'favourite'),
      ('center', 'centre'),
      ('analyze', 'analyse'),
      ('realized', 'realised'),
      ('aluminum', 'aluminium'),
    ]) {
      expect(t.respell(us, EnglishSpelling.british), gb);
      expect(t.respell(gb, EnglishSpelling.american), us);
    }
    for (final w in ['program', 'check', 'meter', 'tire']) {
      expect(t.respell(w, EnglishSpelling.british), w);
    }
  });

  test('the choice is saved, British by default', () {
    expect(const AppSettings().englishSpelling, EnglishSpelling.british);
    final s = const AppSettings().copyWith(
      englishSpelling: EnglishSpelling.tablet,
    );
    expect(
      AppSettings.fromMap(s.toMap()).englishSpelling,
      EnglishSpelling.tablet,
    );
    expect(
      AppSettings.fromMap(const {}).englishSpelling,
      EnglishSpelling.british,
    );
  });
}
