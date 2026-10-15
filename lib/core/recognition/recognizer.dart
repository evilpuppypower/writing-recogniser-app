/// The handwriting recognizer interface (CLAUDE.md rule 1). Every engine
/// (ML Kit, MyScript, a future Windows engine) implements [Recognizer];
/// nothing else in the app knows which engine is in use.
library;

import '../ink.dart';

/// One possible reading of the ink, best first.
class Candidate {
  const Candidate(this.text, {this.score});

  final String text;

  /// Engine-specific confidence or cost, if the engine gives one. Not
  /// comparable between engines.
  final double? score;

  @override
  String toString() => score == null ? text : '$text ($score)';
}

/// Extra information that helps recognition.
class RecognitionContext {
  const RecognitionContext({
    this.preContext = '',
    this.writingAreaWidth,
    this.writingAreaHeight,
  });

  /// Text written just before this ink (e.g. the previous words), which
  /// helps the engine choose between similar-looking words.
  final String preContext;

  /// Size of the writing area in the same units as the ink, if known.
  final double? writingAreaWidth;
  final double? writingAreaHeight;
}

/// Whether an engine can be used right now.
enum RecognizerState {
  /// Ready to recognize.
  ready,

  /// Needs a one-time download (e.g. ML Kit's language model).
  needsDownload,

  /// Needs setup by the user (e.g. MyScript keys in Settings).
  needsSetup,

  /// Can't be used here (e.g. no network for a cloud engine).
  unavailable,
}

class RecognizerStatus {
  const RecognizerStatus(this.state, [this.message = '']);

  final RecognizerState state;

  /// Plain-language explanation for the user when not ready.
  final String message;

  bool get isReady => state == RecognizerState.ready;
}

/// Thrown when recognition fails (network down, engine error, ...).
class RecognitionException implements Exception {
  const RecognitionException(this.message);
  final String message;

  @override
  String toString() => message;
}

abstract class Recognizer {
  /// Short name shown to the user, e.g. "ML Kit".
  String get name;

  /// Whether the ink is processed on the tablet (true) or sent to a server.
  bool get onDevice;

  Future<RecognizerStatus> status();

  /// Does whatever one-time preparation [status] asked for (e.g. download a
  /// model), reporting progress 0..1 when known.
  Future<void> prepare({void Function(double? progress)? onProgress});

  /// Recognizes [strokes]; returns candidates, best first.
  Future<List<Candidate>> recognize(
    List<InkStroke> strokes,
    RecognitionContext context,
  );
}

/// One word of a line read whole: its readings, best first, and which of
/// the strokes sent (indexes) it's made of.
class LineWord {
  const LineWord(this.candidates, this.strokes);

  final List<String> candidates;
  final List<int> strokes;
}

/// An engine that can read a whole line of writing at once and split it
/// into words itself (owner, 2026-10-15: our own splitting cut words into
/// pieces). Optional: engines without it are sent word by word.
abstract class LineRecognizer {
  /// Reads [strokes] (one line) and says which strokes make each word, in
  /// reading order; null if it can't this time (the app then reads word by
  /// word).
  Future<List<LineWord>?> recognizeLine(
    List<InkStroke> strokes,
    RecognitionContext context,
  );
}
