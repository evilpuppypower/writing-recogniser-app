import 'package:flutter/services.dart';

/// Crash and start-up diagnostics from the Android side (App.kt). All return
/// null when unavailable (e.g. in tests).
const _channel = MethodChannel('writing_recogniser/system');

Future<T?> _call<T>(String method) async {
  try {
    return await _channel.invokeMethod<T>(method);
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}

/// Details of the last crash, if the app crashed since this was cleared.
Future<String?> lastCrashReport() => _call<String>('lastCrash');

Future<void> clearLastCrashReport() => _call<void>('clearLastCrash');

/// The screen's refresh rate now, the rates it can run at, and whether
/// Android's battery saver is on (owner, 2026-10-18: measure before
/// deciding on the refresh rate). Empty when unavailable.
Future<Map<String, Object?>> displayState() async {
  try {
    final m = await _channel.invokeMapMethod<String, Object?>('display');
    if (m == null) return const {};
    return {
      if (m['hz'] is num) 'displayHz': (m['hz']! as num).round(),
      if (m['modes'] is List)
        'displayModesHz': [
          for (final r in m['modes']! as List)
            if (r is num) r.round(),
        ],
      if (m['powerSave'] is bool) 'androidSaver': m['powerSave'],
    };
  } on MissingPluginException {
    return const {};
  } on PlatformException {
    return const {};
  }
}

/// Why Google ML Kit couldn't start, or null if it started fine.
Future<String?> mlKitStartError() => _call<String>('mlKitStartError');
