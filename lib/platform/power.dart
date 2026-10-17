import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Whether Android's own battery saver is on, kept up to date while the
/// app runs (MainActivity tells it when it changes). False where it can't
/// be told (tests, other platforms).
final systemBatterySaver = ValueNotifier<bool>(false);

const _channel = MethodChannel('writing_recogniser/power');

/// Starts following Android's battery saver.
Future<void> watchSystemBatterySaver() async {
  _channel.setMethodCallHandler((call) async {
    if (call.method == 'powerSaveChanged') {
      systemBatterySaver.value = call.arguments == true;
    }
  });
  try {
    systemBatterySaver.value =
        await _channel.invokeMethod<bool>('powerSave') ?? false;
  } on MissingPluginException {
    // Not on Android.
  } on PlatformException {
    // Unknown: treated as off.
  }
}

/// Tells automatic backups (run by Android when the app may be closed)
/// the app's battery saver settings, so they wait while it's on.
Future<void> tellBackupsBatterySaver({
  required bool on,
  required bool withSystem,
}) async {
  try {
    await const MethodChannel('writing_recogniser/backup').invokeMethod<void>(
      'setBatterySaver',
      {'on': on, 'withSystem': withSystem},
    );
  } on MissingPluginException {
    // Not on Android.
  } on PlatformException {
    // Backups then don't wait; they still need the battery not low.
  }
}
