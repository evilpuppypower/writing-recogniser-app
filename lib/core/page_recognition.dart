/// Which handwritten words on a page need (re)recognising after the pen
/// pauses, and the text written before each (task 2.2). Pure Dart; the
/// engine is called elsewhere through the Recognizer interface.
library;

import 'dart:math' as math;

import 'page_ink.dart';
import 'printed_text.dart';
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
    this.letterHeight = 4,
  });

  final String key;
  final InkWord word;

  /// Line number on the page, top first.
  final int line;

  /// Recognised text of the words just before this one on the page, in
  /// reading order (helps the engine pick between similar words).
  final String preContext;

  /// Typical letter height of the word's line, in PDF points: the engine
  /// gets each line scaled to its own size, so big and small writing on
  /// the same page are both read.
  final double letterHeight;
}

/// The plan for one page: the words that need recognising, and every word
/// key on the page now (results for other keys are out of date).
class RecognitionPlan {
  const RecognitionPlan(
    this.lines,
    this.jobs,
    this.keys, [
    this.lineJobs = const [],
  ]);

  final List<InkLine> lines;
  final List<RecognitionJob> jobs;
  final Set<String> keys;

  /// The lines with a word that needs recognising, for engines that read
  /// whole lines (see LineRecognizer).
  final List<LineJob> lineJobs;
}

/// A whole line to send to an engine that reads lines.
class LineJob {
  const LineJob({
    required this.line,
    required this.preContext,
    required this.letterHeight,
  });

  /// Line number on the page, top first.
  final int line;

  /// Recognised text just before the line.
  final String preContext;
  final double letterHeight;
}

/// How many characters of earlier text to pass as context.
const preContextChars = 40;

/// Plans recognition for a page's [strokes], given the text already
/// recognised for each word key in [known]. A known word that [reread]
/// says yes to is read again (e.g. it was read tilted before its slant
/// was noticed).
RecognitionPlan planRecognition(
  List<PageStroke> strokes,
  Map<String, String> known, {
  GroupingParams params = const GroupingParams(),
  bool Function(int index)? include,
  bool Function(String key, InkWord word)? reread,
  Map<String, String>? hints,
  bool Function(List<String> keys)? lineNeedsReading,
  PrintedText? printed,
}) {
  final lines = groupStrokes(
    strokes,
    params: params,
    include: include,
    hints: hints,
    printed: printed,
  );
  final jobs = <RecognitionJob>[];
  final lineJobs = <LineJob>[];
  final keys = <String>{};
  // Each line follows on from the writing above it (see [followsOn]): the
  // text so far of each run of lines, so a note in one margin isn't read
  // as carrying on from a note in the other.
  final after = followsOn(lines, printed: printed);
  final runText = <int, StringBuffer>{};
  String cut(String ctx) => ctx.length > preContextChars
      ? ctx.substring(ctx.length - preContextChars)
      : ctx;
  for (var l = 0; l < lines.length; l++) {
    final above = after[l];
    final before = above == null
        ? StringBuffer()
        : runText.remove(above) ?? StringBuffer();
    runText[l] = before;
    final lineStart = before.toString();
    var lineQueued = false;
    void queueLine() {
      if (lineQueued) return;
      lineQueued = true;
      lineJobs.add(
        LineJob(
          line: l,
          preContext: cut(lineStart),
          letterHeight: lines[l].letterHeight,
        ),
      );
    }

    if (lineNeedsReading?.call([
          for (final w in lines[l].words) wordKey(strokes, w),
        ]) ??
        false) {
      queueLine();
    }
    for (final w in lines[l].words) {
      final key = wordKey(strokes, w);
      keys.add(key);
      final text = (reread?.call(key, w) ?? false) ? null : known[key];
      if (text == null) {
        queueLine();
        final ctx = before.toString();
        jobs.add(
          RecognitionJob(
            key: key,
            word: w,
            line: l,
            preContext: ctx.length > preContextChars
                ? ctx.substring(ctx.length - preContextChars)
                : ctx,
            letterHeight: lines[l].letterHeight,
          ),
        );
      } else {
        if (before.isNotEmpty) before.write(' ');
        before.write(text);
      }
    }
  }
  return RecognitionPlan(lines, jobs, keys, lineJobs);
}

/// For each of [lines] (top first, as [groupStrokes] gives them), the line
/// it follows on from, or null when it starts a new note: the nearest line
/// above it that shares some of its width, with no more than 4 letters of
/// space between and no [printed] text in that space. Lines that don't
/// follow anything (a note in another margin, writing below a printed
/// paragraph) start with no earlier text. Each line is followed by at
/// most one other.
List<int?> followsOn(List<InkLine> lines, {PrintedText? printed}) {
  final out = List<int?>.filled(lines.length, null);
  final taken = <int>{};
  final boxes = [for (final l in lines) l.box];
  for (var l = 0; l < lines.length; l++) {
    final b = boxes[l];
    int? best;
    var bestGap = double.infinity;
    for (var k = l - 1; k >= 0; k--) {
      if (taken.contains(k)) continue;
      final a = boxes[k];
      final h = math.max(lines[k].letterHeight, lines[l].letterHeight);
      final gap = a.bottom - b.top;
      if (gap > h * 4 || gap >= bestGap) continue;
      // Below it (allowing a little overlap: tall and low letters).
      if (b.centerY >= a.bottom || a.centerY <= b.top) continue;
      final shared = math.min(a.right, b.right) - math.max(a.left, b.left);
      if (shared <= 0) continue;
      if (printed != null && !printed.isEmpty && gap > 0) {
        final between = InkBox(
          math.max(a.left, b.left),
          b.top,
          math.min(a.right, b.right),
          a.bottom,
        );
        if (printed.within(between).isNotEmpty) continue;
      }
      best = k;
      bestGap = gap;
    }
    if (best != null) {
      out[l] = best;
      taken.add(best);
    }
  }
  return out;
}

/// One piece of ink the user marked "This isn't writing" (task 2.4c),
/// grouped as a word would be, so it can be shown and unmarked (task 2.4d).
class HiddenInk {
  const HiddenInk(this.ids, this.box);

  /// The [PageStroke.id]s of its strokes.
  final Set<String> ids;
  final InkBox box;
}

/// The marked ink on a page, top to bottom, left to right.
List<HiddenInk> hiddenInk(List<PageStroke> strokes) => [
  for (final line in groupStrokes(
    strokes,
    include: (i) => strokes[i].notWriting,
  ))
    for (final w in line.words)
      HiddenInk({for (final i in w.strokes) strokes[i].id}, w.box),
];

/// The marked ink at ([x], [y]) in PDF page coordinates, allowing [reach]
/// points around it (a pen tap rarely lands exactly on a thin line).
HiddenInk? hiddenInkAt(
  List<PageStroke> strokes,
  double x,
  double y, {
  double reach = 6,
}) {
  for (final h in hiddenInk(strokes)) {
    final b = h.box;
    if (x >= b.left - reach &&
        x <= b.right + reach &&
        y >= b.bottom - reach &&
        y <= b.top + reach) {
      return h;
    }
  }
  return null;
}
