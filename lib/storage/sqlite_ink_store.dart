import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../core/ink_store.dart';
import '../core/page_ink.dart';
import 'app_database.dart';

/// [InkStore] in the app's SQLite database: one row per PDF page with ink.
class SqliteInkStore implements InkStore {
  SqliteInkStore(this._db);

  /// Uses the app's shared database.
  static Future<SqliteInkStore> open() async =>
      SqliteInkStore(await AppDatabase.open());

  final Database _db;

  @override
  Future<DocumentInk> load(String documentId) async {
    final rows = await _db.query(
      'page_ink',
      where: 'document_id = ?',
      whereArgs: [documentId],
    );
    final ink = DocumentInk();
    for (final r in rows) {
      final strokes = jsonDecode(r['strokes']! as String) as List;
      ink.setPage(r['page']! as int, [
        for (final s in strokes)
          PageStroke.fromJson((s as Map).cast<String, Object?>()),
      ]);
    }
    return ink;
  }

  @override
  Future<void> savePage(
    String documentId,
    int page,
    List<PageStroke> strokes,
  ) async {
    if (strokes.isEmpty) {
      await _db.delete(
        'page_ink',
        where: 'document_id = ? AND page = ?',
        whereArgs: [documentId, page],
      );
      return;
    }
    await _db.insert('page_ink', {
      'document_id': documentId,
      'page': page,
      'strokes': jsonEncode([for (final s in strokes) s.toJson()]),
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> deleteDocument(String documentId) =>
      _db.delete('page_ink', where: 'document_id = ?', whereArgs: [documentId]);

  @override
  Future<Set<String>> documentsWithInk() async => {
    for (final r in await _db.rawQuery(
      'SELECT DISTINCT document_id FROM page_ink',
    ))
      r['document_id']! as String,
  };
}
