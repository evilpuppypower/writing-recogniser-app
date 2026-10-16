import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/pen_tools.dart';

/// The current pen tools, remembered on the tablet between sessions.
class PenToolsController extends ValueNotifier<PenToolsState> {
  PenToolsController([super.value = const PenToolsState()]);

  static const _key = 'pens.state';

  static const _usageKey = 'pens.usage';

  /// Loads the saved tools (defaults if none or unreadable).
  static Future<PenToolsController> load() async {
    PenToolsController c;
    try {
      final raw = await SharedPreferencesAsync().getString(_key);
      c = raw == null
          ? PenToolsController()
          : PenToolsController(PenToolsState.fromJson(jsonDecode(raw)));
    } catch (_) {
      c = PenToolsController(); // fall back to defaults
    }
    try {
      final raw = await SharedPreferencesAsync().getString(_usageKey);
      if (raw != null) c.usage.load(jsonDecode(raw));
    } catch (_) {
      // Counting starts again.
    }
    return c;
  }

  /// How often each pen is used (owner's approved idea 9: the pens used
  /// most come first).
  final usage = PenUsage();
  int _sinceSaved = 0;

  /// A stroke was written with [style]; counts are saved every 10 strokes.
  void noteUse(PenStyle style) {
    if (!usage.add(style)) return;
    if (++_sinceSaved >= 10) saveUsage();
  }

  /// Saves the counts now (e.g. when the PDF closes).
  void saveUsage() {
    if (_sinceSaved == 0) return;
    _sinceSaved = 0;
    try {
      SharedPreferencesAsync()
          .setString(_usageKey, jsonEncode(usage.toJson()))
          .catchError((_) {});
    } catch (_) {
      // No storage available (e.g. in tests).
    }
  }

  /// Changes the tools and saves them (saving is best-effort).
  void update(PenToolsState next) {
    if (next == value) return;
    value = next;
    try {
      SharedPreferencesAsync()
          .setString(_key, jsonEncode(next.toJson()))
          .catchError((_) {});
    } catch (_) {
      // No storage available (e.g. in tests): keep working without saving.
    }
  }
}
