/// "How well is it learning?" (task 3.1): numbers from real use, worked out
/// from the event log on the tablet. Pure Dart.
///
/// For every word read on a PDF it compares three versions:
///  - what the engine read on its own,
///  - what was shown (after the feedback layer's swaps),
///  - the final text: the user's correction, or what was shown if they let
///    it stand.
/// So "engine alone" vs "with your corrections" needs no re-reading: it's
/// a fair comparison, because the feedback layer only ever learnt from
/// corrections made before each word was read.
library;

import 'event_log.dart';
import 'text_metrics.dart';

/// One word's history.
class WordOutcome {
  WordOutcome({
    required this.at,
    required this.engine,
    required this.shown,
    required this.autoReplaced,
    this.latencyMs,
  }) : finalText = shown;

  final DateTime at;
  final String engine, shown;
  final bool autoReplaced;
  final int? latencyMs;

  String finalText;
  bool corrected = false;
  bool swapUndone = false;

  /// Written before (by its final text), when it was read.
  bool repeated = false;

  bool get engineWrong => _norm(engine) != _norm(finalText);
  bool get shownWrong => _norm(shown) != _norm(finalText);

  static String _norm(String s) => s.trim().toLowerCase();
}

/// Word and character error rates for a set of words.
class ErrorRates {
  const ErrorRates(this.words, this.wrongWords, this.charEdits, this.chars);

  final int words, wrongWords, charEdits, chars;

  double? get wordRate => words == 0 ? null : wrongWords / words;
  double? get charRate => chars == 0 ? null : charEdits / chars;

  static ErrorRates of(
    Iterable<WordOutcome> words,
    String Function(WordOutcome) read,
  ) {
    var n = 0, wrong = 0, edits = 0, chars = 0;
    for (final w in words) {
      final r = read(w).trim().toLowerCase();
      final f = w.finalText.trim().toLowerCase();
      n++;
      if (r != f) wrong++;
      edits += editDistance(r.split(''), f.split(''));
      chars += f.length;
    }
    return ErrorRates(n, wrong, edits, chars);
  }
}

/// Words read and corrections made in one week (starting Monday).
class WeekRow {
  WeekRow(this.monday);

  final DateTime monday;
  int words = 0;
  int corrections = 0;

  double? get correctionsPer100 =>
      words == 0 ? null : corrections * 100 / words;
}

class LearningStats {
  LearningStats._(this.words, this.weeks);

  /// Words read, in reading order (only those logged with the details this
  /// screen needs; older log entries are skipped).
  final List<WordOutcome> words;

  /// Oldest week first.
  final List<WeekRow> weeks;

  ErrorRates get engineAlone => ErrorRates.of(words, (w) => w.engine);
  ErrorRates get withCorrections => ErrorRates.of(words, (w) => w.shown);

  Iterable<WordOutcome> get repeatedWords => words.where((w) => w.repeated);
  Iterable<WordOutcome> get newWords => words.where((w) => !w.repeated);

  /// GATE B measure: how many fewer of the words written before needed
  /// fixing, compared with the engine alone (0.33 = a third fewer). Null
  /// until there are repeated words the engine got wrong.
  double? get repeatedImprovement {
    final engine = ErrorRates.of(repeatedWords, (w) => w.engine).wrongWords;
    if (engine == 0) return null;
    final shown = ErrorRates.of(repeatedWords, (w) => w.shown).wrongWords;
    return 1 - shown / engine;
  }

  int get swaps => words.where((w) => w.autoReplaced).length;
  int get swapsUndone => words.where((w) => w.swapUndone).length;

  /// Middle pen-lift-to-text time, in ms.
  int? get medianLatencyMs {
    final ms = [for (final w in words) ?w.latencyMs]..sort();
    return ms.isEmpty ? null : ms[ms.length ~/ 2];
  }

