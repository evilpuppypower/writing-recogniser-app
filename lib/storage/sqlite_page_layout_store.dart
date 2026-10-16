import 'package:sqflite/sqflite.dart';

import '../core/page_layout.dart';
import 'app_database.dart';

/// Each document's page order and pages of the user's own, in the app
/// database.
class SqlitePageLayoutStore implements PageLayoutStore {
  SqlitePageLayoutStore(this._db);

  /// Uses the app's shared database.
  static Future<SqlitePageLayoutStore> open() async =>
      SqlitePageLayoutStore(await AppDatabase.open());

  final Database _db;

  @override
  Future<String?> load(String documentId) async {
    final rows = await _db.query(
      'page_layouts',
      where: 'document_id = ?',
      whereArgs: [documentId],
    );
    return rows.isEmpty ? null : rows.first['layout'] as String?;
  }

  @override
  Future<void> save(String documentId, PageLayout layout) async {
    if (layout.isPlain) {
      await _db.delete(
        'page_layouts',
        where: 'document_id = ?',
        whereArgs: [documentId],
      );
      return;
    }
    await _db.insert('page_layouts', {
      'document_id': documentId,
      'layout': layout.toJson(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
