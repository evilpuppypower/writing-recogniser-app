/// Turns saved handwriting samples (whole sentences) into one replay case
/// per word, for the replay harness (task 3.1). Pure Dart.
///
/// On PDFs the app reads one word at a time, so the replay does too: each
/// sample's ink is split into words the same way as on a page
/// ([groupStrokes]) and paired with the words of the sentence. A sample
/// whose ink splits into a different number of words than the sentence has
/// can't be paired reliably, so it's skipped (and counted).
library;

import 'labeled_sample.dart';
import 'page_ink.dart';
import 'replay.dart';
import 'stroke_grouping.dart';

class SampleWords {
  const SampleWords(
    this.cases, {
    required this.samplesUsed,
    required this.samplesSkipped,
  });

  /// One case per word, oldest sample first, words in reading order.
  final List<ReplayCase> cases;
  final int samplesUsed;

  /// Samples whose ink didn't split into as many words as the sentence.
  final int samplesSkipped;
}

/// Splits [samples] into words; see the library comment.
SampleWords wordsFromSamples(Iterable<LabeledSample> samples) {
  final sorted = samples.toList()
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  final cases = <ReplayCase>[];
  var used = 0, skipped = 0;
  for (final s in sorted) {
    final truth = s.text.trim().split(RegExp(r'\s+'))
      ..removeWhere((w) => w.isEmpty);
    // Page coordinates have y growing upward; the writing box's grows
    // downward.
    final page = [
      for (final st in s.strokes)
        PageStroke(
          points: [
            for (final p in st.points) PageInkPoint(p.x, -p.y, p.t, p.pressure),
          ],
        ),
    ];
    final words = [for (final line in groupStrokes(page)) ...line.words];
    if (truth.isEmpty || words.length != truth.length) {
      skipped++;
      continue;
    }
    used++;
    for (var i = 0; i < words.length; i++) {
      cases.add(
        ReplayCase(
          strokes: wordInk(page, words[i]),
          truth: truth[i],
          previousWord: i == 0 ? '' : truth[i - 1],
          at: s.createdAt,
        ),
      );
    }
  }
  return SampleWords(cases, samplesUsed: used, samplesSkipped: skipped);
}
