import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/app_settings.dart';
import 'package:writing_recogniser/viewer/dark_pages.dart';

void main() {
  test('ink on a dark page: black shows white, colours keep their hue', () {
    expect(nightArgb(0xFF000000), 0xFFFFFFFF);
    expect(nightArgb(0xFFFFFFFF), 0xFF000000);
    final blue = HSLColor.fromColor(const Color(0xFF0D47A1));
    final shown = HSLColor.fromColor(Color(nightArgb(0xFF0D47A1)));
    expect(shown.hue, closeTo(blue.hue, 1));
    expect(shown.lightness, closeTo(1 - blue.lightness, 0.01));
    // See-through stays see-through.
    expect(nightArgb(0x33000000) >> 24, 0x33);
  });

  test('page colours: as printed by default, saved with the settings', () {
    expect(const AppSettings().pageColours, PageColours.light);
    final s = const AppSettings().copyWith(pageColours: PageColours.system);
    expect(AppSettings.fromMap(s.toMap()).pageColours, PageColours.system);
  });
}
