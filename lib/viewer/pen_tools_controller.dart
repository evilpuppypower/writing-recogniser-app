import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/pen_tools.dart';

/// The current pen tools, remembered on the tablet between sessions.
class PenToolsController extends ValueNotifier<PenToolsState> {
  PenToolsController([super.value = const PenToolsState()]);

  static const _key = 'pens.state';

  /// Loads the saved tools (defaults if none or unreadable).
  static Future<PenToolsController> load() async {
    try {
      final raw = await SharedPreferencesAsync().getString(_key);
      if (raw != null) {
        return PenToolsController(PenToolsState.fromJson(jsonDecode(raw)));
      }
    } catch (_) {
      // Fall back to defaults.
    }
    return PenToolsController();
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
