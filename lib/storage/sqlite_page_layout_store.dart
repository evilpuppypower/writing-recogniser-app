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
    await _db.insert('page_layouts', {
      'document_id': documentId,
      'layout': layout.toJson(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<List<String>> notebooks() async => [
    for (final r in await _db.query(
      'page_layouts',
      columns: ['document_id', 'layout'],
      where: 'layout LIKE ?',
      whereArgs: ['%"nb":true%'],
    ))
      if (PageLayout.fromJson(r['layout'] as String?)?.notebook ?? false)
        r['document_id']! as String,
  ];
}
