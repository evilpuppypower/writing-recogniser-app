/// Which English the app reads handwriting in (owner, 2026-10-24: "British
/// English … with the option to follow or change the regional variation").
/// The engine's readings are put into that spelling ("color" becomes
/// "colour") before the user's own corrections are applied, so it works
/// with any engine (rule 2). What the engine itself read is kept as it was
/// (rule 4). Pure Dart.
library;

import '../recognition/recognizer.dart';
import 'correction.dart';
import 'feedback_layer.dart';

enum EnglishSpelling {
  british('British'),
  american('American'),
  canadian('Canadian'),
  tablet("The tablet's");

  const EnglishSpelling(this.label);
  final String label;
}

/// [s], with "the tablet's" settled by the tablet's region ([country], e.g.
/// "GB"): American or Canadian where those are used, British otherwise.
EnglishSpelling settledSpelling(EnglishSpelling s, String? country) =>
    s != EnglishSpelling.tablet
    ? s
    : switch (country?.toUpperCase()) {
        'US' || 'PR' || 'PH' => EnglishSpelling.american,
        'CA' => EnglishSpelling.canadian,
        _ => EnglishSpelling.british,
      };

/// Each word's spelling in American, British and Canadian English (from VarCon, see tool/spellings/). Words with two meanings
/// spelt differently aren't in it, so a word is only changed when that's
/// always right.
class SpellingTable {
  SpellingTable._(this._rows, this._rowOf);

  /// The table from its file: one word a line, its spellings (American,
  /// British, Canadian) separated by tabs.
  factory SpellingTable.parse(String text) {
    final rows = <List<String>>[];
    final rowOf = <String, int>{};
    for (final line in text.split('\n')) {
      final r = line.trim().split('\t');
      if (r.length != 3 || r.any((w) => w.isEmpty)) continue;
      final i = rows.length;
      rows.add(r);
      for (final w in r) {
        rowOf.putIfAbsent(w.toLowerCase(), () => i);
      }
    }
    return SpellingTable._(rows, rowOf);
  }

  final List<List<String>> _rows;
  final Map<String, int> _rowOf;

  int get length => _rows.length;

  static final _word = RegExp(r"[A-Za-z][A-Za-z']*");

  /// [text] with each word spelt as in [to] (case kept: "Color" becomes
  /// "Colour", "COLOR" "COLOUR"); [EnglishSpelling.tablet] must be settled
  /// first (see [settledSpelling]).
  String respell(String text, EnglishSpelling to) {
    final column = switch (to) {
      EnglishSpelling.american => 0,
      EnglishSpelling.british || EnglishSpelling.tablet => 1,
      EnglishSpelling.canadian => 2,
    };
    return text.replaceAllMapped(_word, (m) {
      final w = m[0]!;
      final i = _rowOf[w.toLowerCase()];
      if (i == null) return w;
      final out = _rows[i][column];
      if (out.toLowerCase() == w.toLowerCase()) return w;
      if (w == w.toUpperCase() && w.length > 1) return out.toUpperCase();
      if (w[0] == w[0].toUpperCase()) {
        return out[0].toUpperCase() + out.substring(1);
      }
      return out;
    });
  }
}

/// Puts the engine's readings into the chosen English ([spelling]; the
/// [table] while it's still loading is null, and nothing changes), then
/// hands them to [inner] (the user's corrections and words).
class RegionalSpelling implements FeedbackLayer {
  RegionalSpelling(
    this.inner, {
    EnglishSpelling Function()? spelling,
    SpellingTable? Function()? table,
  }) : _spelling = spelling ?? (() => current),
       _table = table ?? (() => loaded);

  final FeedbackLayer inner;
  final EnglishSpelling Function() _spelling;
  final SpellingTable? Function() _table;

  /// The app's choice (settled), set from Settings.
  static EnglishSpelling current = EnglishSpelling.british;

  /// The app's table, once loaded.
  static SpellingTable? loaded;

  @override
  FeedbackResult apply(List<Candidate> candidates, FeedbackContext context) {
    final table = _table();
    if (table == null) return inner.apply(candidates, context);
    final to = _spelling();
    final seen = <String>{};
    final respelt = [
      for (final c in candidates)
        if (Candidate(table.respell(c.text, to), score: c.score) case final r
            when seen.add(r.text))
          r,
    ];
    return inner.apply(respelt, context);
  }

  @override
  void learn(CorrectionRecord correction) => inner.learn(correction);

  @override
  void used(String word, {String previousWord = ''}) =>
      inner.used(word, previousWord: previousWord);

  @override
  void undone(String engineText, String shown) =>
      inner.undone(engineText, shown);
}
