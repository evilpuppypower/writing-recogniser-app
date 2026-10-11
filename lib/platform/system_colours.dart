import 'package:flutter/services.dart';

/// Reads the tablet's Material You accent colour (Android 12+), set by the
/// user's wallpaper or theme. Returns null if unavailable (e.g. in tests).
Future<int?> systemAccentColour() async {
  try {
    final argb = await const MethodChannel('writing_recogniser/system')
        .invokeMethod<int>('accentColor');
    return argb;
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}
