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

/// Why Google ML Kit couldn't start, or null if it started fine.
Future<String?> mlKitStartError() => _call<String>('mlKitStartError');
