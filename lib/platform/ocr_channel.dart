import 'package:flutter/services.dart';

import '../core/ocr_models.dart';
import '../core/transfer_estimate.dart' show TransferEstimator;

/// A line of text read from a page image, in its pixels.
typedef OcrLine = ({
  int left,
  int top,
  int right,
  int bottom,
  String text,
  double confidence,
});

/// Reading scanned pages (OcrEngine.kt), behind an interface so another
/// engine (or a fake in tests) can take its place.
abstract class TextReaderService {
  Future<Set<String>> installed();

  /// Each downloaded model's files and their SHA-256 (see
  /// [OcrModel.matches]); a model missing here isn't known to differ.
  Future<Map<String, Map<String, String>>> fingerprints();

  /// Downloads [model]'s files; [progress] gets bytes done and the total
  /// (-1 if unknown). Throws if a file isn't the one expected.
  Future<void> download(
    OcrModel model, {
    void Function(int done, int total)? progress,
  });

  Future<void> cancel();

  Future<void> remove(String id);

  /// The lines of text in an image ([bgra], [width] x [height], blue,
  /// green, red, alpha bytes as PDFium draws a page).
  Future<List<OcrLine>> read(String id, int width, int height, Uint8List bgra);
}

class AndroidTextReader implements TextReaderService {
  const AndroidTextReader();

  static const _channel = MethodChannel('writing_recogniser/ocr');

  @override
  Future<Set<String>> installed() async =>
      ((await _channel.invokeListMethod<String>('installed')) ?? const [])
          .toSet();

  @override
  Future<Map<String, Map<String, String>>> fingerprints() async {
    final m = await _channel.invokeMapMethod<String, Object?>('fingerprints');
    return {
      for (final e in (m ?? const {}).entries)
        e.key: Map<String, String>.from(e.value! as Map),
    };
  }

  @override
  Future<void> download(
    OcrModel model, {
    void Function(int done, int total)? progress,
  }) async {
    if (!model.ready) {
      throw StateError("This model's files aren't checked yet");
    }
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'progress') return;
      final a = (call.arguments as Map).cast<String, Object?>();
      progress?.call((a['done']! as num).toInt(), (a['total']! as num).toInt());
    });
    try {
      await _channel.invokeMethod<void>('download', {
        'id': model.id,
        'files': [
          for (final f in model.files)
            {'name': f.name, 'url': f.url, 'sha256': f.sha256},
        ],
      });
    } finally {
      _channel.setMethodCallHandler(null);
    }
  }

  @override
  Future<void> cancel() => _channel.invokeMethod<void>('cancel');

  @override
  Future<void> remove(String id) =>
      _channel.invokeMethod<void>('remove', {'id': id});

  @override
  Future<List<OcrLine>> read(
    String id,
    int width,
    int height,
    Uint8List bgra,
  ) async {
    final list =
        await _channel.invokeListMethod<Map<Object?, Object?>>('read', {
          'id': id,
          'width': width,
          'height': height,
          'pixels': bgra,
        }) ??
        const [];
    return [
      for (final m in list)
        (
          left: (m['left']! as num).toInt(),
          top: (m['top']! as num).toInt(),
          right: (m['right']! as num).toInt(),
          bottom: (m['bottom']! as num).toInt(),
          text: m['text']! as String,
          confidence: (m['confidence']! as num).toDouble(),
        ),
    ];
  }
}

/// Keeps a download's time left (see [TransferEstimator]).
TransferEstimator downloadEstimate(int total) =>
    TransferEstimator(totalBytes: total, smoothing: 0.2);
