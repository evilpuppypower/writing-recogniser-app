import 'package:sqflite/sqflite.dart';

import '../core/app_settings.dart' show PageColours;
import '../core/document_colours.dart';
import 'app_database.dart';

/// Each PDF's own page colours, in the app database.
class SqliteDocumentColoursStore implements DocumentColoursStore {
  SqliteDocumentColoursStore(this._db);

  /// Uses the app's shared database.
  static Future<SqliteDocumentColoursStore> open() async =>
      SqliteDocumentColoursStore(await AppDatabase.open());

  final Database _db;

  @override
  Future<PageColours?> get(String documentId) async {
    final rows = await _db.query(
      'document_colours',
      where: 'document_id = ?',
      whereArgs: [documentId],
    );
    if (rows.isEmpty) return null;
    final name = rows.first['colours'];
    for (final c in PageColours.values) {
      if (c.name == name) return c;
    }
    return null;
  }

  @override
  Future<void> set(String documentId, PageColours? colours) async {
    if (colours == null) {
      await _db.delete(
        'document_colours',
        where: 'document_id = ?',
        whereArgs: [documentId],
      );
      return;
    }
    await _db.insert('document_colours', {
      'document_id': documentId,
      'colours': colours.name,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
