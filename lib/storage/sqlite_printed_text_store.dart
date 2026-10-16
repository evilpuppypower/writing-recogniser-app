import 'package:sqflite/sqflite.dart';

import '../core/printed_text_store.dart';
import 'app_database.dart';

/// Each PDF's printed text, in the app database.
class SqlitePrintedTextStore implements PrintedTextStore {
  SqlitePrintedTextStore(this._db);

  /// Uses the app's shared database.
  static Future<SqlitePrintedTextStore> open() async =>
      SqlitePrintedTextStore(await AppDatabase.open());

  final Database _db;

  @override
  Future<Map<int, String>?> load(String documentId) async {
    final read = await _db.query(
      'printed_documents',
      where: 'document_id = ?',
      whereArgs: [documentId],
    );
    if (read.isEmpty) return null;
    return {
      for (final r in await _db.query(
        'printed_text',
        where: 'document_id = ?',
        whereArgs: [documentId],
      ))
        r['page']! as int: r['text']! as String,
    };
  }

  @override
  Future<void> save(String documentId, Map<int, String> pages) =>
      _db.transaction((t) async {
        await t.delete(
          'printed_text',
          where: 'document_id = ?',
          whereArgs: [documentId],
        );
        for (final e in pages.entries) {
          await t.insert('printed_text', {
            'document_id': documentId,
            'page': e.key,
            'text': e.value,
          });
        }
        await t.insert('printed_documents', {
          'document_id': documentId,
          'pages': pages.length,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      });

  @override
  Future<Set<String>> documents() async => {
    for (final r in await _db.query('printed_documents'))
      r['document_id']! as String,
  };

  @override
  Future<void> forget(String documentId) => _db.transaction((t) async {
    await t.delete(
      'printed_text',
      where: 'document_id = ?',
      whereArgs: [documentId],
    );
    await t.delete(
      'printed_documents',
      where: 'document_id = ?',
      whereArgs: [documentId],
    );
  });
}
