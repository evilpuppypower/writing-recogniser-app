/// Personal re-ranking (owner's approved idea 2, 2026-10-16: "an app that
/// gets easier to use the more it learns about the user"). When the engine
/// isn't sure, the user's own words win: if its first reading is a word
/// the user has never written, and one of its next readings is a word they
/// write often, that one is shown instead (underlined, one tap to undo).
/// Works with any engine and on top of any other layer. Pure Dart.
library;

import '../recognition/recognizer.dart';
import 'correction.dart';
import 'feedback_layer.dart';

class PersonalWords implements FeedbackLayer {
  PersonalWords({FeedbackLayer? inner, this.minUses = 3, this.lookAt = 3})
    : inner = inner ?? CorrectionMemory();

  /// Applied first; when it changes the engine's reading, that stands.
  final FeedbackLayer inner;

  /// How often the user must have written a word before it's preferred.
  final int minUses;

  /// How many of the engine's readings are looked at (the first included):
  /// only readings it thought likely, never a far-fetched one.
  final int lookAt;

  final _uses = <String, int>{};
  final _after = <String, int>{}; // "previous next" -> times
  final _refused = <String>{}; // "engine shown" pairs the user undid

  static String _key(String s) => s.trim().toLowerCase();

  /// How often the user has written [word].
  int usesOf(String word) => _uses[_key(word)] ?? 0;

  /// The user wrote [word] (after [previousWord]): it's in their
  /// vocabulary.
  @override
  void used(String word, {String previousWord = ''}) {
    final w = _key(word);
    if (w.isEmpty) return;
    _uses[w] = (_uses[w] ?? 0) + 1;
    final p = _key(previousWord);
    if (p.isNotEmpty) _after['$p $w'] = (_after['$p $w'] ?? 0) + 1;
  }

  @override
  void learn(CorrectionRecord correction) {
    inner.learn(correction);
    // A word the user typed in themselves is one they write.
    used(correction.corrected, previousWord: correction.previousWord);
  }

  @override
  void undone(String engineText, String shown) {
    inner.undone(engineText, shown);
    _refused.add('${_key(engineText)} ${_key(shown)}');
  }

  @override
  FeedbackResult apply(List<Candidate> candidates, FeedbackContext context) {
    final r = inner.apply(candidates, context);
    if (candidates.isEmpty ||
        r.autoReplaced ||
        _key(r.text) != _key(candidates.first.text)) {
      return r;
    }
    final top = candidates.first.text;
    if (usesOf(top) > 0) return r; // a word they write: trust the engine
    final prev = _key(context.previousWord);
    double score(String w) =>
        usesOf(w) + 2.0 * (prev.isEmpty ? 0 : _after['$prev ${_key(w)}'] ?? 0);
    Candidate? best;
    var bestScore = 0.0;
    for (final c in r.candidates.skip(1).take(lookAt - 1)) {
      if (usesOf(c.text) < minUses) continue;
      if (_refused.contains('${_key(top)} ${_key(c.text)}')) continue;
      final s = score(c.text);
      if (s > bestScore) {
        bestScore = s;
        best = c;
      }
    }
    if (best == null) return r;
    return FeedbackResult([
      best,
      for (final c in r.candidates)
        if (!identical(c, best)) c,
    ], autoReplaced: true);
  }
}
