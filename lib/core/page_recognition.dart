/// Which handwritten words on a page need (re)recognising after the pen
/// pauses, and the text written before each (task 2.2). Pure Dart; the
/// engine is called elsewhere through the Recognizer interface.
library;

import 'page_ink.dart';
import 'stroke_grouping.dart';

/// Identifies a word by its strokes, so its text is kept until a stroke is
/// added to it or erased from it.
String wordKey(List<PageStroke> strokes, InkWord word) =>
    [for (final i in word.strokes) strokes[i].id].join(',');

/// One word to send to the recognizer.
class RecognitionJob {
  const RecognitionJob({
    required this.key,
    required this.word,
    required this.line,
    required this.preContext,
  });

  final String key;
  final InkWord word;

  /// Line number on the page, top first.
  final int line;

  /// Recognised text of the words just before this one on the page, in
  /// reading order (helps the engine pick between similar words).
  final String preContext;
}

/// The plan for one page: the words that need recognising, and every word
/// key on the page now (results for other keys are out of date).
class RecognitionPlan {
  const RecognitionPlan(this.lines, this.jobs, this.keys, this.letterHeight);

  final List<InkLine> lines;

  /// Typical letter height of the writing on the page, in PDF points.
  final double letterHeight;
  final List<RecognitionJob> jobs;
  final Set<String> keys;
}

/// How many characters of earlier text to pass as context.
const preContextChars = 40;

/// Plans recognition for a page's [strokes], given the text already
/// recognised for each word key in [known].
RecognitionPlan planRecognition(
  List<PageStroke> strokes,
  Map<String, String> known, {
  GroupingParams params = const GroupingParams(),
  bool Function(int index)? include,
}) {
  final lines = groupStrokes(strokes, params: params, include: include);
  final jobs = <RecognitionJob>[];
  final keys = <String>{};
  final before = StringBuffer();
  for (var l = 0; l < lines.length; l++) {
    for (final w in lines[l].words) {
      final key = wordKey(strokes, w);
      keys.add(key);
      final text = known[key];
      if (text == null) {
        final ctx = before.toString();
        jobs.add(
          RecognitionJob(
            key: key,
            word: w,
            line: l,
            preContext: ctx.length > preContextChars
                ? ctx.substring(ctx.length - preContextChars)
                : ctx,
          ),
        );
      } else {
        if (before.isNotEmpty) before.write(' ');
        before.write(text);
      }
    }
  }
  final letter = typicalLetterHeight([
    for (final s in strokes)
      if (isWriting(s)) InkBox.of(s),
  ]);
  return RecognitionPlan(lines, jobs, keys, letter);
}
