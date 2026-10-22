import 'dart:async';

import 'package:flutter/services.dart';

import '../viewer/wet_ink.dart';

/// [WetInk] on Android (WetInk.kt). Every call is sent without waiting;
/// if the platform side is missing or fails, the app's own drawing goes on.
class ChannelWetInk implements WetInk {
  ChannelWetInk({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('writing_recogniser/wet_ink');

  final MethodChannel _channel;

  void _send(String method, [Map<String, Object?>? args]) {
    unawaited(_channel.invokeMethod<void>(method, args).catchError((_) {}));
  }

  /// Puts the layer over the app (while a PDF is open); false if this
  /// tablet can't draw it.
  Future<bool> enable() async {
    try {
      return await _channel.invokeMethod<bool>('enable') ?? false;
    } catch (_) {
      return false;
    }
  }

  void disable() => _send('disable');

  /// What happened since the last call, for the diagnostics: whether it's
  /// on, strokes drawn and cancelled, how long a point took to draw.
  Future<Map<String, Object?>> stats() async {
    try {
      final m = await _channel.invokeMethod<Map<Object?, Object?>>('stats');
      return {for (final e in (m ?? const {}).entries) '${e.key}': e.value};
    } catch (_) {
      return const {};
    }
  }

  @override
  void start({
    required int downMicros,
    required int colorArgb,
    required double unitPx,
    required double spread,
    required double thinnest,
    required Rect clip,
    required double devicePixelRatio,
  }) => _send('start', {
    'downMicros': downMicros,
    'style': {
      'color': colorArgb,
      'unitPx': unitPx,
      'spread': spread,
      'thinnest': thinnest,
      'clip': [clip.left, clip.top, clip.right, clip.bottom],
      'dpr': devicePixelRatio,
    },
  });

  @override
  void cancel(int downMicros) => _send('cancel', {'downMicros': downMicros});

  @override
  void release(int downMicros) => _send('release', {'downMicros': downMicros});
}
