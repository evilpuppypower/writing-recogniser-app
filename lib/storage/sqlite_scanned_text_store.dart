import 'package:sqflite/sqflite.dart';

import '../core/scanned_text.dart';
import 'app_database.dart';

/// Text read from scanned PDFs, in the app database.
class SqliteScannedTextStore implements ScannedTextStore {
  SqliteScannedTextStore(this._db);

  /// Uses the app's shared database.
  static Future<SqliteScannedTextStore> open() async =>
      SqliteScannedTextStore(await AppDatabase.open());

  final Database _db;

  @override
  Future<Map<int, List<ScannedLine>>> load(String documentId) async => {
    for (final r in await _db.query(
      'scanned_text',
      where: 'document_id = ?',
      whereArgs: [documentId],
    ))
      r['page']! as int: decodeScannedLines(r['lines']! as String),
  };

  @override
  Future<void> savePage(String documentId, int page, List<ScannedLine> lines) =>
      _db.insert('scanned_text', {
        'document_id': documentId,
        'page': page,
        'lines': encodeScannedLines(lines),
      }, conflictAlgorithm: ConflictAlgorithm.replace);

  @override
  Future<Set<String>> documents() async => {
    for (final r in await _db.query(
      'scanned_text',
      columns: ['document_id'],
      distinct: true,
    ))
      r['document_id']! as String,
  };

  @override
  Future<void> forget(String documentId) => _db.delete(
    'scanned_text',
    where: 'document_id = ?',
    whereArgs: [documentId],
  );
}
