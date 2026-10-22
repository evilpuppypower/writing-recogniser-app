import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/app_settings.dart';
import 'package:writing_recogniser/core/pressure_response.dart';

void main() {
  test('defaults', () {
    const s = AppSettings();
    expect(s.appColour, AppColour.system);
    expect(s.scrollTabIdle, ScrollTabIdle.slim);
    expect(s.messageStyle, MessageStyle.contrasting);
    expect(s.cachedPdfLimit, 3);
    expect(s.slimTabOpacityPercent, 55);
    expect(s.confirmDeleteCopy, isTrue);
    expect(s.recognitionPauseMs, 800);
    expect(s.writingHand, WritingHand.right);
    expect(s.writingBoxPercent, 67);
    expect(s.pressurePercent, 100);
    expect(s.keepInkOnDelete, isTrue);
    expect(s.textLabels, TextLabelPlace.above);
    expect(s.textPanel, TextPanelPlace.off);
  });

  test('writing box and pressure stay in range', () {
    final s = const AppSettings().copyWith(
      writingBoxPercent: 5,
      pressurePercent: 400,
    );
    expect(s.writingBoxPercent, AppSettings.minWritingBoxPercent);
    expect(s.pressurePercent, 100);
  });

  test('pressure settings become the pen response', () {
    const s = AppSettings();
    expect(s.pressureOn, isTrue);
    expect(s.pressureRangePercent, 40);
    expect(s.arrowHookMs, 70);
    expect(s.inkLeadMs, 18);
    expect(s.fastInk, isTrue);
    expect(s.pressureResponse, const PressureResponse(strength: 1, range: 0.4));
    expect(s.copyWith(pressureOn: false).pressureResponse.factor(1), 1);
    final custom = s.copyWith(pressureRangePercent: 200);
    expect(custom.pressureResponse.factor(1), closeTo(3, 1e-9));
  });

  test('pressure range and arrow trim stay in range', () {
    final s = const AppSettings().copyWith(
      pressurePercent: 0,
      pressureRangePercent: 999,
      arrowHookMs: -5,
      inkLeadMs: 99,
    );
    expect(s.pressurePercent, AppSettings.minPressurePercent);
    expect(s.pressureRangePercent, AppSettings.maxPressureRangePercent);
    expect(s.arrowHookMs, 0);
    expect(s.inkLeadMs, AppSettings.maxInkLeadMs);
  });

  test('pressure 0% saved by the previous version means off', () {
    final s = AppSettings.fromMap({'pressurePercent': 0});
    expect(s.pressureOn, isFalse);
    expect(s.pressurePercent, AppSettings.defaultPressurePercent);
    expect(AppSettings.fromMap({'pressurePercent': 50}).pressureOn, isTrue);
  });

  test('saves and loads every field', () {
    const s = AppSettings(
      appColour: AppColour.orange,
      scrollTabIdle: ScrollTabIdle.slim,
      slimTabOpacityPercent: 30,
      messageStyle: MessageStyle.matching,
      cachedPdfLimit: 7,
      confirmDeleteCopy: false,
      recognitionPauseMs: 1200,
      writingHand: WritingHand.left,
      writingBoxPercent: 55,
      pressureOn: false,
      pressurePercent: 30,
      pressureRangePercent: 120,
      arrowHookMs: 0,
      inkLeadMs: 20,
      fastInk: false,
      keepInkOnDelete: false,
      textLabels: TextLabelPlace.below,
      textPanel: TextPanelPlace.floating,
    );
    expect(AppSettings.fromMap(s.toMap()), s);
  });

  test('missing or damaged values fall back to defaults', () {
    expect(AppSettings.fromMap({}), const AppSettings());
    final s = AppSettings.fromMap({
      'appColour': 'purple-ish',
      'scrollTabIdle': 'sometimes',
      'messageStyle': 42,
      'cachedPdfLimit': 'many',
      'slimTabOpacityPercent': 'clear',
      'confirmDeleteCopy': 'nope',
    });
    expect(s, const AppSettings());
  });

  group('settings saved by the previous version carry over', () {
    test('scroll tab colour becomes the app colour', () {
      final s = AppSettings.fromMap({'scrollTabColour': 'green'});
      expect(s.appColour, AppColour.green);
    });

    test('auto-hide on becomes Hide, off becomes Always show', () {
      expect(
        AppSettings.fromMap({'scrollTabAutoHide': true}).scrollTabIdle,
        ScrollTabIdle.hidden,
      );
      expect(
        AppSettings.fromMap({'scrollTabAutoHide': false}).scrollTabIdle,
        ScrollTabIdle.visible,
      );
    });

    test('new values win over old ones', () {
      final s = AppSettings.fromMap({
        'scrollTabColour': 'green',
        'appColour': 'pink',
        'scrollTabAutoHide': false,
        'scrollTabIdle': 'slim',
      });
      expect(s.appColour, AppColour.pink);
      expect(s.scrollTabIdle, ScrollTabIdle.slim);
    });
  });

  test('cached PDF limit is kept between 1 and 10', () {
    expect(AppSettings.fromMap({'cachedPdfLimit': 0}).cachedPdfLimit, 1);
    expect(AppSettings.fromMap({'cachedPdfLimit': 99}).cachedPdfLimit, 10);
    expect(const AppSettings().copyWith(cachedPdfLimit: -5).cachedPdfLimit, 1);
    expect(const AppSettings().copyWith(cachedPdfLimit: 11).cachedPdfLimit, 10);
  });

  test('slim bar opacity is kept between 15% and 100%', () {
    expect(
      AppSettings.fromMap({'slimTabOpacityPercent': 0}).slimTabOpacityPercent,
      15,
    );
    expect(
      const AppSettings()
          .copyWith(slimTabOpacityPercent: 250)
          .slimTabOpacityPercent,
      100,
    );
  });

  test('recognition pause is kept between 0.3 s and 2 s', () {
    expect(
      AppSettings.fromMap({'recognitionPauseMs': 50}).recognitionPauseMs,
      300,
    );
    expect(
      const AppSettings().copyWith(recognitionPauseMs: 9000).recognitionPauseMs,
      2000,
    );
  });

  test('copyWith changes only what is given', () {
    final s = const AppSettings().copyWith(messageStyle: MessageStyle.matching);
    expect(s.messageStyle, MessageStyle.matching);
    expect(s.appColour, AppColour.system);
    expect(s.scrollTabIdle, ScrollTabIdle.slim);
    expect(s.cachedPdfLimit, 3);
  });

  test('every fixed colour is opaque; only system has no value', () {
    for (final c in AppColour.values) {
      if (c == AppColour.system) {
        expect(c.argb, isNull);
      } else {
        expect(c.argb! >> 24, 0xFF, reason: c.name);
      }
    }
  });

  test('the export "Also convert" choice is saved', () {
    expect(const AppSettings().exportConvertRest, ExportConvertRest.auto);
    final on = const AppSettings().copyWith(
      exportConvertRest: ExportConvertRest.on,
    );
    expect(
      AppSettings.fromMap(on.toMap()).exportConvertRest,
      ExportConvertRest.on,
    );
  });
}
