/// The feedback layer (task 2.6, CLAUDE.md rule 2): sits between the
/// recognizer and the screen and uses the user's corrections to re-rank or
/// replace the engine's candidates. Works with any engine. Pure Dart.
library;

import '../recognition/recognizer.dart';
import 'correction.dart';

class FeedbackContext {
  const FeedbackContext({this.previousWord = '', this.documentId});

  final String previousWord;
  final String? documentId;
}

class FeedbackResult {
  const FeedbackResult(this.candidates, {this.autoReplaced = false});

  /// Candidates after re-ranking, best first.
  final List<Candidate> candidates;

  /// The top word was swapped automatically (shown underlined, undoable).
  final bool autoReplaced;

  String get text => candidates.isEmpty ? '' : candidates.first.text;
}

abstract class FeedbackLayer {
  FeedbackResult apply(List<Candidate> candidates, FeedbackContext context);

  /// Remembers a correction; it affects only words recognised from now on.
  void learn(CorrectionRecord correction);

  /// The user wrote [word] (after [previousWord]) and kept it: it's in
  /// their vocabulary (see PersonalWords).
  void used(String word, {String previousWord = ''});

  /// The user undid an automatic swap: [shown] went back to the engine's
  /// [engineText].
  void undone(String engineText, String shown);
}

/// Changes nothing (the "engine only" baseline for Phase 3).
class PassThroughFeedback implements FeedbackLayer {
  const PassThroughFeedback();

  @override
  FeedbackResult apply(List<Candidate> candidates, FeedbackContext context) =>
      FeedbackResult(candidates);

  @override
  void learn(CorrectionRecord correction) {}

  @override
  void used(String word, {String previousWord = ''}) {}

  @override
  void undone(String engineText, String shown) {}
}

/// The owner's rule (plan 2.6): once a word has been corrected
/// [autoReplaceAfter] times, the correction replaces the engine's word
/// automatically (owner, 2026-10-11: from the next time after the first
/// correction, to be reviewed once testable). Below that, the user's word
/// is preferred (moved to the top if the engine offered it, otherwise
/// offered as the first alternative). A correction made after the same
/// previous word counts double there (context-aware matching).
class CorrectionMemory implements FeedbackLayer {
  CorrectionMemory({this.autoReplaceAfter = 1});

  /// Corrections needed before the swap is automatic (1 = swap the very
  /// next time; 2 = the original plan).
  final int autoReplaceAfter;

  final _memory = <String, Map<String, _Seen>>{};

  static String _key(String s) => s.trim().toLowerCase();

  @override
  void used(String word, {String previousWord = ''}) {}

  @override
  void undone(String engineText, String shown) {}

  @override
  void learn(CorrectionRecord c) {
    final from = _key(c.recognized), to = c.corrected.trim();
    if (from.isEmpty || to.isEmpty || from == _key(to)) return;
    final seen = _memory
        .putIfAbsent(from, () => {})
        .putIfAbsent(to, () => _Seen());
    seen.count++;
    final ctx = _key(c.previousWord);
    if (ctx.isNotEmpty) seen.contexts[ctx] = (seen.contexts[ctx] ?? 0) + 1;
    if (c.scope == CorrectionScope.document && c.documentId != null) {
      seen.onlyIn.add(c.documentId!);
    } else {
      seen.global = true;
    }
  }

  @override
  FeedbackResult apply(List<Candidate> candidates, FeedbackContext context) {
    if (candidates.isEmpty) return FeedbackResult(candidates);
    final top = candidates.first.text;
    final options = _memory[_key(top)];
    if (options == null) return FeedbackResult(candidates);

    // The user's most-used correction for this word that applies here.
    String? best;
    var bestScore = 0;
    final ctx = _key(context.previousWord);
    for (final e in options.entries) {
      final s = e.value;
      final applies =
          s.global ||
          (context.documentId != null && s.onlyIn.contains(context.documentId));
      if (!applies) continue;
      final score = s.count + (ctx.isNotEmpty ? s.contexts[ctx] ?? 0 : 0);
      if (score > bestScore) {
        bestScore = score;
        best = e.key;
      }
    }
    final chosen = best;
    if (chosen == null) return FeedbackResult(candidates);

    final rest = [
      for (final c in candidates)
        if (_key(c.text) != _key(chosen)) c,
    ];
    if (bestScore >= autoReplaceAfter) {
      return FeedbackResult([Candidate(chosen), ...rest], autoReplaced: true);
    }
    final offered = candidates.any((c) => _key(c.text) == _key(chosen));
    return FeedbackResult(
      offered
          ? [Candidate(chosen), ...rest]
          : [rest.first, Candidate(chosen), ...rest.skip(1)],
    );
  }
}

class _Seen {
  int count = 0;
  bool global = false;
  final onlyIn = <String>{};
  final contexts = <String, int>{};
}
