import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../core/ink_store.dart';
import '../core/page_ink.dart';
import 'app_database.dart';

/// [InkStore] in the app's SQLite database: one row per PDF page with ink.
class SqliteInkStore implements InkStore {
  SqliteInkStore(this._db, {this.pieceChars = 500000});

  /// Uses the app's shared database.
  static Future<SqliteInkStore> open() async =>
      SqliteInkStore(await AppDatabase.open());

  final Database _db;

  /// A page's ink is read back this many characters at a time. Android
  /// can't read a row bigger than about 2 MB in one go, and a busy page
  /// is bigger since every pen sample is kept (owner, 2026-10-18: a page
  /// with 633 strokes came back empty; its ink was still saved). The ink
  /// is plain JSON text, so a character is a byte.
  final int pieceChars;

  /// Page [page]'s saved ink as text, read in pieces (see [pieceChars]).
  Future<String> _strokesText(String documentId, int page, int length) async {
    if (length <= pieceChars) {
      final r = await _db.query(
        'page_ink',
        columns: ['strokes'],
        where: 'document_id = ? AND page = ?',
        whereArgs: [documentId, page],
      );
      return r.isEmpty ? '[]' : r.single['strokes']! as String;
    }
    final out = StringBuffer();
    for (var start = 1; start <= length; start += pieceChars) {
      final r = await _db.rawQuery(
        'SELECT substr(strokes, ?, ?) AS piece FROM page_ink '
        'WHERE document_id = ? AND page = ?',
        [start, pieceChars, documentId, page],
      );
      if (r.isEmpty) break;
      out.write(r.single['piece']! as String);
    }
    return out.toString();
  }

  /// Each saved page of [documentId] (all PDFs if null), with its length,
  /// without reading the ink itself.
  Future<List<({String document, int page, int length})>> _pages([
    String? documentId,
  ]) async => [
    for (final r in await _db.rawQuery(
      'SELECT document_id, page, length(strokes) AS n FROM page_ink '
      '${documentId == null ? '' : 'WHERE document_id = ? '}'
      'ORDER BY document_id, page',
      [?documentId],
    ))
      (
        document: r['document_id']! as String,
        page: r['page']! as int,
        length: r['n']! as int,
      ),
  ];

  @override
  Future<DocumentInk> load(String documentId) async {
    final ink = DocumentInk();
    for (final p in await _pages(documentId)) {
      final text = await _strokesText(documentId, p.page, p.length);
      final strokes = jsonDecode(text) as List;
      ink.setPage(p.page, [
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
  Future<void> deleteDocument(String documentId) async {
    await _db.delete(
      'page_ink',
      where: 'document_id = ?',
      whereArgs: [documentId],
    );
    await _db.delete(
      'page_text',
      where: 'document_id = ?',
      whereArgs: [documentId],
    );
    // And the text read from its scanned pages.
    await _db.delete(
      'scanned_text',
      where: 'document_id = ?',
      whereArgs: [documentId],
    );
    // Its bookmarks go with it.
    await _db.delete(
      'bookmarks',
      where: 'document_id = ?',
      whereArgs: [documentId],
    );
    // And its own page colours.
    await _db.delete(
      'document_colours',
      where: 'document_id = ?',
      whereArgs: [documentId],
    );
    // And its pages of the user's own.
    await _db.delete(
      'page_layouts',
      where: 'document_id = ?',
      whereArgs: [documentId],
    );
    // And how it was last shown.
    await _db.delete(
      'document_views',
      where: 'document_id = ?',
      whereArgs: [documentId],
    );
    // And its tags (the tags themselves stay for other documents).
    await _db.delete(
      'document_tags',
      where: 'document_id = ?',
      whereArgs: [documentId],
    );
  }

  /// Whether [page] of [documentId] has any ink (one row, not the whole
  /// document's).
  Future<bool> hasInkOn(String documentId, int page) async => (await _db.query(
    'page_ink',
    columns: ['page'],
    where: 'document_id = ? AND page = ?',
    whereArgs: [documentId, page],
    limit: 1,
  )).isNotEmpty;

  @override
  Future<Map<int, String>> loadText(String documentId) async => {
    for (final r in await _db.query(
      'page_text',
      where: 'document_id = ?',
      whereArgs: [documentId],
    ))
      r['page']! as int: r['words']! as String,
  };

  /// Every page's saved recognition, of every PDF (for the training file,
  /// task 4.1b).
  Future<List<({String document, String json})>> allText() async => [
    for (final r in await _db.query('page_text', orderBy: 'document_id, page'))
      (document: r['document_id']! as String, json: r['words']! as String),
  ];

  /// Every page's ink, of every PDF, as saved (for the training file's
  /// word pairs, task 4.5).
  Future<List<({String document, String json})>> allInk() async => [
    for (final p in await _pages())
      (
        document: p.document,
        json: await _strokesText(p.document, p.page, p.length),
      ),
  ];

  @override
  Future<void> saveText(String documentId, int page, String? json) async {
    if (json == null) {
      await _db.delete(
        'page_text',
        where: 'document_id = ? AND page = ?',
        whereArgs: [documentId, page],
      );
      return;
    }
    await _db.insert('page_text', {
      'document_id': documentId,
      'page': page,
      'words': json,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<Set<String>> documentsWithInk() async => {
    for (final r in await _db.rawQuery(
      'SELECT DISTINCT document_id FROM page_ink',
    ))
      r['document_id']! as String,
  };
}
