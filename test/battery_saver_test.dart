import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/app_settings.dart';
import 'package:writing_recogniser/core/battery_saver.dart';

void main() {
  test('on when switched on, or with Android\'s while that is on', () {
    expect(
      batterySaverOn(switchedOn: true, withSystem: false, systemSaving: false),
      isTrue,
    );
    expect(
      batterySaverOn(switchedOn: false, withSystem: true, systemSaving: true),
      isTrue,
    );
    expect(
      batterySaverOn(switchedOn: false, withSystem: false, systemSaving: true),
      isFalse,
    );
    expect(
      batterySaverOn(switchedOn: false, withSystem: true, systemSaving: false),
      isFalse,
    );
  });

  test('a longer pause before reading while saving', () {
    expect(readPauseMs(600, saving: false), 600);
    expect(readPauseMs(600, saving: true), savingPauseMs);
    expect(readPauseMs(3000, saving: true), 3000);
  });

  test('kept in the settings', () {
    const s = AppSettings(
      batterySaver: true,
      batterySaverWithSystem: false,
      readLater: true,
    );
    final back = AppSettings.fromMap(s.toMap());
    expect(back.batterySaver, isTrue);
    expect(back.batterySaverWithSystem, isFalse);
    expect(back.readLater, isTrue);
    expect(back, s);
    expect(const AppSettings().batterySaverWithSystem, isTrue);
  });
}
