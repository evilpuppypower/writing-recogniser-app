import 'package:flutter/material.dart';

import '../core/app_settings.dart';
import '../settings/settings_controller.dart';

export '../core/night_colours.dart' show nightArgb;

/// Whether pages are shown dark (see [PageColours]): only the screen
/// changes, never the PDF or an export.
bool darkPagesOf(BuildContext context) {
  final c =
      context.dependOnInheritedWidgetOfExactType<DarkPagesScope>()?.colours ??
      SettingsScope.valueOf(context).pageColours;
  return c == PageColours.dark ||
      (c == PageColours.system &&
          MediaQuery.platformBrightnessOf(context) == Brightness.dark);
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

/// The open PDF's own page colours (null: Settings' choice), for
/// [darkPagesOf] below it.
class DarkPagesScope extends InheritedWidget {
  const DarkPagesScope({
    super.key,
    required this.colours,
    required super.child,
  });

  final PageColours? colours;

  @override
  bool updateShouldNotify(DarkPagesScope old) => old.colours != colours;
}
