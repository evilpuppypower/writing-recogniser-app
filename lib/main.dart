import 'package:flutter/material.dart';

import 'core/app_settings.dart';
import 'library/home_screen.dart';
import 'platform/system_colours.dart';
import 'settings/settings_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final (settings, accent) = await (
    SettingsController.load(),
    systemAccentColour(),
  ).wait;
  runApp(WritingRecogniserApp(settings: settings, accentArgb: accent));
}

/// Fallback colour when the tablet's Material You colour isn't available.
const _fallbackSeed = Colors.indigo;

/// Builds the app theme from the user's settings: the chosen app colour (or
/// the tablet's Material You colour) and the pop-up message style.
ThemeData buildTheme(
  AppSettings settings,
  Brightness brightness, {
  int? systemAccentArgb,
}) {
  final argb = settings.appColour.argb ?? systemAccentArgb;
  final scheme = ColorScheme.fromSeed(
    seedColor: argb == null ? _fallbackSeed : Color(argb),
    brightness: brightness,
    // "Match system" builds soft colours like Android does. A colour the
    // user picked is kept faithful (the default style would add colour to a
    // near-grey seed, turning Grey greenish); Grey is pure greyscale.
    dynamicSchemeVariant: switch (settings.appColour) {
      AppColour.system => DynamicSchemeVariant.tonalSpot,
      AppColour.grey => DynamicSchemeVariant.monochrome,
      _ => DynamicSchemeVariant.fidelity,
    },
  );
  final matching = settings.messageStyle == MessageStyle.matching;
  return ThemeData(
    colorScheme: scheme,
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      // Leaves room on the right for the viewer's scroll tab.
      insetPadding: const EdgeInsets.fromLTRB(16, 8, 96, 16),
      backgroundColor: matching ? scheme.surfaceContainerHighest : null,
      contentTextStyle: matching ? TextStyle(color: scheme.onSurface) : null,
      actionTextColor: matching ? scheme.primary : null,
    ),
    tooltipTheme: matching
        ? TooltipThemeData(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: scheme.outlineVariant),
            ),
            textStyle: TextStyle(color: scheme.onSurface),
          )
        : null,
  );
}

class WritingRecogniserApp extends StatelessWidget {
  const WritingRecogniserApp({
    super.key,
    required this.settings,
    this.accentArgb,
  });

  final SettingsController settings;

  /// The tablet's Material You accent colour, if known.
  final int? accentArgb;

  @override
  Widget build(BuildContext context) {
    return SettingsScope(
      controller: settings,
      // Rebuild the theme whenever a setting changes.
      child: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => MaterialApp(
          title: 'Writing Recogniser',
          theme: buildTheme(
            settings.value,
            Brightness.light,
            systemAccentArgb: accentArgb,
          ),
          darkTheme: buildTheme(
            settings.value,
            Brightness.dark,
            systemAccentArgb: accentArgb,
          ),
          // Follows the tablet's light/dark setting.
          themeMode: ThemeMode.system,
          showPerformanceOverlay: settings.showSmoothnessGraphs,
          home: const HomeScreen(),
        ),
      ),
    );
  }
}
