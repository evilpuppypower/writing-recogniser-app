/// Accuracy measures for comparing recognised text with what was written.
/// Pure Dart.
library;

import 'dart:math' as math;

/// Number of single-item insertions, deletions or substitutions needed to
/// turn [a] into [b] (Levenshtein distance).
int editDistance<T>(List<T> a, List<T> b) {
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      cur[j] = math.min(
        math.min(cur[j - 1] + 1, prev[j] + 1),
        prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1),
      );
    }
    prev = cur;
  }
  return prev[b.length];
}

/// How strictly texts are compared.
enum Matching {
  /// Exactly as written: case, spacing and punctuation count.
  strict,

  /// Ignores capital letters, punctuation and extra spaces.
  lenient,
}

String normalise(String s, Matching m) {
  var t = s.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (m == Matching.lenient) {
    t = t
        .toLowerCase()
        .replaceAll(RegExp(r"[^\p{L}\p{N}\s']", unicode: true), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
  return t;
}

List<String> _chars(String s) => s.runes.map(String.fromCharCode).toList();

List<String> _words(String s) =>
    s.isEmpty ? const [] : s.split(' ').where((w) => w.isNotEmpty).toList();

/// Edit counts for one reference/hypothesis pair.
class TextErrors {
  const TextErrors({
    required this.charEdits,
    required this.refChars,
    required this.wordEdits,
    required this.refWords,
  });

  factory TextErrors.of(String reference, String hypothesis, Matching m) {
    final r = normalise(reference, m), h = normalise(hypothesis, m);
    return TextErrors(
      charEdits: editDistance(_chars(r), _chars(h)),
      refChars: _chars(r).length,
      wordEdits: editDistance(_words(r), _words(h)),
      refWords: _words(r).length,
    );
  }

  final int charEdits, refChars, wordEdits, refWords;

  /// Character error rate (0 = perfect; can exceed 1 for very wrong output).
  double get cer => refChars == 0 ? 0 : charEdits / refChars;

  /// Word error rate.
  double get wer => refWords == 0 ? 0 : wordEdits / refWords;

  bool get exact => charEdits == 0;
}
