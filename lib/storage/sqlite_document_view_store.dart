import 'package:sqflite/sqflite.dart';

import '../core/document_view.dart';
import 'app_database.dart';

/// How each document was last shown, in the app database.
class SqliteDocumentViewStore implements DocumentViewStore {
  SqliteDocumentViewStore(this._db);

  /// Uses the app's shared database.
  static Future<SqliteDocumentViewStore> open() async =>
      SqliteDocumentViewStore(await AppDatabase.open());

  final Database _db;

  @override
  Future<DocumentView> load(String documentId) async {
    final rows = await _db.query(
      'document_views',
      where: 'document_id = ?',
      whereArgs: [documentId],
    );
    return DocumentView.fromJson(
      rows.isEmpty ? null : rows.first['view'] as String?,
    );
  }

  @override
  Future<void> save(String documentId, DocumentView view) => _db.insert(
    'document_views',
    {'document_id': documentId, 'view': view.toJson()},
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
}
