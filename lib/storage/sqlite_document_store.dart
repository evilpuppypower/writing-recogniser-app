import 'package:sqflite/sqflite.dart';

import '../core/document_state.dart';
import 'app_database.dart';

class SqliteDocumentStore implements DocumentStateStore {
  SqliteDocumentStore(this._db);

  /// Uses the app's shared database.
  static Future<SqliteDocumentStore> open() async =>
      SqliteDocumentStore(await AppDatabase.open());

  final Database _db;

  static DocumentState _fromRow(Map<String, Object?> r) => DocumentState(
    id: r['id']! as String,
    lastPage: r['last_page']! as int,
    pageCount: r['page_count']! as int,
    updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at']! as int),
  );

  @override
  Future<DocumentState?> get(String id) async {
    final rows = await _db.query('documents', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  @override
  Future<Map<String, DocumentState>> all() async => {
    for (final r in await _db.query('documents'))
      r['id']! as String: _fromRow(r),
  };

  @override
  Future<void> save(DocumentState s) => _db.insert('documents', {
    'id': s.id,
    'last_page': s.lastPage,
    'page_count': s.pageCount,
    'updated_at': s.updatedAt.millisecondsSinceEpoch,
  }, conflictAlgorithm: ConflictAlgorithm.replace);
}
