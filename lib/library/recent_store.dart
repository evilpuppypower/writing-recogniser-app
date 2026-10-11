import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/recent_pdfs.dart';

/// Saves the Recent list on the tablet.
class RecentStore {
  const RecentStore();

  static const _key = 'library.recent';

  Future<List<RecentPdf>> load() async {
    final saved = await SharedPreferencesAsync().getStringList(_key) ?? [];
    final list = <RecentPdf>[];
    for (final s in saved) {
      try {
        list.add(RecentPdf.fromJson(jsonDecode(s) as Map<String, Object?>));
      } catch (_) {
        // Skip a damaged entry rather than losing the whole list.
      }
    }
    return list;
  }

  Future<void> save(List<RecentPdf> list) => SharedPreferencesAsync()
      .setStringList(_key, [for (final r in list) jsonEncode(r.toJson())]);
}
