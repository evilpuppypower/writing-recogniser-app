import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_settings.dart';

/// Holds the current [AppSettings], saves changes, and notifies listeners.
class SettingsController extends ChangeNotifier {
  SettingsController(this._settings, {this.onSave});

  /// Called with the new settings after every change, to persist them.
  final Future<void> Function(AppSettings settings)? onSave;

  AppSettings _settings;
  AppSettings get value => _settings;

  Future<void> update(AppSettings settings) async {
    if (settings == _settings) return;
    _settings = settings;
    notifyListeners();
    await onSave?.call(settings);
  }

  static const _prefix = 'settings.';

  /// Loads saved settings from the device (defaults if none saved yet).
  static Future<SettingsController> load() async {
    final prefs = SharedPreferencesAsync();
    final saved = await prefs.getAll(
      allowList: {
        ...const AppSettings().toMap().keys,
        ...AppSettings.legacyKeys,
      }.map((k) => '$_prefix$k').toSet(),
    );
    final settings = AppSettings.fromMap({
      for (final e in saved.entries) e.key.substring(_prefix.length): e.value,
    });
    return SettingsController(
      settings,
      onSave: (s) async {
        for (final e in s.toMap().entries) {
          final key = '$_prefix${e.key}';
          switch (e.value) {
            case final bool v:
              await prefs.setBool(key, v);
            case final int v:
              await prefs.setInt(key, v);
            case final Object v:
              await prefs.setString(key, '$v');
          }
        }
      },
    );
  }
}

/// Makes the [SettingsController] available to every screen; widgets that
/// call [SettingsScope.of] rebuild when settings change.
class SettingsScope extends InheritedNotifier<SettingsController> {
  const SettingsScope({
    super.key,
    required SettingsController controller,
    required super.child,
  }) : super(notifier: controller);

  static SettingsController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsScope>()!.notifier!;

  /// The settings, or the defaults when there is no [SettingsScope] above
  /// (e.g. a widget shown on its own in a test).
  static AppSettings valueOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<SettingsScope>()
          ?.notifier
          ?.value ??
      const AppSettings();
}