  /// Works the numbers out from the log's 'recognition', 'correction' and
  /// 'not_writing' events (any order; they're sorted by time).
  factory LearningStats.fromEvents(Iterable<LoggedEvent> events) {
    final sorted = events.toList()..sort((a, b) => a.at.compareTo(b.at));
    final byWord = <String, WordOutcome>{};
    // Which word each stroke belongs to ("doc|page|stroke id" -> word key).
    final strokeOwner = <String, String>{};
    final order = <WordOutcome>[];
    final weeks = <DateTime, WeekRow>{};
    WeekRow week(DateTime t) {
      // Calendar maths, not hours, so clock changes can't shift the day.
      final monday = DateTime(t.year, t.month, t.day - (t.weekday - 1));
      return weeks.putIfAbsent(monday, () => WeekRow(monday));
    }

    String? id(LoggedEvent e) {
      final word = e.data['word'];
      if (word is! String || word.isEmpty) return null;
      return '${e.data['doc'] ?? ''}|${e.data['page'] ?? ''}|$word';
    }

    for (final e in sorted) {
      final key = id(e);
      if (key == null) continue;
      switch (e.type) {
        case 'recognition':
          final engine = e.data['engineText'], shown = e.data['text'];
          if (engine is! String || shown is! String) continue;
          final w = WordOutcome(
            at: e.at,
            engine: engine,
            shown: shown,
            autoReplaced: e.data['autoReplaced'] == true,
            latencyMs: e.latencyMs,
          );
          // The same word read again (e.g. the PDF was reopened): the first
          // reading, and any correction of it, is what counts.
          if (byWord.containsKey(key)) continue;
          // A word that grew or shrank (an i-dot added later, a word
          // written in two goes, part rubbed out) replaces the earlier
          // reading of any of its strokes.
          final place = key.substring(0, key.lastIndexOf('|') + 1);
          for (final stroke in key.substring(place.length).split(',')) {
            final earlier = strokeOwner.remove('$place$stroke');
            if (earlier == null) continue;
            final old = byWord.remove(earlier);
            if (old != null && order.remove(old)) week(old.at).words--;
          }
          for (final stroke in key.substring(place.length).split(',')) {
            strokeOwner['$place$stroke'] = key;
          }
          byWord[key] = w;
          order.add(w);
          week(e.at).words++;
        case 'correction':
          final w = byWord[key];
          final text = e.data['corrected'];
          if (w == null || text is! String) continue;
          w.finalText = text;
          w.corrected = true;
          if (e.data['undo'] == true && w.autoReplaced) w.swapUndone = true;
          week(e.at).corrections++;
        case 'not_writing':
          final w = byWord.remove(key);
          if (w != null && order.remove(w)) week(w.at).words--;
      }
    }

    // "Written before": by final text, in reading order.
    final seen = <String>{};
    for (final w in order) {
      final t = w.finalText.trim().toLowerCase();
      w.repeated = seen.contains(t);
      seen.add(t);
    }
    final weekList = weeks.values.toList()
      ..sort((a, b) => a.monday.compareTo(b.monday));
    return LearningStats._(order, weekList);
  }

  /// One row per word, oldest first, for a spreadsheet.
  String toCsv() {
    String q(String s) {
      // A cell starting with = + - @ would run as a formula in a
      // spreadsheet; a leading ' keeps it as text.
      if (RegExp(r'^[=+\-@\t\r]').hasMatch(s)) s = "'$s";
      return RegExp(r'[",\r\n]').hasMatch(s)
          ? '"${s.replaceAll('"', '""')}"'
          : s;
    }

    String two(int n) => n.toString().padLeft(2, '0');
    final b = StringBuffer(
      'time,engine read,shown,final,corrected,swapped,swap undone,'
      'written before,pen lift to text (ms)\n',
    );
    for (final w in words) {
      final t = w.at;
      b.writeln(
        [
          '${t.year}-${two(t.month)}-${two(t.day)} '
              '${two(t.hour)}:${two(t.minute)}:${two(t.second)}',
          q(w.engine),
          q(w.shown),
          q(w.finalText),
          w.corrected ? 'yes' : 'no',
          w.autoReplaced ? 'yes' : 'no',
          w.swapUndone ? 'yes' : 'no',
          w.repeated ? 'yes' : 'no',
          w.latencyMs?.toString() ?? '',
        ].join(','),
      );
    }
    return b.toString();
  }
}
