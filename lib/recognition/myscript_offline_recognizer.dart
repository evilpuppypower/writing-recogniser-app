import 'dart:convert';

import 'package:flutter/services.dart';

import '../core/ink.dart';
import '../core/recognition/recognizer.dart';
import 'jiix.dart';

/// MyScript iink running on the tablet (Android native SDK). No internet and
/// no quota; nothing leaves the device. Needs the owner's certificate and
/// MyScript's English recognition files, both added to the APK by CI.
class MyScriptOfflineRecognizer implements Recognizer, LineRecognizer {
  MyScriptOfflineRecognizer({
    this.channel = const MethodChannel('writing_recogniser/myscript_offline'),
  });

  final MethodChannel channel;

  /// Language in use once ready, e.g. "en_GB".
  String? language;

  /// Millimetres per point sent (from the engine), to match the words'
  /// boxes to strokes; null from older builds (lines are then read word by
  /// word).
  double? mmPerX, mmPerY;
  bool _noBoxes = false;

  @override
  String get name => 'MyScript offline';

  @override
  bool get onDevice => true;

  @override
  Future<RecognizerStatus> status() async {
    try {
      final m = await channel.invokeMapMethod<String, Object?>('status');
      final state = m?['state'] as String?;
      final message = (m?['message'] as String?) ?? '';
      if (state == 'ready') {
        language = m?['lang'] as String?;
        mmPerX = (m?['mmPerPxX'] as num?)?.toDouble();
        mmPerY = (m?['mmPerPxY'] as num?)?.toDouble();
        return const RecognizerStatus(RecognizerState.ready);
      }
      return RecognizerStatus(RecognizerState.unavailable, message);
    } on MissingPluginException {
      return const RecognizerStatus(
        RecognizerState.unavailable,
        'MyScript offline only works in the Android app.',
      );
    } on PlatformException catch (e) {
      return RecognizerStatus(
        RecognizerState.unavailable,
        e.message ?? 'MyScript offline is not available.',
      );
    }
  }

  @override
  Future<void> prepare({void Function(double? progress)? onProgress}) async {}

  @override
  Future<List<Candidate>> recognize(
    List<InkStroke> strokes,
    RecognitionContext context,
  ) async {
    if (strokes.isEmpty) return const [];
    try {
      final jiix = await channel.invokeMethod<String>('recognize', {
        'strokes': encodeStrokesFlat(strokes),
      });
      if (jiix == null || jiix.isEmpty) return const [];
      final decoded = jsonDecode(jiix);
      return decoded is Map<String, Object?>
          ? jiixToCandidates(decoded)
          : const [];
    } on PlatformException catch (e) {
      throw RecognitionException(e.message ?? 'MyScript offline failed.');
    } on FormatException {
      throw const RecognitionException('MyScript gave an unreadable answer.');
    }
  }

  @override
  Future<List<LineWord>?> recognizeLine(
    List<InkStroke> strokes,
    RecognitionContext context,
  ) async {
    final sx = mmPerX, sy = mmPerY;
    if (strokes.isEmpty || sx == null || sy == null || _noBoxes) return null;
    try {
      final jiix = await channel.invokeMethod<String>('recognize', {
        'strokes': encodeStrokesFlat(strokes),
      });
      if (jiix == null || jiix.isEmpty) return null;
      final decoded = jsonDecode(jiix);
      if (decoded is! Map<String, Object?>) return null;
      // An engine whose answers have no word boxes never will: stop asking
      // (lines are then read word by word, with no extra call).
      final words = decoded['words'];
      if (words is List &&
          words.any(
            (w) =>
                w is Map &&
                '${w['label'] ?? ''}'.trim().isNotEmpty &&
                w['bounding-box'] == null,
          )) {
        _noBoxes = true;
        return null;
      }
      return jiixLineWords(decoded, strokes, mmPerX: sx, mmPerY: sy);
    } on PlatformException catch (e) {
      throw RecognitionException(e.message ?? 'MyScript offline failed.');
    } on FormatException {
      return null;
    }
  }
}

/// Each stroke as one flat list: x, y, t (ms), pressure, repeated. Compact
/// for the platform channel.
List<List<num>> encodeStrokesFlat(List<InkStroke> strokes) => [
  for (final s in strokes)
    [
      for (final p in s.points) ...[p.x, p.y, p.t, p.pressure],
    ],
];
