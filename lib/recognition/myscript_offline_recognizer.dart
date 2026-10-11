import 'dart:convert';

import 'package:flutter/services.dart';

import '../core/ink.dart';
import '../core/recognition/recognizer.dart';
import 'jiix.dart';

/// MyScript iink running on the tablet (Android native SDK). No internet and
/// no quota; nothing leaves the device. Needs the owner's certificate and
/// MyScript's English recognition files, both added to the APK by CI.
class MyScriptOfflineRecognizer implements Recognizer {
  MyScriptOfflineRecognizer({
    this.channel = const MethodChannel('writing_recogniser/myscript_offline'),
  });

  final MethodChannel channel;

  /// Language in use once ready, e.g. "en_GB".
  String? language;

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
}

/// Each stroke as one flat list: x, y, t (ms), pressure, repeated. Compact
/// for the platform channel.
List<List<num>> encodeStrokesFlat(List<InkStroke> strokes) => [
  for (final s in strokes)
    [
      for (final p in s.points) ...[p.x, p.y, p.t, p.pressure],
    ],
];
