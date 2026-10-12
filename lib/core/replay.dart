/// The Phase 3 replay harness (task 3.1): re-runs saved handwritten words
/// through (a) the engine alone and (b) the engine plus the feedback layer,
/// learning from corrections as it goes, as the user would. Reports word
/// and character error rates, split into words seen before (repeated
/// vocabulary) and new words (held out), and corrections per 100 words
/// over time. Pure Dart.
library;

import 'feedback/correction.dart';
import 'feedback/feedback_layer.dart';
import 'ink.dart';
import 'recognition/recognizer.dart';
import 'text_metrics.dart';

/// One handwritten word with what it really says, in the order written.
class ReplayCase {
  const ReplayCase({
    required this.strokes,
    required this.truth,
    required this.at,
    this.previousWord = '',
    this.documentId,
  });

  final List<InkStroke> strokes;
  final String truth;
  final String previousWord;
  final DateTime at;
  final String? documentId;
}

class ReplayStep {
  const ReplayStep({
    required this.truth,
    required this.engine,
    required this.withFeedback,
    required this.seenBefore,
    required this.autoReplaced,
  });

  final String truth;

  /// The engine's top word, and the word after the feedback layer.
  final String engine;
  final String withFeedback;

  /// The true word appeared earlier in the replay (repeated vocabulary).
  final bool seenBefore;
  final bool autoReplaced;

  /// The user would have had to correct the word shown.
  bool get needsCorrection =>
      normalise(withFeedback, Matching.lenient) !=
      normalise(truth, Matching.lenient);
}

class ReplayReport {
  ReplayReport(this.steps);

  final List<ReplayStep> steps;

  /// Character error rate of the engine alone or with feedback, optionally
  /// only for words seen before ([repeated] true) or new ([repeated] false).
  double cer({required bool feedback, bool? repeated}) {
    var edits = 0, chars = 0;
    for (final s in _pick(repeated)) {
      final e = TextErrors.of(
        s.truth,
        feedback ? s.withFeedback : s.engine,
        Matching.lenient,
      );
      edits += e.charEdits;
      chars += e.refChars;
    }
    return chars == 0 ? 0 : edits / chars;
  }

  /// Share of words wrong (each case is one word).
  double wer({required bool feedback, bool? repeated}) {
    final picked = _pick(repeated).toList();
    if (picked.isEmpty) return 0;
    final wrong = picked.where(
      (s) =>
          normalise(feedback ? s.withFeedback : s.engine, Matching.lenient) !=
          normalise(s.truth, Matching.lenient),
    );
    return wrong.length / picked.length;
  }

  /// Corrections needed per 100 words, in consecutive windows of [window]
  /// words: should fall over time if the layer learns.
  List<double> correctionsPer100({int window = 100}) => [
    for (var i = 0; i < steps.length; i += window)
      () {
        final w = steps.skip(i).take(window).toList();
        return 100 * w.where((s) => s.needsCorrection).length / w.length;
      }(),
  ];

  /// GATE B measure: how many fewer of the words seen before needed fixing
  /// with the feedback layer than with the engine alone (0.33 = a third
  /// fewer). Null until the engine got a repeated word wrong.
  double? get repeatedImprovement {
    final repeated = _pick(true).toList();
    bool wrong(String shown, String truth) =>
        normalise(shown, Matching.lenient) !=
        normalise(truth, Matching.lenient);
    final engine = repeated.where((s) => wrong(s.engine, s.truth)).length;
    if (engine == 0) return null;
    final shown = repeated.where((s) => s.needsCorrection).length;
    return 1 - shown / engine;
  }

  Iterable<ReplayStep> _pick(bool? repeated) =>
      repeated == null ? steps : steps.where((s) => s.seenBefore == repeated);
}

/// Replays [cases] in order through [engine] and [layer]. After each word
/// the layer shows wrongly, the correction is taught to the layer, so later
/// words benefit, as in real use. Reports progress after each word, and
/// stops early (with the words done so far) once [cancelled] says so.
Future<ReplayReport> replay(
  List<ReplayCase> cases,
  Recognizer engine,
  FeedbackLayer layer, {
  void Function(int done, int total)? onProgress,
  bool Function()? cancelled,
}) async {
  final steps = <ReplayStep>[];
  final seen = <String>{};
  for (final c in cases) {
    if (cancelled?.call() ?? false) break;
    List<Candidate> candidates;
    try {
      candidates = await engine.recognize(
        c.strokes,
        RecognitionContext(preContext: c.previousWord),
      );
    } on RecognitionException {
      candidates = const [];
    }
    final engineTop = candidates.isEmpty ? '' : candidates.first.text;
    final result = layer.apply(
      candidates,
      FeedbackContext(previousWord: c.previousWord, documentId: c.documentId),
    );
    final key = normalise(c.truth, Matching.lenient);
    final step = ReplayStep(
      truth: c.truth,
      engine: engineTop,
      withFeedback: result.text,
      seenBefore: seen.contains(key),
      autoReplaced: result.autoReplaced,
    );
    steps.add(step);
    seen.add(key);
    if (step.needsCorrection && engineTop.isNotEmpty) {
      layer.learn(
        CorrectionRecord(
          recognized: engineTop,
          corrected: c.truth,
          previousWord: c.previousWord,
          strokes: c.strokes,
          at: c.at,
          documentId: c.documentId,
        ),
      );
    }
    onProgress?.call(steps.length, cases.length);
  }
  return ReplayReport(steps);
}
