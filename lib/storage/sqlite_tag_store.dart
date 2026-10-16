import 'package:sqflite/sqflite.dart';

import '../core/tags.dart';
import 'app_database.dart';

/// Tags and which documents have them, in the app database.
class SqliteTagStore implements TagStore {
  SqliteTagStore(this._db);

  /// Uses the app's shared database.
  static Future<SqliteTagStore> open() async =>
      SqliteTagStore(await AppDatabase.open());

  final Database _db;

  @override
  Future<List<Tag>> tags() async => [
    for (final r in await _db.query('tags', orderBy: 'name'))
      Tag(r['name']! as String, r['colour']! as int),
  ];

  @override
  Future<Map<String, Set<String>>> documentTags() async {
    final out = <String, Set<String>>{};
    for (final r in await _db.query('document_tags')) {
      (out[r['document_id']! as String] ??= {}).add(r['tag']! as String);
    }
    return out;
  }

  @override
  Future<void> saveTag(Tag tag) => _db.insert('tags', {
    'name': tag.name,
    'colour': tag.colourArgb,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  @override
  Future<void> deleteTag(String name) => _db.transaction((t) async {
    await t.delete('tags', where: 'name = ?', whereArgs: [name]);
    await t.delete('document_tags', where: 'tag = ?', whereArgs: [name]);
  });

  @override
  Future<void> setDocumentTags(String documentId, Set<String> names) =>
      _db.transaction((t) async {
        await t.delete(
          'document_tags',
          where: 'document_id = ?',
          whereArgs: [documentId],
        );
        for (final n in names) {
          await t.insert('document_tags', {
            'document_id': documentId,
            'tag': n,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      });
}
