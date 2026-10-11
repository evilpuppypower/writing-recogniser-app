import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../core/ink.dart';
import '../core/labeled_sample.dart';
import '../core/sample_store.dart';

/// [SampleStore] backed by the app's SQLite database.
class SqliteSampleStore implements SampleStore {
  SqliteSampleStore(this._db);

  final Database _db;

  @override
  Future<int> add(LabeledSample s) => _db.insert('samples', {
    'text': s.text,
    'strokes': jsonEncode(strokesToJson(s.strokes)),
    'created_at': s.createdAt.millisecondsSinceEpoch,
    'canvas_width': s.canvasWidth,
    'canvas_height': s.canvasHeight,
    'hover': s.hover.isEmpty ? null : jsonEncode(hoverToJson(s.hover)),
  });

  @override
  Future<List<LabeledSample>> all() async {
    final rows = await _db.query('samples', orderBy: 'id');
    return [
      for (final r in rows)
        LabeledSample(
          id: r['id']! as int,
          text: r['text']! as String,
          strokes: strokesFromJson(jsonDecode(r['strokes']! as String) as List),
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            r['created_at']! as int,
          ),
          canvasWidth: (r['canvas_width'] as num?)?.toDouble(),
          canvasHeight: (r['canvas_height'] as num?)?.toDouble(),
          hover: r['hover'] == null
              ? const []
              : hoverFromJson(jsonDecode(r['hover']! as String) as List),
        ),
    ];
  }

  @override
  Future<int> count() async =>
      Sqflite.firstIntValue(
        await _db.rawQuery('SELECT COUNT(*) FROM samples'),
      ) ??
      0;

  @override
  Future<void> delete(int id) =>
      _db.delete('samples', where: 'id = ?', whereArgs: [id]);
}
