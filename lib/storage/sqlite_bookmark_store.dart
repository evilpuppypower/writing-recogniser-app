import 'package:sqflite/sqflite.dart';

import '../core/bookmarks.dart';
import 'app_database.dart';

/// [BookmarkStore] in the app's SQLite database.
class SqliteBookmarkStore implements BookmarkStore {
  SqliteBookmarkStore(this._db);

  static Future<BookmarkStore> open() async =>
      SqliteBookmarkStore(await AppDatabase.open());

  final Database _db;

  @override
  Future<List<int>> pages(String documentId) async => [
    for (final r in await _db.query(
      'bookmarks',
      where: 'document_id = ?',
      whereArgs: [documentId],
      orderBy: 'page',
    ))
      r['page']! as int,
  ];

  @override
  Future<void> set(String documentId, int page, {required bool on}) async {
    if (on) {
      await _db.insert('bookmarks', {
        'document_id': documentId,
        'page': page,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } else {
      await _db.delete(
        'bookmarks',
        where: 'document_id = ? AND page = ?',
        whereArgs: [documentId, page],
      );
    }
  }
}
