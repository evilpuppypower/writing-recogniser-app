import 'dart:convert';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../core/ink_store.dart';
import '../core/page_ink.dart';
import '../core/stroke_codec.dart';
import 'app_database.dart';

/// [InkStore] in the app's SQLite database: one row per stroke, and one
/// per page with the order of its strokes. A save writes only the new
/// strokes (owner, 2026-10-18: a busy page was rewritten whole, several
/// MB, after every stroke). Pages saved before as one row each are read
/// and moved over when their PDF is opened.
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
  Future<String> _strokesText(
    DatabaseExecutor db,
    String documentId,
    int page,
    int length,
  ) async {
    if (length <= pieceChars) {
      final r = await db.query(
        'page_ink',
        columns: ['strokes'],
        where: 'document_id = ? AND page = ?',
        whereArgs: [documentId, page],
      );
      return r.isEmpty ? '[]' : r.single['strokes']! as String;
    }
    final out = StringBuffer();
    for (var start = 1; start <= length; start += pieceChars) {
      final r = await db.rawQuery(
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
  Future<List<({String document, int page, int length})>> _pages(
    DatabaseExecutor db, [
    String? documentId,
  ]) async => [
    for (final r in await db.rawQuery(
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

  /// Which saved row holds each stroke object, per document page (the
  /// viewer keeps the same objects between saves, so a save only writes
  /// the strokes that are new). Checked against the database before use.
  static final _rows = <String, Expando<int>>{};

  static Expando<int> _rowsOf(String documentId, int page) =>
      _rows['$page/$documentId'] ??= Expando<int>();

  /// Rows that couldn't be read (damaged), per document page: kept as they
  /// are, never deleted by a save, in case they can be read one day.
  static final _unreadable = <String, Set<int>>{};

  static Set<int> _unreadableOf(String documentId, int page) =>
      _unreadable['$page/$documentId'] ??= <int>{};

  /// The ink saved on [documentId]'s pages before strokes were saved one
  /// by one (each page moves to [_newPages] when the PDF is opened).
  Future<Map<int, List<PageStroke>>> _oldPages(
    DatabaseExecutor db,
    String documentId,
  ) async {
    final out = <int, List<PageStroke>>{};
    for (final p in await _pages(db, documentId)) {
      final text = await _strokesText(db, documentId, p.page, p.length);
      out[p.page] = [
        for (final s in jsonDecode(text) as List)
          PageStroke.fromJson((s as Map).cast<String, Object?>()),
      ];
    }
    return out;
  }

  /// The ink saved stroke by stroke: each page's strokes in order.
  Future<Map<int, List<PageStroke>>> _newPages(
    DatabaseExecutor db,
    String documentId,
  ) async {
    final order = await db.query(
      'ink_pages',
      columns: ['page', 'stroke_ids'],
      where: 'document_id = ?',
      whereArgs: [documentId],
    );
    if (order.isEmpty) return {};
    final out = <int, List<PageStroke>>{};
    for (final o in order) {
      final page = o['page']! as int;
      final rows = await db.query(
        'ink_strokes',
        columns: ['id', 'data'],
        where: 'document_id = ? AND page = ?',
        whereArgs: [documentId, page],
      );
      final byId = {
        for (final r in rows) r['id']! as int: r['data']! as Uint8List,
      };
      // A damaged order row: the strokes in the order they were saved.
      final ids =
          _idsOf(o['stroke_ids']! as Uint8List) ?? (byId.keys.toList()..sort());
      final known = _rowsOf(documentId, page);
      final unreadable = _unreadableOf(documentId, page)..clear();
      final strokes = <PageStroke>[];
      for (final id in ids) {
        final data = byId[id];
        if (data == null) continue;
        final PageStroke s;
        try {
          s = decodeStroke(data);
        } on FormatException {
          // A damaged stroke: the rest of the page still opens.
          unreadable.add(id);
          continue;
        }
        known[s] = id;
        strokes.add(s);
      }
      if (strokes.isNotEmpty) out[page] = strokes;
    }
    return out;
  }

  static Uint8List _bytesOf(List<int> ids) =>
      Int64List.fromList(ids).buffer.asUint8List();

  static List<int>? _idsOf(Uint8List bytes) => bytes.length % 8 == 0
      ? Int64List.sublistView(Uint8List.fromList(bytes))
      : null;

  @override
  Future<DocumentInk> load(String documentId) async {
    // Read as one snapshot, so a save meanwhile can't give half of each.
    final read = await _db.transaction(
      (txn) async => (
        pages: await _newPages(txn, documentId),
        old: await _oldPages(txn, documentId),
      ),
    );
    final pages = read.pages;
    for (final e in read.old.entries) {
      // Moved to the new form now, in one go: if it's interrupted the old
      // row is still there. A page in both forms was written by an older
      // build after it moved (that build couldn't see the moved ink): the
      // two are put together, so nothing is lost.
      pages[e.key] = await _moveOld(
        documentId,
        e.key,
        _together(pages[e.key] ?? const [], e.value),
      );
    }
    final ink = DocumentInk();
    for (final e in pages.entries) {
      if (e.value.isNotEmpty) ink.setPage(e.key, e.value);
    }
    return ink;
  }

  /// [saved], then the strokes of [older] that aren't in it already.
  static List<PageStroke> _together(
    List<PageStroke> saved,
    List<PageStroke> older,
  ) {
    if (saved.isEmpty) return older;
    final have = {for (final s in saved) jsonEncode(s.toJson())};
    return [
      ...saved,
      for (final s in older)
        if (!have.contains(jsonEncode(s.toJson()))) s,
    ];
  }

  /// Saves [page] as [strokes] (its ink put together from the old form)
  /// and removes the old form, unless something saved the page since it
  /// was read (then that is what the page holds).
  Future<List<PageStroke>> _moveOld(
    String documentId,
    int page,
    List<PageStroke> strokes,
  ) async {
    final moved = await _db.transaction((txn) async {
      final old = await txn.query(
        'page_ink',
        columns: ['page'],
        where: 'document_id = ? AND page = ?',
        whereArgs: [documentId, page],
      );
      if (old.isEmpty) return null;
      return _write(txn, documentId, page, strokes);
    });
    if (moved != null) {
      _remember(documentId, page, moved);
      return strokes;
    }
    return (await _newPages(_db, documentId))[page] ?? const [];
  }

  @override
  Future<void> savePage(
    String documentId,
    int page,
    List<PageStroke> strokes,
  ) async => _remember(
    documentId,
    page,
    await _db.transaction((txn) => _write(txn, documentId, page, strokes)),
  );

  /// Saves [page] as [strokes]: only strokes not saved before are written.
  /// Returns the new rows, to be remembered once the save has gone through
  /// (a failed save keeps nothing).
  Future<List<(PageStroke, int)>> _write(
    Transaction txn,
    String documentId,
    int page,
    List<PageStroke> strokes,
  ) async {
    strokes = List.of(strokes); // the caller's list may change meanwhile
    final known = _rowsOf(documentId, page);
    final unreadable = _unreadableOf(documentId, page);
    final added = <(PageStroke, int)>[];
    {
      // The rows saved for the page now (another part of the app may have
      // changed them since).
      final stored = {
        for (final r in await txn.query(
          'ink_strokes',
          columns: ['id'],
          where: 'document_id = ? AND page = ?',
          whereArgs: [documentId, page],
        ))
          r['id']! as int,
      };
      // Which strokes are already saved; the rest are written in one go
      // (one trip to the database, not one per stroke).
      final ids = List<int?>.filled(strokes.length, null);
      final used = <int>{};
      final fresh = <int>[];
      for (var i = 0; i < strokes.length; i++) {
        final id = known[strokes[i]];
        if (id == null || !stored.contains(id) || used.contains(id)) {
          fresh.add(i);
        } else {
          ids[i] = id;
          used.add(id);
        }
      }
      if (fresh.isNotEmpty) {
        final batch = txn.batch();
        for (final i in fresh) {
          batch.insert('ink_strokes', {
            'document_id': documentId,
            'page': page,
            'data': encodeStroke(strokes[i]),
          });
        }
        final made = await batch.commit();
        for (var k = 0; k < fresh.length; k++) {
          final id = made[k]! as int;
          ids[fresh[k]] = id;
          used.add(id);
          added.add((strokes[fresh[k]], id));
        }
      }
      // Damaged rows stay, at the end of the page.
      final kept = [
        for (final id in unreadable)
          if (stored.contains(id) && !used.contains(id)) id,
      ];
      used.addAll(kept);
      final gone = [
        for (final id in stored)
          if (!used.contains(id)) id,
      ];
      for (var i = 0; i < gone.length; i += 500) {
        final part = gone.sublist(
          i,
          i + 500 > gone.length ? gone.length : i + 500,
        );
        await txn.delete(
          'ink_strokes',
          where: 'id IN (${List.filled(part.length, '?').join(',')})',
          whereArgs: part,
        );
      }
      if (ids.isEmpty && kept.isEmpty) {
        await txn.delete(
          'ink_pages',
          where: 'document_id = ? AND page = ?',
          whereArgs: [documentId, page],
        );
      } else {
        await txn.insert('ink_pages', {
          'document_id': documentId,
          'page': page,
          'stroke_ids': _bytesOf([for (final id in ids) id!, ...kept]),
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      // The page as it was saved before (see _oldPages) is replaced.
      await txn.delete(
        'page_ink',
        where: 'document_id = ? AND page = ?',
        whereArgs: [documentId, page],
      );
    }
    return added;
  }

  void _remember(String documentId, int page, List<(PageStroke, int)> rows) {
    final known = _rowsOf(documentId, page);
    for (final (s, id) in rows) {
      known[s] = id;
    }
  }

  @override
  Future<void> deleteDocument(String documentId) async {
    for (final table in ['page_ink', 'ink_strokes', 'ink_pages']) {
      await _db.delete(
        table,
        where: 'document_id = ?',
        whereArgs: [documentId],
      );
    }
    _rows.removeWhere((k, _) => k.endsWith('/$documentId'));
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
  Future<bool> hasInkOn(String documentId, int page) async {
    for (final table in ['ink_pages', 'page_ink']) {
      final found = await _db.query(
        table,
        columns: ['page'],
        where: 'document_id = ? AND page = ?',
        whereArgs: [documentId, page],
        limit: 1,
      );
      if (found.isNotEmpty) return true;
    }
    return false;
  }

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
  Future<List<({String document, String json})>> allInk() async {
    final out = <({String document, String json})>[];
    for (final id in (await documentsWithInk()).toList()..sort()) {
      final ink = await load(id);
      for (final page in ink.pagesWithInk.toList()..sort()) {
        out.add((
          document: id,
          json: jsonEncode([for (final s in ink.strokesOn(page)) s.toJson()]),
        ));
      }
    }
    return out;
  }

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
      'SELECT document_id FROM page_ink UNION SELECT document_id FROM ink_pages',
    ))
      r['document_id']! as String,
  };
}
