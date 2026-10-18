import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// The app's SQLite database (samples, event log, PDF library state;
/// annotations and corrections later). Everything stays on the tablet (CLAUDE.md rule 7).
class AppDatabase {
  AppDatabase._();

  static const fileName = 'writing_recogniser.db';
  static const version = 15;

  /// Opens (and creates or upgrades) the database. [factory] and [path] can
  /// be overridden for tests.
  static Future<Database> open({DatabaseFactory? factory, String? path}) async {
    final f = factory ?? databaseFactory;
    final dbPath = path ?? p.join(await f.getDatabasesPath(), fileName);
    return f.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: version,
        onCreate: (db, version) => _migrate(db, 0, version),
        onUpgrade: _migrate,
      ),
    );
  }

  static Future<void> _migrate(Database db, int from, int to) async {
    if (from < 1) {
      await db.execute('''
        CREATE TABLE samples (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          text TEXT NOT NULL,
          strokes TEXT NOT NULL,      -- JSON: [[[x, y, t, pressure], ...], ...]
          created_at INTEGER NOT NULL, -- ms since epoch
          canvas_width REAL,
          canvas_height REAL
        )
      ''');
    }
    if (from < 2) {
      await db.execute('''
        CREATE TABLE events (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          type TEXT NOT NULL,          -- recognition, correction, accept, ...
          at INTEGER NOT NULL,         -- ms since epoch
          engine TEXT,
          latency_ms INTEGER,          -- pen lift to text shown
          data TEXT NOT NULL           -- JSON with extra details
        )
      ''');
      await db.execute('CREATE INDEX events_type ON events(type)');
    }
    if (from < 3) {
      await db.execute('''
        CREATE TABLE documents (
          id TEXT PRIMARY KEY,         -- library id (same as stored copy)
          last_page INTEGER NOT NULL,  -- 1-based page the user was on
          page_count INTEGER NOT NULL,
          updated_at INTEGER NOT NULL  -- ms since epoch
        )
      ''');
    }
    if (from < 4) {
      // Pen hover between strokes: JSON [[x, y, t], ...]; null for older
      // samples.
      await db.execute('ALTER TABLE samples ADD COLUMN hover TEXT');
    }
    if (from < 5) {
      // Ink written on PDFs (task 1.3): one row per page with ink, strokes
      // in PDF page coordinates. The PDF itself is never changed.
      await db.execute('''
        CREATE TABLE page_ink (
          document_id TEXT NOT NULL,   -- library id (as in documents)
          page INTEGER NOT NULL,       -- 1-based
          strokes TEXT NOT NULL,       -- JSON list of PageStroke
          updated_at INTEGER NOT NULL, -- ms since epoch
          PRIMARY KEY (document_id, page)
        )
      ''');
    }
    if (from < 6) {
      // Corrections (task 2.5, CLAUDE.md rule 4): one row each time the
      // user corrects a word, with the raw strokes, for the feedback layer
      // now and training later. Stays on the tablet.
      await db.execute('''
        CREATE TABLE corrections (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          recognized TEXT NOT NULL,     -- what the engine read
          corrected TEXT NOT NULL,      -- what the user meant
          previous_word TEXT NOT NULL,  -- context
          strokes TEXT NOT NULL,        -- JSON: [[[x, y, t, pressure], ...], ...]
          scope TEXT NOT NULL,          -- global | document
          document_id TEXT,
          created_at INTEGER NOT NULL   -- ms since epoch
        )
      ''');
      await db.execute(
        'CREATE INDEX corrections_recognized ON corrections (recognized)',
      );
    }
    if (from < 7) {
      // What the handwriting on each page was read as, kept with the ink so
      // reopening a PDF doesn't read it all again. Stays on the tablet.
      await db.execute('''
        CREATE TABLE page_text (
          document_id TEXT NOT NULL,   -- library id (as in page_ink)
          page INTEGER NOT NULL,       -- 1-based
          words TEXT NOT NULL,         -- JSON list of recognised words
          updated_at INTEGER NOT NULL, -- ms since epoch
          PRIMARY KEY (document_id, page)
        )
      ''');
    }
    if (from < 8) {
      // Pages the user bookmarked in each PDF (owner's choice, 2026-10-15).
      await db.execute('''
        CREATE TABLE bookmarks (
          document_id TEXT NOT NULL,   -- library id (as in page_ink)
          page INTEGER NOT NULL,       -- 1-based
          created_at INTEGER NOT NULL, -- ms since epoch
          PRIMARY KEY (document_id, page)
        )
      ''');
    }
    if (from < 9) {
      // Each PDF's own page colours, light or dark (owner, 2026-10-16).
      await db.execute('''
        CREATE TABLE document_colours (
          document_id TEXT PRIMARY KEY, -- library id (as in page_ink)
          colours TEXT NOT NULL         -- a PageColours name
        )
      ''');
    }
    if (from < 10) {
      // The order pages are shown in, with pages of the user's own to
      // write on (owner, 2026-10-16). No row: the PDF's own pages.
      await db.execute('''
        CREATE TABLE page_layouts (
          document_id TEXT PRIMARY KEY, -- library id (as in page_ink)
          layout TEXT NOT NULL          -- PageLayout.toJson
        )
      ''');
    }
    if (from < 11) {
      // How each document was last shown (owner, 2026-10-16).
      await db.execute('''
        CREATE TABLE document_views (
          document_id TEXT PRIMARY KEY, -- library id (as in page_ink)
          view TEXT NOT NULL            -- DocumentView.toJson
        )
      ''');
    }
    if (from < 12) {
      // Tags (owner, 2026-10-16): several per document, colour-coded.
      await db.execute('''
        CREATE TABLE tags (
          name TEXT PRIMARY KEY,
          colour INTEGER NOT NULL       -- ARGB
        )
      ''');
      await db.execute('''
        CREATE TABLE document_tags (
          document_id TEXT NOT NULL,    -- library id (as in page_ink)
          tag TEXT NOT NULL,
          PRIMARY KEY (document_id, tag)
        )
      ''');
    }
    if (from < 13) {
      // Each PDF's printed text, read once, for searching every document
      // (owner, 2026-10-16).
      await db.execute('''
        CREATE TABLE printed_text (
          document_id TEXT NOT NULL,    -- library id (as in page_ink)
          page INTEGER NOT NULL,        -- the PDF's own page number
          text TEXT NOT NULL,
          PRIMARY KEY (document_id, page)
        )
      ''');
      await db.execute('''
        CREATE TABLE printed_documents (
          document_id TEXT PRIMARY KEY, -- read (even if it has no text)
          pages INTEGER NOT NULL        -- the PDF's page count
        )
      ''');
    }
    if (from < 14) {
      // Text read from scanned PDFs on the tablet (owner, 2026-10-17).
      await db.execute('''
        CREATE TABLE scanned_text (
          document_id TEXT NOT NULL,    -- library id (as in page_ink)
          page INTEGER NOT NULL,        -- the PDF's own page number
          lines TEXT NOT NULL,          -- JSON: [[left, top, right, bottom, text, confidence], ...], shares of the page
          PRIMARY KEY (document_id, page)
        )
      ''');
    }
    if (from < 15) {
      // Ink saved stroke by stroke, compactly (owner, 2026-10-18: a busy
      // page was rewritten whole after every stroke, and the pen waited).
      // page_ink stays for pages saved before; each moves here when its
      // PDF is next opened.
      // "If not exists": every build has the same version number, so an
      // older build can be installed over this one; it sets the database
      // back to version 14 and leaves these tables, and this step runs
      // again when a newer build is back.
      await db.execute('''
        CREATE TABLE IF NOT EXISTS ink_strokes (
          id INTEGER PRIMARY KEY AUTOINCREMENT, -- never reused
          document_id TEXT NOT NULL,   -- library id (as in page_ink)
          page INTEGER NOT NULL,       -- page key (as in page_ink)
          data BLOB NOT NULL           -- one stroke, see encodeStroke
        )
      ''');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS ink_strokes_page '
        'ON ink_strokes (document_id, page)',
      );
      await db.execute('''
        CREATE TABLE IF NOT EXISTS ink_pages (
          document_id TEXT NOT NULL,
          page INTEGER NOT NULL,
          stroke_ids BLOB NOT NULL,    -- the page's ink_strokes ids in order (64-bit each)
          updated_at INTEGER NOT NULL, -- ms since epoch
          PRIMARY KEY (document_id, page)
        )
      ''');
    }
  }
}
