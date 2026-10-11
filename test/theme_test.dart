import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/app_settings.dart';
import 'package:writing_recogniser/main.dart';

void main() {
  test('the chosen app colour drives the whole colour scheme', () {
    final orange = buildTheme(
      const AppSettings(appColour: AppColour.orange),
      Brightness.light,
    );
    final green = buildTheme(
      const AppSettings(appColour: AppColour.green),
      Brightness.light,
    );
    expect(orange.colorScheme.primary, isNot(green.colorScheme.primary));
  });

  test('Grey is truly grey, not tinted', () {
    for (final b in Brightness.values) {
      final scheme = buildTheme(
        const AppSettings(appColour: AppColour.grey),
        b,
      ).colorScheme;
      for (final c in [
        scheme.primary,
        scheme.primaryContainer,
        scheme.secondary,
        scheme.surface,
      ]) {
        expect(HSVColor.fromColor(c).saturation, lessThan(0.02), reason: '$c');
      }
    }
  });

  test('a picked colour stays close to itself (orange stays orange)', () {
    final primary = buildTheme(
      const AppSettings(appColour: AppColour.orange),
      Brightness.light,
    ).colorScheme.primary;
    final hue = HSVColor.fromColor(primary).hue;
    final orangeHue = HSVColor.fromColor(const Color(0xFFFB8C00)).hue;
    expect((hue - orangeHue).abs(), lessThan(15));
    expect(HSVColor.fromColor(primary).saturation, greaterThan(0.5));
  });

  test('"Match system" uses the tablet colour, and ignores it otherwise', () {
    const tabletPink = 0xFFD81B60;
    final system = buildTheme(
      const AppSettings(),
      Brightness.light,
      systemAccentArgb: tabletPink,
    );
    expect(
      system.colorScheme.primary,
      ColorScheme.fromSeed(seedColor: const Color(tabletPink)).primary,
    );
    final blue = buildTheme(
      const AppSettings(appColour: AppColour.blue),
      Brightness.light,
      systemAccentArgb: tabletPink,
    );
    expect(blue.colorScheme.primary, isNot(system.colorScheme.primary));
  });

  test('message style: contrasting keeps defaults, matching uses theme', () {
    final contrasting = buildTheme(const AppSettings(), Brightness.light);
    expect(contrasting.snackBarTheme.backgroundColor, isNull);
    expect(contrasting.tooltipTheme.decoration, isNull);

    final matching = buildTheme(
      const AppSettings(messageStyle: MessageStyle.matching),
      Brightness.light,
    );
    final scheme = matching.colorScheme;
    expect(
      matching.snackBarTheme.backgroundColor,
      scheme.surfaceContainerHighest,
    );
    expect(matching.snackBarTheme.contentTextStyle?.color, scheme.onSurface);
    expect(
      (matching.tooltipTheme.decoration! as BoxDecoration).color,
      scheme.surfaceContainerHighest,
    );
  });

  test('messages always leave room for the scroll tab', () {
    final t = buildTheme(const AppSettings(), Brightness.dark);
    expect(t.snackBarTheme.behavior, SnackBarBehavior.floating);
    expect(t.snackBarTheme.insetPadding!.right, greaterThanOrEqualTo(72));
  });
}
