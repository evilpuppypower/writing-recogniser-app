// The ONLY file that may import ML Kit (CLAUDE.md rule 1).

import 'package:google_mlkit_digital_ink_recognition/google_mlkit_digital_ink_recognition.dart'
    as mlkit;

import '../core/ink.dart';
import '../core/recognition/recognizer.dart';
import '../platform/diagnostics.dart';
import '../core/feedback/regional_spelling.dart';

/// Google ML Kit Digital Ink Recognition. Runs on the tablet; needs a
/// one-time download of the English model (about 20 MB) from Google.
/// Only the model is downloaded; ink never leaves the device.
class MlKitRecognizer implements Recognizer {
  MlKitRecognizer({this.languageChoice});

  /// Variants to try instead of the English chosen in Settings (tests).
  final List<String>? languageChoice;

  /// Preferred English variants, best first; the first one ML Kit supports
  /// is used: the English chosen in Settings (see RegionalSpelling).
  List<String> get languageTags =>
      languageChoice ?? englishTagsFor(RegionalSpelling.current);

  /// [spelling]'s English first, then British, US and plain English.
  static List<String> englishTagsFor(EnglishSpelling spelling) => {
    switch (spelling) {
      EnglishSpelling.american => 'en-US',
      EnglishSpelling.canadian => 'en-CA',
      EnglishSpelling.british || EnglishSpelling.tablet => 'en-GB',
    },
    'en-GB',
    'en-US',
    'en',
  }.toList();

  final _models = mlkit.DigitalInkRecognizerModelManager();
  mlkit.DigitalInkRecognizer? _recognizer;
  String? _tag;

  @override
  String get name => 'ML Kit';

  @override
  bool get onDevice => true;

  /// The language model in use, once known (e.g. "en-GB").
  String? get languageTag => _tag;

  Future<String?> _downloadedTag() async {
    for (final tag in languageTags) {
      try {
        if (await _models.isModelDownloaded(tag)) return tag;
      } catch (_) {
        // Unsupported tag on this ML Kit version; try the next.
      }
    }
    return null;
  }

  @override
  Future<RecognizerStatus> status() async {
    final startError = await mlKitStartError();
    if (startError != null) {
      return RecognizerStatus(
        RecognizerState.unavailable,
        "ML Kit couldn't start on this tablet. Please send this to "
        'Claude: $startError',
      );
    }
    _tag ??= await _downloadedTag();
    return _tag != null
        ? const RecognizerStatus(RecognizerState.ready)
        : const RecognizerStatus(
            RecognizerState.needsDownload,
            'ML Kit needs to download its English handwriting model once '
            '(about 20 MB, from Google). After that it works offline. '
            'Your writing is never sent anywhere.',
          );
  }

  @override
  Future<void> prepare({void Function(double? progress)? onProgress}) async {
    onProgress?.call(null); // ML Kit doesn't report download progress
    Object? lastError;
    for (final tag in languageTags) {
      try {
        if (await _models.downloadModel(tag, isWifiRequired: false)) {
          _tag = tag;
          return;
        }
      } catch (e) {
        lastError = e;
      }
    }
    throw RecognitionException(
      "Couldn't download the handwriting model. Check the internet "
      'connection and try again. ($lastError)',
    );
  }

  @override
  Future<List<Candidate>> recognize(
    List<InkStroke> strokes,
    RecognitionContext context,
  ) async {
    final tag = _tag ?? await _downloadedTag();
    if (tag == null) {
      throw const RecognitionException('The model is not downloaded yet.');
    }
    _tag = tag;
    final recognizer = _recognizer ??= mlkit.DigitalInkRecognizer(
      languageCode: tag,
    );
    final ink = mlkit.Ink()
      ..strokes = [
        for (final s in strokes)
          mlkit.Stroke()
            ..points = [
              for (final p in s.points)
                mlkit.StrokePoint(x: p.x, y: p.y, t: p.t),
            ],
      ];
    final w = context.writingAreaWidth, h = context.writingAreaHeight;
    final mlContext = mlkit.DigitalInkRecognitionContext(
      preContext: context.preContext.isEmpty ? null : context.preContext,
      writingArea: w != null && h != null
          ? mlkit.WritingArea(width: w, height: h)
          : null,
    );
    try {
      final result = await recognizer.recognize(ink, context: mlContext);
      return [for (final c in result) Candidate(c.text, score: c.score)];
    } catch (e) {
      throw RecognitionException('ML Kit failed: $e');
    }
  }
}
