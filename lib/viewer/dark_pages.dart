import 'package:flutter/material.dart';

import '../core/app_settings.dart';
import '../settings/settings_controller.dart';

/// Whether pages are shown dark (see [PageColours]): only the screen
/// changes, never the PDF or an export.
bool darkPagesOf(BuildContext context) {
  final c = SettingsScope.valueOf(context).pageColours;
  return c == PageColours.dark ||
      (c == PageColours.system &&
          MediaQuery.platformBrightnessOf(context) == Brightness.dark);
}

/// An ink colour as shown on a dark page: the same hue with its lightness
/// turned round, so black ink shows white and dark blue shows light blue.
int nightArgb(int argb) {
  final hsl = HSLColor.fromColor(Color(argb));
  return hsl.withLightness(1 - hsl.lightness).toColor().toARGB32();
}

/// Turns a page's printed content dark: the colours reversed, then the
/// black lifted to a soft dark grey. Drawn over the page, under the ink.
void paintDarkPage(Canvas canvas, Rect pageRect) {
  canvas
    ..drawRect(
      pageRect,
      Paint()
        ..color = const Color(0xFFFFFFFF)
        ..blendMode = BlendMode.difference,
    )
    ..drawRect(
      pageRect,
      Paint()
        ..color = const Color(0xFF202124)
        ..blendMode = BlendMode.lighten,
    );
}
