import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../core/feedback/correction.dart';
import '../core/feedback/correction_store.dart';
import '../core/ink.dart';
import 'app_database.dart';

/// [CorrectionStore] in the app's SQLite database.
class SqliteCorrectionStore implements CorrectionStore {
  SqliteCorrectionStore(this._db);

  static Future<SqliteCorrectionStore> open() async =>
      SqliteCorrectionStore(await AppDatabase.open());

  final Database _db;

  @override
  Future<void> add(CorrectionRecord c) => _db.insert('corrections', {
    'recognized': c.recognized,
    'corrected': c.corrected,
    'previous_word': c.previousWord,
    'strokes': jsonEncode([for (final s in c.strokes) s.toJson()]),
    'scope': c.scope.name,
    'document_id': c.documentId,
    'created_at': c.at.millisecondsSinceEpoch,
  });

  @override
  Future<List<CorrectionRecord>> all() async {
    final rows = await _db.query('corrections', orderBy: 'id');
    final counts = <String, int>{};
    return [
      for (final r in rows)
        () {
          final recognized = r['recognized']! as String;
          final corrected = r['corrected']! as String;
          final key = '${recognized.toLowerCase()}\u0000$corrected';
          final count = counts[key] = (counts[key] ?? 0) + 1;
          return CorrectionRecord(
            recognized: recognized,
            corrected: corrected,
            previousWord: r['previous_word']! as String,
            strokes: [
              for (final s in jsonDecode(r['strokes']! as String) as List)
                InkStroke.fromJson(s as List),
            ],
            count: count,
            at: DateTime.fromMillisecondsSinceEpoch(r['created_at']! as int),
            scope:
                CorrectionScope.values.asNameMap()[r['scope']] ??
                CorrectionScope.global,
            documentId: r['document_id'] as String?,
          );
        }(),
    ];
  }
}
