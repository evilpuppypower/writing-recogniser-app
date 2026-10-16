import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import '../core/app_settings.dart';
import '../core/bookmarks.dart';
import 'page_colours_dialog.dart';
import '../storage/sqlite_document_colours_store.dart';
import '../core/document_colours.dart';
import '../core/document_state.dart';
import '../core/feedback/correction_store.dart';
import '../core/handwriting_search.dart';
import '../core/ink_export_plan.dart' show ExportWord;
import '../core/ink_classifier.dart';
import '../core/event_log.dart';
import '../core/feedback/vocabulary.dart';
import '../core/ink_store.dart';
import '../core/open_timing.dart';
import '../core/page_coordinates.dart';
import '../core/page_ink.dart';
import '../core/page_recognition.dart' show HiddenInk, hiddenInkAt;
import '../core/selection.dart';
import '../core/stroke_grouping.dart' show InkBox, isWriting, levelPoint;
import '../core/typed_text.dart';
import '../core/pen_tools.dart';
import '../core/recognition/recognizer.dart';
import '../core/transfer_estimate.dart' show formatBytes, formatRemaining;
import '../export/pdf_exporter.dart';
import '../export/pdf_ink_writer.dart' show PdfExportException;
import '../platform/file_transfer.dart';
import '../platform/share_file.dart';
import '../recognition/engines.dart';
import '../recognition/myscript_ink_classifier.dart';
import '../settings/settings_controller.dart';
import '../storage/app_database.dart';
import '../storage/sqlite_bookmark_store.dart';
import '../storage/sqlite_correction_store.dart';
import '../storage/sqlite_document_store.dart';
import '../storage/sqlite_event_log.dart';
import '../storage/sqlite_ink_store.dart';
import 'ink_text_controller.dart';
import 'contents_sheet.dart';
import 'dark_pages.dart';
import 'frame_recorder.dart';
import 'label_fade.dart';
import 'page_ink_layer.dart';
import 'correct_word_sheet.dart';
import 'export_options_dialog.dart';
import 'page_text_labels.dart';
import 'page_typed_text.dart';
import 'pen_toolbar.dart';
import 'pen_tools_controller.dart';
import 'text_panel.dart';
import 'two_page_layout.dart';

/// The PDF viewer (task 1.1): scroll and zoom with fingers, page number and
/// "Go to page", a draggable scroll tab, and it reopens each PDF on the page
/// where it was left. The pen writes on the pages (task 1.2), and the ink
/// is saved as you write and comes back when the PDF reopens (task 1.3).
class PdfViewerScreen extends StatefulWidget {
  const PdfViewerScreen({
    super.key,
    required this.title,
    required this.documentId,
    required this.viewerBuilder,
    this.importTook,
    this.tappedAt,
    this.openEventLog = _openEventLog,
    this.makeRecognizer = _mainEngine,
    this.makeClassifier = _mainClassifier,
    this.openCorrections = SqliteCorrectionStore.open,
    this.openStore = SqliteDocumentStore.open,
    this.openInkStore = SqliteInkStore.open,
    this.openBookmarks = SqliteBookmarkStore.open,
    this.openDocumentColours = SqliteDocumentColoursStore.open,
    this.sourcePath,
    this.locateSource,
    this.exportPdf = exportPdfWithInk,
    this.saveFile = saveFileAs,
    this.shareFile = shareFileVia,
  });

  final String title;

  /// Library id of this PDF (its stored copy's id).
  final String documentId;

  /// How long the import copy took, if this file was just imported.
  final Duration? importTook;

  /// When the PDF was tapped, for timing how long it takes to show
  /// (defaults to when this screen was created).
  final DateTime? tappedAt;

  /// Where opening times are logged (the app database by default).
  final Future<EventLog> Function() openEventLog;

  /// The engine that reads the handwriting (task 2.3): the main engine,
  /// MyScript offline (GATE A), unless a test passes another.
  final Recognizer Function() makeRecognizer;

  static Recognizer _mainEngine() => buildEngines().first;

  /// Sorts writing from drawings: MyScript's own sorting, or the shape
  /// check when MyScript can't (task 2.2b).
  final InkClassifier Function() makeClassifier;

  static InkClassifier _mainClassifier() => MyScriptInkClassifier();

  /// Where corrections are saved (the app database by default).
  final Future<CorrectionStore> Function() openCorrections;

  static Future<EventLog> _openEventLog() async =>
      SqliteEventLog(await AppDatabase.open());

  /// Creates the [PdfViewer] for the chosen source (asset, file or bytes),
  /// opening at [initialPageNumber] (pdfrx keeps it inside the document).
  final PdfViewer Function(
    PdfViewerController controller,
    PdfViewerParams params,
    int initialPageNumber,
  )
  viewerBuilder;

  /// Where reading positions are kept (the app database by default).
  final Future<DocumentStateStore> Function() openStore;

  /// Where the ink is saved (the app database by default).
  final Future<InkStore> Function() openInkStore;

  /// Where the PDF's bookmarks are kept (the app database by default).
  final Future<BookmarkStore> Function() openBookmarks;

  /// Where each PDF's own page colours are kept (the app database by
  /// default).
  final Future<DocumentColoursStore> Function() openDocumentColours;

  /// The PDF file on the tablet; exporting is offered when it's known.
  final String? sourcePath;

  /// Finds where the PDF file is now, just before exporting. The library
  /// can move its stored copy while the PDF is open (e.g. keeping it
  /// permanently once it has ink), so [sourcePath] may be out of date.
  /// Null means "use [sourcePath]".
  final Future<String?> Function()? locateSource;

  /// Makes the exported PDF, and asks where to save it (injectable for
  /// tests; the defaults use PDFium and Android's save dialog).
  final Future<Uint8List> Function({
    required String sourcePath,
    required DocumentInk ink,
    PressureResponse pressure,
    Map<int, List<ExportWord>> text,
    Set<int>? onlyPages,
    bool darkPages,
    List<String>? trace,
  })
  exportPdf;
  final Future<bool> Function(String name, String mime, List<int> bytes)
  saveFile;

  /// Opens the share menu with the exported PDF (injectable for tests).
  final Future<bool> Function(String name, String mime, List<int> bytes)
  shareFile;

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  final _controller = PdfViewerController();
  final _ink = DocumentInkController();

  /// The recognised text of the handwriting (task 2.3).
  late final InkTextController _text = InkTextController(
    engine: widget.makeRecognizer(),
    classifier: widget.makeClassifier(),
    documentId: widget.documentId,
  );

  /// Typed text shown instead of the handwriting it was converted from
  /// (task 2.3c; owner: switchable, typed text by default).
  final _showTyped = ValueNotifier<bool>(true);

  /// Labels fade 5 s after writing stops, and come back with the pen
  /// near them, a tap, or the labels button (owner's choice C1 + C4).
  final _labelsShown = LabelFade();

  /// Whether [w]'s ink is converted and the typed text is showing, so its
  /// label is left out.
  bool _shownTyped(int page, RecognizedWord w) =>
      _showTyped.value && _isConverted(page, w);

  /// Whether (most of) [w]'s strokes were converted to typed text.
  bool _isConverted(int page, RecognizedWord w) =>
      mostlyConverted(w.key, convertedStrokeIds(_ink.ink.strokesOn(page)));

  bool get _hasTyped => _ink.ink.pagesWithInk.any(
    (p) => _ink.ink
        .strokesOn(p)
        // Converted handwriting (not text boxes, which always show).
        .any((s) => s.typedGroup != null && (s.typedText?.isNotEmpty ?? false)),
  );

  /// While typed text shows: what a tap at [at] on [page] does (edit the
  /// typed word there), or null.
  VoidCallback? _typedTapAt(
    int page,
    Offset at,
    PageGeometry geometry,
    double viewWidth,
  ) {
    if (!_showTyped.value) return null;
    final l = typedLineAt(_ink.ink.strokesOn(page), at, geometry, viewWidth);
    return l == null ? null : () => _editTyped(page, l);
  }

  /// Reads [page] (if needed) with a progress dialog and Cancel; null if
  /// cancelled or reading failed (the user is told why).
  Future<List<RecognizedWord>?> _readPage(int page) async {
    var cancelled = false;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: const Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 20),
              Expanded(child: Text('Reading the handwriting…')),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                cancelled = true;
                Navigator.of(context).pop();
              },
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
    Object? error;
    List<RecognizedWord> words = const [];
    try {
      words = await _text.readNow(
        page,
        _ink.ink.strokesOn(page),
        stop: () => cancelled || !mounted,
      );
    } catch (e) {
      error = e;
    } finally {
      if (!cancelled && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
    if (cancelled || !mounted) return null;
    final messenger = ScaffoldMessenger.of(context);
    if (error != null) {
      messenger.showSnackBar(
        SnackBar(content: Text("Couldn't read the handwriting: $error")),
      );
      return null;
    }
    if (words.isEmpty && _text.problem != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text("Handwriting can't be read now: ${_text.problem}"),
        ),
      );
      return null;
    }
    return words;
  }

  /// Converts [words] on [page] to typed text and shows it (task 2.3c):
  /// the words of each line become one piece of typed text, so a sentence
  /// stays together and can be edited as one (owner's choice F1).
  void _convertWords(int page, List<RecognizedWord> words) {
    final messenger = ScaffoldMessenger.of(context);
    // Words already converted (perhaps edited since) are left as they are.
    // Words with any converted stroke are left as they are (converting the
    // rest of one would repeat the converted part's text).
    final done = convertedStrokeIds(_ink.ink.strokesOn(page));
    final fresh = [
      for (final w in words)
        if (!w.key.split(',').any(done.contains)) w,
    ];
    final map = typedTextByLine(fresh);
    final count = map.values.fold(0, (n, t) => n + t.split(' ').length);
    if (map.isEmpty) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            fresh.length < words.length
                ? 'That handwriting is already converted.'
                : 'No handwriting was read there.',
          ),
        ),
      );
      if (fresh.length < words.length) _showTyped.value = true;
      return;
    }
    if (!_ink.convert(page, map)) {
      messenger.showSnackBar(
        const SnackBar(content: Text('That handwriting is already converted.')),
      );
      _showTyped.value = true;
      return;
    }
    _showTyped.value = true;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Converted $count word${count == 1 ? '' : 's'} to typed text. '
          'Undo takes it back; tap the text to edit it.',
        ),
      ),
    );
  }

  /// "Convert this page" (task 2.3c, owner's choice 2c).
  Future<void> _convertPage() async {
    final page = _pageNumber.value ?? 1;
    if (!_ink.ink.strokesOn(page).any((s) => s.tool == InkTool.pen)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('There is no handwriting on this page.')),
      );
      return;
    }
    final words = await _readPage(page);
    if (words == null || !mounted) return;
    _convertWords(page, words);
  }

  /// A lasso loop was drawn on [page]: offer to convert the words inside.
  /// The strokes picked with the Select tool (owner, 2026-10-14: select,
  /// then move, resize, or use the bar's actions), or null.
  final _selection = ValueNotifier<InkSelection?>(null);

  /// Strokes copied with the selection bar's Copy, for Paste.
  List<PageStroke>? _clipboard;

  // Search (owner's choice, 2026-10-15): the PDF's own text (pdfrx finds
  // it) and the handwriting read on its pages, in one list of matches.
  bool _searchOpen = false;
  final _searchField = TextEditingController();
  // Made when search is first opened (the PDF is loaded by then).
  PdfTextSearcher? _searcherMade;
  PdfTextSearcher get _searcher =>
      _searcherMade ??= PdfTextSearcher(_controller)..addListener(_searchFound);

  /// What's being searched for now, and whether the PDF search for it
  /// hasn't started yet (typing pauses first).
  String _query = '';
  bool _searchPending = false;
  Timer? _searchTimer;
  List<HandwritingHit> _handHits = const [];
  List<({int page, double top, int? pdf, HandwritingHit? hand})> _hits =
      const [];
  int _hitAt = -1;
  late final _pagePainters = [_paintDark, _paintSearch];

  // Bookmarks (owner's choice, 2026-10-15): the pages marked in this PDF.
  BookmarkStore? _bookmarkStore;
  Future<void> _bookmarksLoaded = Future.value();

  /// The bookmarked pages, first page first; also shown as a ribbon on
  /// each bookmarked page (the pages' layers listen to this).
  final _bookmarked = ValueNotifier<List<int>>(const []);
  List<int> get _bookmarks => _bookmarked.value;
  set _bookmarks(List<int> pages) => _bookmarked.value = pages;

  List<int> _pairOf(int page) => pagePair(page, _pageCount ?? page);

  // This PDF's own page colours (null: Settings' choice), asked when it's
  // imported (owner, 2026-10-16).
  PageColours? _ownColours;
  DocumentColoursStore? _coloursStore;

  Future<void> _coloursLoaded = Future.value();

  Future<void> _loadColours() async {
    PageColours? own;
    try {
      final store = await widget.openDocumentColours();
      own = await store.get(widget.documentId);
      _coloursStore = store;
    } catch (_) {
      _coloursStore = MemoryDocumentColoursStore();
    }
    if (mounted && own != null) setState(() => _ownColours = own);
  }

  /// A PDF imported for the very first time (never opened before, so not
  /// one whose stored copy was removed and brought back): asks how its
  /// pages should look, once its first page is showing.
  Future<void> _askColoursIfNew() async {
    await _coloursLoaded;
    if (!mounted) return;
    final settings = context
        .getInheritedWidgetOfExactType<SettingsScope>()
        ?.notifier;
    if (widget.importTook == null ||
        _saved != null ||
        _ownColours != null ||
        settings == null ||
        !settings.value.askPageColours) {
      return;
    }
    final byDefault = settings.value.pageColours;
    final pick = await askPageColours(
      context,
      byDefault: byDefault,
      importing: true,
    );
    if (pick == null || !mounted) return;
    if (pick.stopAsking) {
      settings.update(settings.value.copyWith(askPageColours: false));
    }
    // Kept as Settings' choice: the PDF follows Settings from then on.
    final chosen = pick.colours == byDefault ? null : pick.colours;
    setState(() => _ownColours = chosen);
    try {
      await _coloursStore?.set(widget.documentId, chosen);
    } catch (_) {
      // Used this time, just not kept.
    }
  }

  Future<void> _loadBookmarks() async {
    try {
      final store = await widget.openBookmarks();
      final pages = await store.pages(widget.documentId);
      if (!mounted) return;
      setState(() {
        _bookmarkStore = store;
        _bookmarks = pages;
      });
    } catch (_) {
      // Bookmarks just aren't kept this time.
      _bookmarkStore = MemoryBookmarkStore();
    }
  }

  Future<void> _toggleBookmark(int page) async {
    // Tapped while they're still loading: wait, so the tap isn't lost.
    await _bookmarksLoaded;
    if (!mounted) return;
    final on = !_bookmarks.contains(page);
    setState(
      () => _bookmarks = on
          ? ([..._bookmarks, page]..sort())
          : [
              for (final p in _bookmarks)
                if (p != page) p,
            ],
    );
    try {
      await _bookmarkStore?.set(widget.documentId, page, on: on);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Couldn't save the bookmark: $e")));
    }
  }

  /// "Contents": the PDF's own contents list (if it has one) and the
  /// pages bookmarked, each going to its page.
  Future<void> _showContents() async {
    List<PdfOutlineNode> outline = const [];
    // A big PDF's contents can take a moment: say so after a second.
    var shown = false;
    final navigator = Navigator.of(context, rootNavigator: true);
    final wait = Timer(const Duration(seconds: 1), () {
      if (!mounted) return;
      shown = true;
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => const AlertDialog(
            content: Row(
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 16),
                Text('Reading the contents…'),
              ],
            ),
          ),
        ),
      );
    });
    try {
      outline = await _controller.document.loadOutline();
    } catch (_) {
      // No contents list.
    }
    wait.cancel();
    if (shown) navigator.pop();
    if (!mounted) return;
    final page = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) =>
          ContentsSheet(outline: outline, bookmarks: _bookmarks),
    );
    if (page != null) await _controller.goToPage(pageNumber: page);
  }

  /// Pages shown dark (Settings, Page colours), as last built.
  bool _dark = false;

  /// Pages side by side in pairs (two-page view), as last built.
  bool _twoPages = false;

  void _paintDark(Canvas canvas, Rect pageRect, PdfPage page) {
    if (_dark) paintDarkPage(canvas, pageRect);
  }

  void _openSearch() {
    setState(() => _searchOpen = true);
    // New or changed writing is found while search is open.
    _text.addListener(_refreshHandHits);
    _ink.addListener(_refreshHandHits);
  }

  void _closeSearch() {
    _text.removeListener(_refreshHandHits);
    _ink.removeListener(_refreshHandHits);
    _searchTimer?.cancel();
    _searcher.resetTextSearch();
    _searchField.clear();
    setState(() {
      _searchOpen = false;
      _query = '';
      _searchPending = false;
      _handHits = const [];
      _hits = const [];
      _hitAt = -1;
    });
    _controller.invalidate();
  }

  void _search(String query) {
    final q = query.trim();
    _query = q;
    _searchTimer?.cancel();
    _searcher.resetTextSearch();
    _searchPending = q.isNotEmpty;
    if (q.isNotEmpty) {
      // The PDF search starts once typing pauses.
      _searchTimer = Timer(const Duration(milliseconds: 400), () {
        if (!mounted || _query != q) return;
        _searchPending = false;
        _searcher.startTextSearch(
          q,
          caseInsensitive: true,
          goToFirstMatch: false,
          searchImmediately: true,
        );
      });
    }
    _handHits = q.isEmpty ? const [] : searchHandwriting(_searchWords(), q);
    _hitAt = -1;
    _searchFound();
  }

  void _refreshHandHits() {
    if (!_searchOpen || _query.isEmpty || !mounted) return;
    _handHits = searchHandwriting(_searchWords(), _query);
    _searchFound();
  }

  /// The handwriting to search: converted lines by their typed text (as
  /// edited), the rest by the words read.
  List<SearchWord> _searchWords() {
    final out = <SearchWord>[];
    for (var page = 1; page <= (_pageCount ?? 0); page++) {
      final strokes = _ink.ink.strokesOn(page);
      final converted = convertedStrokeIds(strokes);
      final lineOf = <String, int>{};
      for (final w in _text.wordsOn(page)) {
        for (final id in w.key.split(',')) {
          lineOf[id] = w.line;
        }
        if (w.key.split(',').any(converted.contains)) continue;
        out.add((page: page, line: w.line, box: w.box, text: w.text));
      }
      for (final s in strokes) {
        if (!s.isTextBox || s.points.length < 2) continue;
        out.add((
          page: page,
          line: 1 << 20,
          box: InkBox.of(s),
          text: s.typedText ?? '',
        ));
      }
      for (final t in typedLines(strokes)) {
        final line = t.words
            .expand((w) => w.strokeIds)
            .map((id) => lineOf[id])
            .whereType<int>()
            .fold(1 << 20, math.min);
        out.add((page: page, line: line, box: t.box, text: t.text));
      }
    }
    return out;
  }

  /// The PDF matches for what's being searched now (none from an earlier
  /// search, while the new one waits to start).
  List<PdfPageTextRange> get _pdfMatches =>
      !_searchPending && _searcher.pattern?.toString() == _query
      ? _searcher.matches
      : const [];

  /// PDF and handwriting matches together, page by page, top first; the
  /// current match stays current as more are found.
  void _searchFound() {
    if (!mounted) return;
    final was = _hitAt >= 0 && _hitAt < _hits.length ? _hits[_hitAt] : null;
    final hits =
        [
          for (final (i, m) in _pdfMatches.indexed)
            (page: m.pageNumber, top: m.bounds.top, pdf: i, hand: null),
          for (final h in _handHits)
            (page: h.page, top: h.box.top, pdf: null, hand: h),
        ]..sort(
          (a, b) => a.page != b.page
              ? a.page.compareTo(b.page)
              : b.top.compareTo(a.top),
        );
    setState(() {
      _hits = hits;
      _hitAt = was == null
          ? -1
          : hits.indexWhere(
              (h) => was.pdf != null
                  ? h.pdf == was.pdf
                  : identical(h.hand, was.hand),
            );
    });
    _controller.invalidate();
  }

  Future<void> _goToHit(int step) async {
    final n = _hits.length;
    if (n == 0) return;
    setState(
      () => _hitAt = _hitAt < 0 ? (step > 0 ? 0 : n - 1) : (_hitAt + step) % n,
    );
    final hit = _hits[_hitAt];
    final pdf = hit.pdf;
    final hand = hit.hand;
    final match = pdf == null ? null : _pdfMatches[pdf];
    final page = match?.pageNumber ?? hand!.page;
    final r =
        match?.bounds ??
        PdfRect(hand!.box.left, hand.box.top, hand.box.right, hand.box.bottom);
    await _controller.ensureVisible(
      _controller.calcRectForRectInsidePage(pageNumber: page, rect: r),
      margin: 50,
    );
    _controller.invalidate();
  }

  /// Highlights the matches: yellow, and the current one orange.
  void _paintSearch(Canvas canvas, Rect pageRect, PdfPage page) {
    if (!_searchOpen) return;
    final current = _hitAt >= 0 && _hitAt < _hits.length ? _hits[_hitAt] : null;
    void mark(PdfRect r, bool now, {double room = 0}) => canvas.drawRect(
      r
          .toRect(page: page, scaledPageSize: pageRect.size)
          .translate(pageRect.left, pageRect.top)
          .inflate(room),
      Paint()..color = now ? const Color(0x80FF9800) : const Color(0x80FFEB3B),
    );
    for (final (i, m) in _pdfMatches.indexed) {
      if (m.pageNumber == page.pageNumber) mark(m.bounds, current?.pdf == i);
    }
    for (final h in _handHits) {
      if (h.page != page.pageNumber) continue;
      mark(
        PdfRect(h.box.left, h.box.top, h.box.right, h.box.bottom),
        identical(h, current?.hand),
        room: 2,
      );
    }
  }

  /// A loop was drawn with the Select tool on [page]: select what's inside.
  void _lassoDrawn(int page, List<PageInkPoint> loop) {
    final picked = strokesInLoop(_ink.ink.strokesOn(page), loop);
    if (picked.isEmpty) {
      _selection.value = null;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Nothing inside the loop. Draw it all the way around the '
            'handwriting.',
          ),
        ),
      );
      return;
    }
    _selection.value = InkSelection(page, picked);
  }

  /// The selection bar's "Convert": the words mostly inside the selection.
  Future<void> _convertSelection(InkSelection sel) async {
    _selection.value = null;
    final words = await _readPage(sel.page);
    if (words == null || !mounted) return;
    _convertWords(sel.page, [
      for (final w in words)
        if (w.key.isNotEmpty &&
            w.key.split(',').where(sel.ids.contains).length * 2 >=
                w.key.split(',').length)
          w,
    ]);
  }

  /// "Read as one word": these strokes are always read together, as
  /// writing (also kept as a lesson for a future word-finding model).
  void _oneWord(InkSelection sel) {
    _selection.value = null;
    _text.markWriting(sel.page, sel.ids);
    _ink.markOneWord(sel.page, sel.ids);
    _logDiagnostic('one_word', {'strokes': sel.ids.length});
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('These strokes are read as one word now.')),
    );
  }

  /// "This isn't writing" for everything selected.
  void _selectionNotWriting(InkSelection sel) {
    _selection.value = null;
    for (final w in _text.wordsOn(sel.page)) {
      if (w.key.split(',').every(sel.ids.contains)) {
        _text.markNotWriting(sel.page, w);
      }
    }
    _ink.markNotWriting(sel.page, sel.ids);
  }

  Future<void> _recolourSelection(InkSelection sel) async {
    final argb = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Colour'),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in penColours)
                  Tooltip(
                    message: colourName(c),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => Navigator.of(context).pop(c),
                      child: CircleAvatar(backgroundColor: Color(c)),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (argb != null) _ink.recolour(sel.page, sel.ids, argb);
  }

  void _copySelection(
    InkSelection sel, {
    String said = 'Copied. Use Paste in the title bar on any page.',
  }) {
    _clipboard = [
      for (final s in _ink.ink.strokesOn(sel.page))
        if (sel.ids.contains(s.id)) s,
    ];
    setState(() {}); // shows Paste in the title bar
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(said)));
  }

  /// "Cut": Copy, then Delete.
  void _cutSelection(InkSelection sel) {
    _copySelection(sel, said: 'Cut. Use Paste in the title bar on any page.');
    _deleteSelection(sel);
  }

  /// "Duplicate": a copy just beside the selection, selected.
  void _duplicateSelection(InkSelection sel) {
    final copies = pastedCopies([
      for (final s in _ink.ink.strokesOn(sel.page))
        if (sel.ids.contains(s.id)) s,
    ], DateTime.now().millisecondsSinceEpoch);
    _ink.addStrokes(sel.page, copies);
    _selection.value = InkSelection(sel.page, {for (final s in copies) s.id});
  }

  /// "Thickness": thinner or thicker lines for the selection.
  Future<void> _thicknessSelection(InkSelection sel) async {
    final picked = [
      for (final s in _ink.ink.strokesOn(sel.page))
        if (sel.ids.contains(s.id)) s,
    ];
    // Measured on the pen strokes, or the highlighter if that's all there
    // is, with that tool's range.
    final pen = picked.any((s) => s.tool == InkTool.pen);
    final (lo, hi) = pen
        ? (PenStyle.minPenWidth, PenStyle.maxPenWidth)
        : (PenStyle.minHighlighterWidth, PenStyle.maxHighlighterWidth);
    final widths = [
      for (final s in picked)
        if ((s.tool == InkTool.pen) == pen) s.width,
    ]..sort();
    if (widths.isEmpty) return;
    final now = widths[widths.length ~/ 2];
    final start = now.clamp(lo, hi);
    var chosen = start;
    final width = await showDialog<double>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('Thickness'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${chosen.toStringAsFixed(1)} pt'),
              Slider(
                value: chosen,
                min: lo,
                max: hi,
                divisions: ((hi - lo) * 10).round(),
                label: '${chosen.toStringAsFixed(1)} pt',
                onChanged: (w) => setDialog(() => chosen = w),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(chosen),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    // Unchanged (Apply without moving the slider): nothing to do.
    if (width == null || width == start || now <= 0) return;
    // Everything selected changes by the same amount, so a highlighter
    // stroke in the selection stays as much wider as it was.
    _ink.scaleWidth(
      sel.page,
      sel.ids,
      width / now,
      (tool) => tool == InkTool.pen
          ? (PenStyle.minPenWidth, PenStyle.maxPenWidth)
          : (PenStyle.minHighlighterWidth, PenStyle.maxHighlighterWidth),
    );
  }

  /// "Straighten": slanted lines of writing in the selection turned level.
  void _straightenSelection(InkSelection sel) {
    final level = straightened([
      for (final s in _ink.ink.strokesOn(sel.page))
        if (sel.ids.contains(s.id)) s,
    ]);
    if (level.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This writing is level already.')),
      );
      return;
    }
    _ink.replaceStrokes(sel.page, level);
  }

  /// "Copy as text": the words read in the selection, to paste in another
  /// app.
  Future<void> _copySelectionText(InkSelection sel) async {
    final messenger = ScaffoldMessenger.of(context);
    final words = await _readPage(sel.page);
    if (words == null || !mounted) return;
    // Converted writing: its typed text (perhaps edited since); the rest:
    // the words read.
    final strokes = _ink.ink.strokesOn(sel.page);
    final converted = convertedStrokeIds(strokes);
    final lineOf = {
      for (final w in words)
        for (final id in w.key.split(',')) id: w.line,
    };
    final text = selectionText([
      for (final t in typedLines(strokes))
        (
          line: t.words
              .expand((w) => w.strokeIds)
              .map((id) => lineOf[id])
              .whereType<int>()
              .fold(1 << 20, math.min),
          strokeIds: [for (final w in t.words) ...w.strokeIds],
          text: t.text,
        ),
      for (final w in words)
        if (!w.key.split(',').any(converted.contains))
          (line: w.line, strokeIds: w.key.split(','), text: w.text),
    ], sel.ids);
    if (text.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No words were read in the selection.')),
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(SnackBar(content: Text('Copied the text: "$text"')));
  }

  /// "Share": a picture of the selected ink, through Android's share
  /// menu (nothing is sent until the user picks an app).
  Future<void> _shareSelection(InkSelection sel, PageGeometry geometry) async {
    final messenger = ScaffoldMessenger.of(context);
    final pressure = SettingsScope.valueOf(context).pressureResponse;
    final navigator = Navigator.of(context, rootNavigator: true);
    // A big selection can take a moment to draw: say so (never freeze
    // without feedback).
    var waiting = true;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => const AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Text('Making the picture…'),
            ],
          ),
        ),
      ).whenComplete(() => waiting = false),
    );
    void closeWaiting() {
      if (waiting) navigator.pop();
      waiting = false;
    }

    try {
      final png = await inkImage(
        [
          for (final s in _ink.ink.strokesOn(sel.page))
            if (sel.ids.contains(s.id)) s,
        ],
        geometry,
        pressure: pressure,
      );
      closeWaiting();
      if (png == null || !mounted) return;
      await widget.shareFile('handwriting.png', 'image/png', png);
    } catch (e) {
      closeWaiting();
      messenger.showSnackBar(SnackBar(content: Text("Couldn't share: $e")));
    }
  }

  /// The Text tool tapped [at] on [page]: edit the text box there, or
  /// place a new one with its top-left corner there.
  Future<void> _textBoxAt(int page, PdfPagePoint at) async {
    // Text is laid out along the page's own rows, which run up and down the
    // screen on a page turned sideways: not there yet.
    if (_geometryOf(_controller.document.pages[page - 1]).quarterTurns != 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Text boxes can't be added to pages turned sideways yet.",
          ),
        ),
      );
      return;
    }
    PageStroke? existing;
    for (final s in _ink.ink.strokesOn(page).reversed) {
      if (s.isTextBox && s.distanceTo(at.x, at.y) <= 4) {
        existing = s;
        break;
      }
    }
    final result = await showDialog<({String text, double size})?>(
      context: context,
      builder: (context) => TextBoxDialog(
        text: existing?.typedText ?? '',
        size: existing?.width ?? _textSize,
        editing: existing != null,
      ),
    );
    if (result == null || !mounted) return;
    if (existing != null) {
      final text = result.text;
      if (text.trim().isEmpty) {
        _ink.removeStrokes(page, {existing.id});
        return;
      }
      // Same first point time and point count, so the same id: the edit
      // is one change to the same box.
      final (w, h) = _measureText(text, result.size);
      final corner = PageInkPoint(
        math.min(existing.points.first.x, existing.points.last.x),
        math.max(existing.points.first.y, existing.points.last.y),
        existing.points.first.t,
        existing.points.first.pressure,
      );
      _ink.replaceStrokes(page, [
        PageStroke(
          points: [
            corner,
            PageInkPoint(corner.x + w, corner.y - h, existing.points.last.t),
          ],
          tool: InkTool.text,
          width: result.size,
          colorArgb: existing.colorArgb,
          typedText: text,
        ),
      ]);
    } else if (result.text.trim().isNotEmpty) {
      _textSize = result.size;
      _ink.addStrokes(page, [
        textBox(
          result.text,
          at.x,
          at.y,
          size: result.size,
          colorArgb: _tools.value.pen.colorArgb,
          nowMs: DateTime.now().millisecondsSinceEpoch,
          measured: _measureText(result.text, result.size),
        ),
      ]);
    }
  }

  /// How much room [text] takes on the page at [size] points, measured as
  /// it's drawn (so a tap anywhere on it finds the box).
  (double, double) _measureText(String text, double size) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: size, height: 1.25),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final measured = (painter.width, painter.height);
    painter.dispose();
    return measured;
  }

  /// The size new text boxes get (the last one chosen).
  double _textSize = 12;

  void _deleteSelection(InkSelection sel) {
    _selection.value = null;
    _ink.removeStrokes(sel.page, sel.ids);
  }

  /// Pastes the copied strokes on the page showing, a little down and to
  /// the right of where they were, and selects them.
  void _paste() {
    final copied = _clipboard;
    if (copied == null || copied.isEmpty) return;
    final page = _pageNumber.value ?? 1;
    final pasted = pastedCopies(copied, DateTime.now().millisecondsSinceEpoch);
    _ink.addStrokes(page, pasted);
    _selection.value = InkSelection(page, {for (final s in pasted) s.id});
  }

  /// Tap on typed text: edit it (owner's choice 4a). The edit also teaches
  /// the learning layer, like a correction.
  Future<void> _editTyped(int page, TypedLine typed) async {
    final field = TextEditingController(text: typed.text);
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit typed text'),
        content: TextField(
          controller: field,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Text'),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(field.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    // After the dialog has finished closing (it still uses the field).
    WidgetsBinding.instance.addPostFrameCallback((_) => field.dispose());
    final t = text?.trim() ?? '';
    if (t.isEmpty || t == typed.text || !mounted) return;
    // The whole line is edited, even if it was converted in pieces; it
    // becomes one piece from then on.
    final groups = [for (final w in typed.words) w.group];
    _ink.setTypedText(page, groups.first, t, merge: groups.skip(1).toSet());
    final strokeIds = {for (final w in typed.words) ...w.strokeIds};
    // Teach the learning layer, like a correction, word by word: the words
    // as read (mostly the same strokes), left to right, matched with the
    // edited words when there are as many of them.
    final read = [
      for (final w in _text.wordsOn(page))
        if (mostlyConverted(w.key, strokeIds)) w,
    ]..sort((a, b) => a.box.left.compareTo(b.box.left));
    final before = typed.text.split(RegExp(r'\s+'));
    final after = t.split(RegExp(r'\s+'));
    if (read.length != before.length || before.length != after.length) return;
    for (var i = 0; i < read.length; i++) {
      if (after[i] != before[i]) await _text.correct(page, read[i], after[i]);
    }
  }

  /// Double-tap on a label: correct the word (task 2.4).
  Future<void> _fixWord(int page, RecognizedWord word) async {
    final fix = await showCorrectWordSheet(context, word);
    switch (fix) {
      case UseText(:final text):
        await _text.correct(page, word, text);
      case NotWriting():
        // Saved on the strokes, so it lasts when the PDF is reopened.
        _ink.markNotWriting(page, word.key.split(',').toSet());
        _text.markNotWriting(page, word);
      case null:
        break;
    }
  }

  /// Double-tap on ink marked "This isn't writing": offer to read it as
  /// writing again (task 2.4d).
  Future<void> _askUnhide(int page, HiddenInk hidden) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hidden ink'),
        content: const Text(
          "You marked this ink as not writing, so it isn't read. Read it "
          'as writing again?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('This is writing'),
          ),
        ],
      ),
    );
    if (yes == true) _unhide(page, hidden);
  }

  /// Reads [hidden] as writing again. The text controller forgets the mark
  /// first, so the reading the ink change triggers includes it.
  void _unhide(int page, HiddenInk hidden) {
    _text.markWriting(page, hidden.ids);
    _ink.markWriting(page, hidden.ids);
  }

  /// Whether recognised text shows under the ink.
  /// Labels on or off from the title bar (remembers above/below).
  TextLabelPlace _lastLabels = TextLabelPlace.above;

  void _toggleLabels() {
    final settings = SettingsScope.of(context);
    final s = settings.value;
    // On but faded: bring them back rather than switching them off (C4).
    if (s.textLabels != TextLabelPlace.off && !_labelsShown.value) {
      _labelsShown.wake();
      return;
    }
    _labelsShown.wake();
    if (s.textLabels != TextLabelPlace.off) _lastLabels = s.textLabels;
    settings.update(
      s.copyWith(
        textLabels: s.textLabels == TextLabelPlace.off
            ? _lastLabels
            : TextLabelPlace.off,
      ),
    );
  }

  /// The text panel on or off from the title bar (opens on the right).
  TextPanelPlace _lastPanel = TextPanelPlace.right;

  void _togglePanel() {
    final settings = SettingsScope.of(context);
    final s = settings.value;
    if (s.textPanel != TextPanelPlace.off) _lastPanel = s.textPanel;
    _placePanel(
      s.textPanel == TextPanelPlace.off ? _lastPanel : TextPanelPlace.off,
    );
  }

  void _placePanel(TextPanelPlace place) {
    final settings = SettingsScope.of(context);
    settings.update(settings.value.copyWith(textPanel: place));
  }

  void _inkChangedForText(int page) {
    _labelsShown.wake();
    _text.inkChanged(
      page,
      _ink.ink.strokesOn(page),
      Duration(
        milliseconds: SettingsScope.of(context).value.recognitionPauseMs,
      ),
    );
  }

  /// The pen hovering near a recognised word (or its label, just above or
  /// below it) brings the labels back.
  void _penHover(int page, Offset at, PageGeometry geometry, double width) {
    final p = geometry.toPdf(ViewPoint(at.dx, at.dy), width);
    for (final w in _text.wordsOn(page)) {
      // A word at a slant: measured turned level.
      final slant = w.slant;
      final b = slant?.box ?? w.box, reach = b.height * 1.5;
      final q = slant == null
          ? PageInkPoint(p.x, p.y, 0)
          : levelPoint(
              PageInkPoint(p.x, p.y, 0),
              slant.angle,
              slant.cx,
              slant.cy,
            );
      if (q.x >= b.left - reach &&
          q.x <= b.right + reach &&
          q.y >= b.bottom - reach &&
          q.y <= b.top + reach) {
        _labelsShown.wake();
        return;
      }
    }
  }

  InkAutosaver? _autosaver;

  /// Saves the recognised text with the ink, so reopening doesn't read it
  /// all again.
  TextAutosaver? _textSaver;

  /// Screen drawing times, every 30 s with what was on screen (owner's
  /// request, for finding what makes it stutter).
  late final _frames = FrameRecorder(
    onScreen: _onScreenCounts,
    onSummary: (s) => _logDiagnostic('frames', s),
  );

  /// Counts of what's on the pages around the one showing (no content).
  Map<String, Object?> _onScreenCounts() {
    final current = _pageNumber.value ?? 1;
    final pages = [current - 1, current, current + 1];
    var strokes = 0, labels = 0, typed = 0;
    for (final p in pages) {
      final s = _ink.ink.strokesOn(p);
      strokes += s.length;
      typed += typedLines(s).length;
      labels += _text.wordsOn(p).length;
    }
    double? zoom;
    try {
      zoom = _controller.isReady ? _controller.currentZoom : null;
    } catch (_) {}
    return {
      'pagesInPdf': _pageCount,
      'strokesNearby': strokes,
      'labelsNearby': labels,
      'typedLinesNearby': typed,
      'strokesInPdf': _ink.ink.pagesWithInk.fold<int>(
        0,
        (n, p) => n + _ink.ink.strokesOn(p).length,
      ),
      if (zoom != null) 'zoom': (zoom * 100).round() / 100,
    };
  }

  /// Records what happened for Settings → Testing → "Save diagnostic
  /// report" (owner's request: logs to send when something fails). Stays on
  /// the tablet like the rest of the event log.
  void _logDiagnostic(String area, Map<String, Object?> data) {
    unawaited(
      _text.eventLog
              ?.log(
                LoggedEvent(
                  type: 'diagnostic',
                  at: DateTime.now(),
                  data: {'area': area, ...data},
                ),
              )
              .catchError((_) {}) ??
          Future<void>.value(),
    );
  }

  void _flushSaves() {
    _autosaver?.flush();
    _textSaver?.flush();
  }

  late final AppLifecycleListener _lifecycle;

  /// False until saved ink has loaded (a small notice shows meanwhile).
  final _inkLoaded = ValueNotifier<bool>(false);
  bool _saveErrorShown = false;
  final _tools = PenToolsController();

  /// Keeps the open PDF (and its zoom/scroll) when the toolbar moves.
  final _pageKey = GlobalKey();
  final _pageNumber = ValueNotifier<int?>(null);

  /// True while scrolling; false once idle (then the tab shows, shrinks or
  /// hides depending on the user's setting).
  final _thumbActive = ValueNotifier<bool>(true);
  Timer? _hideTimer;
  Timer? _saveTimer;
  int? _pageCount;
  DocumentStateStore? _store;

  /// False until the viewer has moved to the saved page, so the first
  /// "page 1" report while opening doesn't overwrite the saved position.
  bool _restored = false;

  late final DateTime _tappedAt;

  /// When the PDF file was open (pages may still be loading).
  int? _readyMs;
  int _resumePage = 1;
  bool _timingShown = false;
  Timer? _resumeNoteTimer;

  /// True when the first page is taking a while, to offer Cancel.
  final _slowOpen = ValueNotifier<bool>(false);
  Timer? _slowOpenTimer;

  /// Closes the PDF while it is still opening (nothing is recorded).
  void _cancelOpening() => Navigator.of(context).maybePop();

  /// Built once the saved page is known, so it opens straight there.
  PdfViewer? _viewer;

  Future<void> _prepareViewer() async {
    DocumentState? saved;
    try {
      _store = await widget.openStore();
      saved = await _store!.get(widget.documentId);
    } catch (_) {
      // No saved position (e.g. storage unavailable): start at page 1.
    }
    if (!mounted) return;
    _saved = saved;
    setState(() {
      _viewer = widget.viewerBuilder(
        _controller,
        _viewerParams(),
        saved?.lastPage ?? 1,
      );
    });
  }

  DocumentState? _saved;

  PdfViewerParams _viewerParams() => PdfViewerParams(
    // Text is selected with a long-press and handles (the touch style)
    // whatever touched the screen last. Otherwise, after the pen has
    // been used, pdfrx makes a one-finger drag select text, so fingers
    // can no longer scroll or zoom the page.
    textSelectionParams: const PdfTextSelectionParams(
      enableSelectionHandles: true,
    ),
    pageOverlaysBuilder: _buildPageOverlays,
    pagePaintCallbacks: _pagePainters,
    // Read each time pages are laid out, so the two-page switch works on
    // the open viewer.
    layoutPages: (pages, params) =>
        pageLayout(pages, params, twoPages: _twoPages),
    viewerOverlayBuilder: (context, size, handleLinkTap) => [
      PdfViewerScrollThumb(
        controller: _controller,
        orientation: ScrollbarOrientation.right,
        thumbSize: const Size(72, 44),
        thumbBuilder: _buildScrollThumb,
      ),
    ],
    loadingBannerBuilder: (context, bytesDownloaded, totalBytes) =>
        _OpeningBanner(title: widget.title, onCancel: _cancelOpening),
    onViewerReady: _onViewerReady,
    onPageChanged: _onPageChanged,
    // Called once the page it opened at has been drawn and every page's
    // size is known.
    onDocumentLoadFinished: (_, ok) {
      if (ok) _onFirstPageShown();
    },
  );

  Future<void> _onViewerReady(
    PdfDocument document,
    PdfViewerController controller,
  ) async {
    final pages = document.pages.length;
    setState(() => _pageCount = pages);
    _readyMs ??= DateTime.now().difference(_tappedAt).inMilliseconds;
    final resume = _saved?.resumePageFor(pages) ?? 1;
    _resumePage = resume;
    if (resume > 1 && controller.pageNumber != resume) {
      await controller.goToPage(pageNumber: resume, duration: Duration.zero);
    }
    _restored = true;
    if (!mounted || resume <= 1) return;
    // The timing message says where it continued from; if the first page is
    // slow to draw, say so now instead.
    _resumeNoteTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || _timingShown) return;
      _showOpenMessage(null);
    });
  }

  Future<void> _onFirstPageShown() async {
    if (_timingShown || !mounted) return;
    final shownMs = DateTime.now().difference(_tappedAt).inMilliseconds;
    final source = widget.sourcePath;
    int? bytes;
    if (source != null) {
      try {
        bytes = await File(source).length();
      } catch (_) {}
    }
    final timing = OpenTiming(
      name: widget.title,
      at: _tappedAt,
      shownMs: shownMs,
      readyMs: _readyMs ?? shownMs,
      importMs: widget.importTook?.inMilliseconds,
      fileBytes: bytes,
      pages: _pageCount ?? 0,
      page: _resumePage,
    );
    unawaited(
      widget
          .openEventLog()
          .then((log) => log.log(timing.toEvent(widget.documentId)))
          .catchError((_) {}),
    );
    if (!mounted) return;
    _showOpenMessage(timing);
    unawaited(_askColoursIfNew());
  }

  void _showOpenMessage(OpenTiming? timing) {
    final resume = _resumePage;
    final messenger = ScaffoldMessenger.of(context);
    if (timing != null) {
      _timingShown = true;
      _resumeNoteTimer?.cancel();
      _slowOpenTimer?.cancel();
      _slowOpen.value = false;
    }
    final parts = [
      if (timing != null) '${timing.describe()}.',
      if (resume > 1) 'Continuing from page $resume.',
    ];
    if (parts.isEmpty) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 4),
          content: Text(parts.join(' ')),
          action: resume > 1
              ? SnackBarAction(
                  label: 'Go to page 1',
                  onPressed: () => _controller.goToPage(pageNumber: 1),
                )
              : null,
        ),
      );
  }

  void _onPageChanged(int? pageNumber) {
    _pageNumber.value = pageNumber;
    if (!_restored || pageNumber == null) return;
    // Save shortly after scrolling settles, not on every page flick.
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), _savePosition);
  }

  void _savePosition() {
    final page = _pageNumber.value, pages = _pageCount, store = _store;
    if (!_restored || page == null || pages == null || store == null) return;
    store
        .save(
          DocumentState(
            id: widget.documentId,
            lastPage: page,
            pageCount: pages,
            updatedAt: DateTime.now(),
          ),
        )
        .catchError((_) {});
  }

  static PageGeometry _geometryOf(PdfPage page) {
    final turns = page.rotation.index;
    // pdfrx reports width/height after rotation; we want the unrotated size.
    final sideways = turns.isOdd;
    return PageGeometry(
      width: sideways ? page.height : page.width,
      height: sideways ? page.width : page.height,
      quarterTurns: turns,
    );
  }

  List<Widget> _buildPageOverlays(
    BuildContext context,
    Rect pageRect,
    PdfPage page,
  ) => [
    // A ribbon on a bookmarked page, so it shows which of two pages side
    // by side is marked. Never takes a touch.
    Positioned(
      top: 0,
      right: pageRect.width * 0.04,
      child: IgnorePointer(
        child: ValueListenableBuilder(
          valueListenable: _bookmarked,
          builder: (context, bookmarks, _) =>
              bookmarks.contains(page.pageNumber)
              ? Icon(
                  Icons.bookmark,
                  size: (pageRect.width * 0.05).clamp(14.0, 40.0),
                  color: Theme.of(context).colorScheme.primary,
                  semanticLabel: 'Bookmarked',
                )
              : const SizedBox.shrink(),
        ),
      ),
    ),
    Positioned.fill(
      // Finger tap on typed text: edit it (task 2.3c). Fingers otherwise
      // pass through to scroll and zoom.
      child: GestureDetector(
        supportedDevices: const {PointerDeviceKind.touch},
        behavior: HitTestBehavior.translucent,
        onTapUp: (d) {
          _labelsShown.wake();
          _typedTapAt(
            page.pageNumber,
            d.localPosition,
            _geometryOf(page),
            pageRect.width,
          )?.call();
        },
        child: PageInkLayer(
          pageNumber: page.pageNumber,
          geometry: _geometryOf(page),
          viewWidth: pageRect.width,
          controller: _ink,
          tools: _tools,
          showTyped: _showTyped,
          onLasso: (loop) => _lassoDrawn(page.pageNumber, loop),
          selection: _selection,
          onClearSelection: () => _selection.value = null,
          onTextTap: (at) => _textBoxAt(page.pageNumber, at),
          // The guide shows once the writing is read as a word.
          wordsRead: _text,
          isRead: (id) => _text
              .wordsOn(page.pageNumber)
              .any((w) => w.key.split(',').contains(id)),
          onPenHover: (at) =>
              _penHover(page.pageNumber, at, _geometryOf(page), pageRect.width),
          // Pen tap on typed text: edit it (task 2.3c).
          tapActionAt: (at) => _typedTapAt(
            page.pageNumber,
            at,
            _geometryOf(page),
            pageRect.width,
          ),
          // Pen double-tap on a word's label: correct it (task 2.4b).
          // On ink marked "This isn't writing": offer to undo that (2.4d).
          doubleTapActionAt: (at) {
            final place = SettingsScope.valueOf(context).textLabels;
            final word = place == TextLabelPlace.off
                ? null
                : PageTextLabels.wordAtLabel(
                    [
                      for (final w in _text.wordsOn(page.pageNumber))
                        if (!_shownTyped(page.pageNumber, w)) w,
                    ],
                    at,
                    geometry: _geometryOf(page),
                    viewWidth: pageRect.width,
                    above: place == TextLabelPlace.above,
                    textScaler: MediaQuery.textScalerOf(context),
                  );
            if (word != null) {
              return (
                target: word.key,
                action: () => _fixWord(page.pageNumber, word),
              );
            }
            final p = _geometryOf(page)
                .toPdf(ViewPoint(at.dx, at.dy), pageRect.width);
            final hidden = hiddenInkAt(
              _ink.ink.strokesOn(page.pageNumber),
              p.x,
              p.y,
            );
            return hidden == null
                ? null
                : (
                    target: 'hidden:${(hidden.ids.toList()..sort()).join(',')}',
                    action: () => _askUnhide(page.pageNumber, hidden),
                  );
          },
        ),
      ),
    ),
    Positioned.fill(
      child: Builder(
        builder: (context) {
          final place = SettingsScope.valueOf(context).textLabels;
          return place == TextLabelPlace.off
              ? const SizedBox.shrink()
              : PageTextLabels(
                  above: place == TextLabelPlace.above,
                  pageNumber: page.pageNumber,
                  geometry: _geometryOf(page),
                  viewWidth: pageRect.width,
                  text: _text,
                  strokes: () => _ink.ink.strokesOn(page.pageNumber),
                  onDoubleTap: (w) => _fixWord(page.pageNumber, w),
                  skip: (w) => _shownTyped(page.pageNumber, w),
                  refresh: Listenable.merge([_ink, _showTyped]),
                  shown: _labelsShown,
                );
        },
      ),
    ),
    Positioned.fill(
      child: PageTypedText(
        pageNumber: page.pageNumber,
        geometry: _geometryOf(page),
        viewWidth: pageRect.width,
        controller: _ink,
        showTyped: _showTyped,
      ),
    ),
    // The selection bar, just above what's selected (below it when that's
    // at the top of the page).
    Positioned.fill(
      child: ListenableBuilder(
        listenable: Listenable.merge([_selection, _ink]),
        builder: (context, _) {
          final sel = _selection.value;
          if (sel == null || sel.page != page.pageNumber) {
            return const SizedBox.shrink();
          }
          final rect = selectionRect(
            _ink.ink.strokesOn(page.pageNumber),
            sel.ids,
            _geometryOf(page),
            pageRect.width,
          );
          if (rect == null) return const SizedBox.shrink();
          const barHeight = 48.0;
          final top = rect.top >= barHeight + 8
              ? rect.top - barHeight - 8
              : rect.bottom + 8;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                // About as wide as the bar, so it stays on the page.
                left: rect.left.clamp(0, math.max(0, pageRect.width - 520)),
                top: top,
                child: SelectionBar(
                  count: sel.ids.length,
                  onOneWord: () => _oneWord(sel),
                  onConvert: () => _convertSelection(sel),
                  onColour: () => _recolourSelection(sel),
                  onCopy: () => _copySelection(sel),
                  onCut: () => _cutSelection(sel),
                  onDuplicate: () => _duplicateSelection(sel),
                  onThickness: () => _thicknessSelection(sel),
                  onStraighten: () => _straightenSelection(sel),
                  onCopyText: () => _copySelectionText(sel),
                  onShare: () => _shareSelection(sel, _geometryOf(page)),
                  onDelete: () => _deleteSelection(sel),
                  onNotWriting: () => _selectionNotWriting(sel),
                  onClose: () => _selection.value = null,
                ),
              ),
            ],
          );
        },
      ),
    ),
  ];

  /// The search box under the title bar: what to find, how many matches,
  /// and buttons to step through them.
  PreferredSizeWidget _searchBar() => PreferredSize(
    preferredSize: const Size.fromHeight(52),
    child: ListenableBuilder(
      listenable: _searcher,
      builder: (context, _) {
        final searching = _searcher.isSearching || _searchPending;
        final count = _hits.isEmpty
            ? (_searchField.text.trim().isEmpty
                  ? ''
                  : (searching ? 'Searching…' : 'No matches'))
            : '${_hitAt < 0 ? '–' : _hitAt + 1} of ${_hits.length}';
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 4, 6),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchField,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  decoration: const InputDecoration(
                    hintText: 'Search the text and your handwriting',
                    isDense: true,
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: _search,
                  onSubmitted: (_) => _goToHit(1),
                ),
              ),
              const SizedBox(width: 8),
              if (searching)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(count),
              ),
              IconButton(
                tooltip: 'Previous match',
                icon: const Icon(Icons.keyboard_arrow_up),
                onPressed: _hits.isEmpty ? null : () => _goToHit(-1),
              ),
              IconButton(
                tooltip: 'Next match',
                icon: const Icon(Icons.keyboard_arrow_down),
                onPressed: _hits.isEmpty ? null : () => _goToHit(1),
              ),
              IconButton(
                tooltip: 'Close search',
                icon: const Icon(Icons.close),
                onPressed: _closeSearch,
              ),
            ],
          ),
        );
      },
    ),
  );

  Future<void> _askForPage() async {
    final pages = _pageCount;
    if (pages == null) return;
    final page = await showDialog<int>(
      context: context,
      builder: (context) =>
          _GoToPageDialog(pageCount: pages, current: _pageNumber.value ?? 1),
    );
    if (page != null) await _controller.goToPage(pageNumber: page);
  }

  /// Draggable thumb on the right edge; shows the current page number.
  Widget _buildScrollThumb(
    BuildContext context,
    Size thumbSize,
    int? pageNumber,
    PdfViewerController controller,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final settings = SettingsScope.of(context).value;
    final idleMode = settings.scrollTabIdle;
    final slimOpacity = settings.slimTabOpacityPercent / 100;
    return ValueListenableBuilder(
      valueListenable: _thumbActive,
      builder: (context, active, _) {
        final full = active || idleMode == ScrollTabIdle.visible;
        final slim = !full && idleMode == ScrollTabIdle.slim;
        final hidden = !full && idleMode == ScrollTabIdle.hidden;
        const duration = Duration(milliseconds: 250);
        // Hidden: ignores touches, so an invisible tab can't get in the way;
        // scrolling brings it back. Slim: a thin see-through bar that can
        // still be grabbed (its touch area is a bit wider than the bar).
        return IgnorePointer(
          ignoring: hidden,
          child: AnimatedOpacity(
            opacity: hidden ? 0 : (slim ? slimOpacity : 1),
            duration: duration,
            child: Align(
              alignment: Alignment.centerRight,
              child: Container(
                width: slim ? 28 : thumbSize.width,
                color: Colors.transparent,
                alignment: Alignment.centerRight,
                child: AnimatedContainer(
                  duration: duration,
                  width: slim ? 10 : thumbSize.width,
                  height: thumbSize.height,
                  child: Tooltip(
                    message: 'Drag to jump through the document',
                    child: Material(
                      color: scheme.primaryContainer,
                      elevation: slim ? 0 : 3,
                      borderRadius: BorderRadius.circular(slim ? 5 : 8),
                      child: slim
                          ? null
                          : Center(
                              child: Text(
                                pageNumber == null ? '' : '$pageNumber',
                                maxLines: 1,
                                style: TextStyle(
                                  color: scheme.onPrimaryContainer,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  void initState() {
    super.initState();
    _frames.start();
    _bookmarksLoaded = _loadBookmarks();
    _coloursLoaded = _loadColours();
    // A selection belongs to the Select tool.
    _tools.addListener(() {
      if (_tools.value.mode != PenMode.lasso) _selection.value = null;
    });
    _tappedAt = widget.tappedAt ?? DateTime.now();
    _slowOpenTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && !_timingShown) _slowOpen.value = true;
    });
    // Any scroll or zoom shows the tab and restarts the hide countdown.
    _controller.addListener(_showThumbForAWhile);
    _showThumbForAWhile();
    PenToolsController.load().then((saved) {
      if (mounted) _tools.value = saved.value;
      saved.dispose();
    });
    // Save straight away if the app is sent to the background (it may be
    // closed there without warning).
    _lifecycle = AppLifecycleListener(
      onHide: _flushSaves,
      onPause: _flushSaves,
    );
    _loadInk();
    widget
        .openCorrections()
        .then<void>((store) {
          _text.corrections = store;
          return _text.loadCorrections();
        })
        .catchError((_) {}); // corrections then last only while open
    widget
        .openEventLog()
        .then<void>((log) => _text.eventLog = log)
        .catchError(
          (_) {}, // nothing is logged if the database can't be opened
        );
    _prepareViewer();
  }

  /// The words kept on every PDF's pages, so the user's own words win
  /// when the engine isn't sure (owner's approved idea: personal
  /// re-ranking). Read away from the screen's thread (a lot of text when
  /// there are many PDFs).
  Future<List<UsedWord>> _vocabularyOf(InkStore store) async {
    final pages = <String>[];
    for (final id in await store.documentsWithInk()) {
      pages.addAll((await store.loadText(id)).values);
    }
    return compute(vocabularyFromPages, pages);
  }

  Future<void> _loadInk() async {
    try {
      final store = await widget.openInkStore();
      final saved = await store.load(widget.documentId);
      final savedText = await store
          .loadText(widget.documentId)
          .catchError((_) => <int, String>{}); // read again instead
      if (!mounted) return;
      // What the saved ink was read as, before the ink is looked at, so
      // only new or changed handwriting goes to the engine.
      for (final e in savedText.entries) {
        _text.restore(e.key, e.value);
      }
      _text.loadVocabularyLater(_vocabularyOf(store));
      final textSaver = TextAutosaver(
        store: store,
        documentId: widget.documentId,
        pageText: _text.pageJson,
        onError: (_) {}, // it's only read again next time
      );
      _textSaver = textSaver;
      _text.onWordsChanged = textSaver.changed;
      final saver = InkAutosaver(
        store: store,
        documentId: widget.documentId,
        pageStrokes: _ink.ink.strokesOn,
        onError: _saveFailed,
      );
      // Anything written while loading goes on top of the saved ink.
      final written = {..._ink.ink.pagesWithInk};
      final mixed = _ink.restore(saved);
      _autosaver = saver;
      _ink.onChanged = (page) {
        saver.changed(page);
        _inkChangedForText(page);
      };
      for (final page in {...written, ...mixed}) {
        saver.changed(page);
        _inkChangedForText(page);
      }
      // Saved words are checked against the ink: a page whose ink changed
      // after its words were saved (closed before a pause ended, or
      // erased) is read again; only new handwriting goes to the engine.
      for (final page in {...savedText.keys, ..._ink.ink.pagesWithInk}) {
        if (written.contains(page) || mixed.contains(page)) continue;
        _text.ensure(page, _ink.ink.strokesOn(page));
      }
    } catch (e) {
      if (mounted) _saveFailed(e);
    } finally {
      if (mounted) _inkLoaded.value = true;
    }
  }

  /// Reads the handwriting on [only] (or every page with ink) so the export
  /// can carry it as searchable text (task 1.4b), with a progress bar and
  /// the time left. Null if the user cancels.
  Future<Map<int, List<ExportWord>>?> _readForExport(
    Set<int>? only, {
    bool Function(int page, RecognizedWord word)? skip,
  }) async {
    final pages = [
      for (final p in _ink.ink.pagesWithInk.toList()..sort())
        if (only == null || only.contains(p)) p,
    ];
    final progress = ValueNotifier<(int, String)>((
      0,
      'Reading your handwriting…',
    ));
    var cancelled = false;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('Making the text searchable'),
          content: ValueListenableBuilder<(int, String)>(
            valueListenable: progress,
            builder: (_, p, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(
                  value: pages.isEmpty ? null : p.$1 / pages.length,
                ),
                const SizedBox(height: 12),
                Text(p.$2),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                cancelled = true;
                Navigator.of(context).pop();
              },
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
    final words = <int, List<ExportWord>>{};
    final watch = Stopwatch()..start();
    Object? error;
    try {
      for (var i = 0; i < pages.length && !cancelled; i++) {
        final page = pages[i];
        final left = i == 0
            ? ''
            : ', ${formatRemaining(Duration(milliseconds: watch.elapsedMilliseconds * (pages.length - i) ~/ i))}';
        progress.value = (
          i,
          'Reading page $page (${i + 1} of ${pages.length})$left…',
        );
        final read = await _text.readNow(
          page,
          _ink.ink.strokesOn(page),
          stop: () => cancelled || !mounted,
        );
        words[page] = [
          for (final w in read)
            if (w.text.trim().isNotEmpty && !(skip?.call(page, w) ?? false))
              if (w.slant?.box ?? w.box case final b)
                ExportWord(
                  w.text,
                  b.left,
                  b.bottom,
                  b.right,
                  b.top,
                  angle: w.slant?.angle ?? 0,
                  cx: w.slant?.cx ?? 0,
                  cy: w.slant?.cy ?? 0,
                ),
        ];
      }
    } catch (e) {
      error = e;
    } finally {
      // The progress dialog closes however reading ended (Cancel closes it
      // itself).
      if (!cancelled && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
    if (cancelled || !mounted) return null;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't read the handwriting: $error")),
      );
      return null;
    }
    final problem = _text.problem;
    if (problem != null && words.values.every((w) => w.isEmpty) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "Handwriting couldn't be read, so the export won't be "
            'searchable: $problem',
          ),
        ),
      );
    }
    return words;
  }

  /// Makes a new PDF with the ink drawn in (task 1.4) and saves it where
  /// the user picks, or opens the share menu with it when [share]. The
  /// original PDF is never changed.
  Future<void> _export({bool share = false}) async {
    if (widget.sourcePath == null) return;
    final messenger = ScaffoldMessenger.of(context);
    if (_ink.ink.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'There is no ink to export yet. Write on the PDF first.',
          ),
        ),
      );
      return;
    }
    await _autosaver?.flush();
    final locate = widget.locateSource;
    final source = locate == null
        ? widget.sourcePath
        : await locate().catchError((_) => widget.sourcePath);
    if (!mounted) return;
    if (source == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            "Can't find this PDF's stored copy to export. Close it and open "
            'it again from the home screen, then try again.',
          ),
        ),
      );
      return;
    }
    final converted = {
      for (final p in _ink.ink.pagesWithInk)
        p: convertedStrokeIds(_ink.ink.strokesOn(p)),
    };
    final choice = await showExportOptions(
      context,
      pageCount: _pageCount ?? _ink.ink.pagesWithInk.fold(1, math.max),
      share: share,
      startWith: _hasTyped && _showTyped.value
          ? ExportHandwriting.typed
          : ExportHandwriting.ink,
      anyConverted: _hasTyped,
      darkNow: _dark,
      convertRest: switch (SettingsScope.of(context).value.exportConvertRest) {
        ExportConvertRest.on => true,
        ExportConvertRest.off => false,
        ExportConvertRest.auto => null,
      },
      anyUnconverted: _ink.ink.pagesWithInk.any(
        (p) => _ink.ink
            .strokesOn(p)
            .any(
              (s) =>
                  isWriting(s) &&
                  !s.notWriting &&
                  !converted[p]!.contains(s.id),
            ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice.askedConvertRest) {
      // Remembered for next time (owner).
      final settings = SettingsScope.of(context);
      settings.update(
        settings.value.copyWith(
          exportConvertRest: choice.convertRest
              ? ExportConvertRest.on
              : ExportConvertRest.off,
        ),
      );
    }
    final mode = choice.handwriting;
    final text = <int, List<ExportWord>>{};
    var exportInk = _ink.ink;
    if (choice.searchable || choice.convertRest) {
      final read = await _readForExport(
        choice.pages,
        // Typed text is searchable by itself: no invisible copy.
        skip: mode == ExportHandwriting.ink
            ? null
            : (page, w) => choice.convertRest || _isConverted(page, w),
      );
      if (read == null || !mounted) return; // cancelled
      if (choice.searchable) text.addAll(read);
      // Owner's choice 1b: the rest converted too, in the export only.
      if (choice.convertRest) {
        exportInk = inkWithRestConverted(_ink.ink, [
          for (final p in _ink.ink.pagesWithInk)
            if (choice.pages == null || choice.pages!.contains(p)) p,
        ], _text.wordsOn);
      }
    }
    // Converted handwriting as visible typed text (task 2.3d).
    for (final page in exportInk.pagesWithInk) {
      if (choice.pages != null && !choice.pages!.contains(page)) continue;
      final typed = [
        ...typedForExport(exportInk.strokesOn(page), mode),
        ...textBoxesForExport(exportInk.strokesOn(page)),
      ];
      if (typed.isNotEmpty) text[page] = [...?text[page], ...typed];
    }
    if (!mounted) return;
    final pressure = SettingsScope.of(context).value.pressureResponse;
    final watch = Stopwatch()..start();
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 20),
              Expanded(child: Text('Making a copy of the PDF with your ink…')),
            ],
          ),
        ),
      ),
    );
    Object? error;
    List<int>? bytes;
    final trace = <String>[];
    final exportInkNow = inkForExport(exportInk, mode);
    // For the diagnostic log: sizes and choices only, no names or text.
    final details = <String, Object?>{
      'share': share,
      'handwriting': mode.name,
      'searchable': choice.searchable,
      'darkPages': choice.darkPages,
      'convertRest': choice.convertRest,
      'pagesInPdf': _pageCount,
      'pagesChosen': choice.pages?.length,
      'pagesWithInk': exportInkNow.pagesWithInk.length,
      'strokes': exportInkNow.pagesWithInk.fold<int>(
        0,
        (n, p) => n + exportInkNow.strokesOn(p).length,
      ),
      'words': text.values.fold<int>(0, (n, w) => n + w.length),
    };
    try {
      bytes = await widget.exportPdf(
        sourcePath: source,
        ink: exportInkNow,
        pressure: pressure,
        text: text,
        onlyPages: choice.pages,
        darkPages: choice.darkPages,
        trace: trace,
      );
    } catch (e) {
      error = e;
      if (e is PdfExportException && trace.isEmpty) trace.addAll(e.trace);
    }
    _logDiagnostic('export', {
      ...details,
      'result': bytes == null ? 'failed' : 'made',
      if (bytes == null) 'error': '$error',
      'ms': watch.elapsedMilliseconds,
      'steps': trace,
    });
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // the progress dialog
    if (bytes == null) {
      messenger.showSnackBar(
        SnackBar(content: Text("Couldn't export the PDF: $error")),
      );
      return;
    }
    final took = (watch.elapsedMilliseconds / 1000).toStringAsFixed(1);
    // So a wrong page choice shows straight away.
    final all = _pageCount;
    final n = choice.pages?.where((p) => all == null || p <= all).length ?? all;
    final pageCount = n == null ? 'all pages' : '$n page${n == 1 ? '' : 's'}';
    bool saved;
    try {
      saved = await (share ? widget.shareFile : widget.saveFile)(
        exportFileName(widget.title),
        'application/pdf',
        bytes,
      );
    } catch (e) {
      _logDiagnostic('export', {
        ...details,
        'result': share ? 'share failed' : 'saving the file failed',
        'error': '${e.runtimeType}: $e',
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            share
                ? "Couldn't share the exported PDF: $e"
                : "Couldn't save the exported PDF: $e",
          ),
        ),
      );
      return;
    }
    if (!saved || !mounted || share) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Saved ${exportFileName(widget.title)} '
          '($pageCount, ${formatBytes(bytes.length)}, made in $took s). '
          'The original PDF is unchanged.',
        ),
      ),
    );
  }

  void _saveFailed(Object error) {
    if (!mounted || _saveErrorShown) return;
    _saveErrorShown = true; // once per visit, not after every stroke
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 8),
        content: Text(
          "Your ink couldn't be saved, so it may be lost when you close "
          'this PDF. ($error)',
        ),
      ),
    );
  }

  void _showThumbForAWhile() {
    // The viewer can move during a layout pass (e.g. after rotating the
    // tablet); changing what's shown then isn't allowed, so wait a frame.
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showThumbForAWhile();
      });
      return;
    }
    _thumbActive.value = true;
    _hideTimer?.cancel();
    _hideTimer = Timer(AppSettings.scrollTabIdleAfter, () {
      if (mounted) _thumbActive.value = false;
    });
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    if (_searchOpen) {
      _text.removeListener(_refreshHandHits);
      _ink.removeListener(_refreshHandHits);
    }
    _searcherMade?.dispose();
    _searchField.dispose();
    _frames.stop();
    _textSaver?.flush(); // takes the text now, before it's thrown away
    _textSaver?.dispose();
    _text.dispose();
    _saveTimer?.cancel();
    _resumeNoteTimer?.cancel();
    _slowOpenTimer?.cancel();
    _slowOpen.dispose();
    _savePosition();
    _lifecycle.dispose();
    _autosaver?.flush();
    _autosaver?.dispose();
    _inkLoaded.dispose();
    _hideTimer?.cancel();
    _controller.removeListener(_showThumbForAWhile);
    _thumbActive.dispose();
    _pageNumber.dispose();
    _bookmarked.dispose();
    _ink.dispose();
    _tools.dispose();
    _showTyped.dispose();
    _labelsShown.dispose();
    _selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Save the page as soon as Back is pressed: the library reloads right
    // away, before this screen is disposed (and before the 1 s timer).
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) return;
        _saveTimer?.cancel();
        _savePosition();
        _flushSaves();
      },
      child: DarkPagesScope(
        colours: _ownColours,
        child: Scaffold(
          appBar: AppBar(
            title: Builder(
              builder: (context) {
                // Pages repainted when dark pages are turned on or off.
                final dark = darkPagesOf(context);
                final twoPages = SettingsScope.valueOf(context).twoPages;
                if (dark != _dark || twoPages != _twoPages) {
                  final relayout = twoPages != _twoPages;
                  _dark = dark;
                  _twoPages = twoPages;
                  WidgetsBinding.instance.addPostFrameCallback((_) async {
                    if (!mounted || !_controller.isReady) return;
                    final page = _pageNumber.value;
                    _controller.invalidate();
                    // Laid out again: back to the page that was showing.
                    if (relayout && page != null) {
                      await _controller.goToPage(
                        pageNumber: page,
                        duration: Duration.zero,
                      );
                    }
                  });
                }
                return Text(widget.title, overflow: TextOverflow.ellipsis);
              },
            ),
            bottom: _searchOpen ? _searchBar() : null,
            actions: [
              ValueListenableBuilder(
                valueListenable: _pageNumber,
                builder: (context, page, _) => ValueListenableBuilder(
                  valueListenable: _bookmarked,
                  builder: (context, bookmarks, _) {
                    // Two pages showing (owner: bookmarks work in two-page
                    // view): a choice of either.
                    final pair = page != null && _twoPages && _pageCount != null
                        ? _pairOf(page)
                        : const <int>[];
                    if (pair.length == 2) {
                      final any = pair.any(bookmarks.contains);
                      return PopupMenuButton<int>(
                        tooltip: 'Bookmark page ${pair[0]} or ${pair[1]}',
                        icon: Icon(
                          any ? Icons.bookmark : Icons.bookmark_border,
                        ),
                        onSelected: _toggleBookmark,
                        itemBuilder: (context) => [
                          for (final p in pair)
                            CheckedPopupMenuItem(
                              value: p,
                              checked: bookmarks.contains(p),
                              child: Text('Bookmark page $p'),
                            ),
                        ],
                      );
                    }
                    final marked = page != null && bookmarks.contains(page);
                    return IconButton(
                      tooltip: marked
                          ? 'Remove the bookmark on this page'
                          : 'Bookmark this page',
                      icon: Icon(
                        marked ? Icons.bookmark : Icons.bookmark_border,
                      ),
                      onPressed: page == null || _pageCount == null
                          ? null
                          : () => _toggleBookmark(page),
                    );
                  },
                ),
              ),
              Builder(
                builder: (context) {
                  final settings = context
                      .dependOnInheritedWidgetOfExactType<SettingsScope>()
                      ?.notifier;
                  if (settings == null) return const SizedBox.shrink();
                  final two = settings.value.twoPages;
                  return IconButton(
                    tooltip: two
                        ? 'Show one page at a time'
                        : 'Show two pages side by side',
                    icon: Icon(
                      two ? Icons.chrome_reader_mode : Icons.auto_stories,
                    ),
                    onPressed: () => settings.update(
                      settings.value.copyWith(twoPages: !two),
                    ),
                  );
                },
              ),
              IconButton(
                tooltip: 'Contents and bookmarks',
                icon: const Icon(Icons.toc),
                onPressed: _pageCount == null ? null : _showContents,
              ),
              IconButton(
                tooltip: 'Search the PDF and your handwriting',
                icon: const Icon(Icons.search),
                // Once the PDF is open (its text can't be searched before).
                onPressed: _pageCount == null
                    ? null
                    : (_searchOpen ? _closeSearch : _openSearch),
              ),
              ListenableBuilder(
                listenable: _ink,
                builder: (context, _) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Undo',
                      icon: const Icon(Icons.undo),
                      onPressed: _ink.canUndo ? _ink.undo : null,
                    ),
                    IconButton(
                      tooltip: 'Redo',
                      icon: const Icon(Icons.redo),
                      onPressed: _ink.canRedo ? _ink.redo : null,
                    ),
                    if (_clipboard != null)
                      IconButton(
                        tooltip: 'Paste the copied ink on this page',
                        icon: const Icon(Icons.content_paste),
                        onPressed: _paste,
                      ),
                    IconButton(
                      tooltip: "Convert this page's handwriting to typed text",
                      icon: const Icon(Icons.keyboard),
                      onPressed: _convertPage,
                    ),
                    if (_hasTyped) TypedSwitchButton(showTyped: _showTyped),
                    Builder(
                      builder: (context) {
                        final s = SettingsScope.valueOf(context);
                        final labels = s.textLabels != TextLabelPlace.off;
                        final panel = s.textPanel != TextPanelPlace.off;
                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ValueListenableBuilder(
                              valueListenable: _labelsShown,
                              builder: (context, awake, _) => IconButton(
                                tooltip: !labels
                                    ? 'Show recognised text over the ink'
                                    : awake
                                    ? 'Hide recognised text over the ink'
                                    : 'Bring back the recognised text (it '
                                          'fades while you\'re not writing)',
                                isSelected: labels,
                                icon: const Icon(Icons.text_fields),
                                onPressed: _toggleLabels,
                              ),
                            ),
                            IconButton(
                              tooltip: panel
                                  ? 'Close the text panel'
                                  : "Show this page's text in a panel",
                              isSelected: panel,
                              icon: const Icon(Icons.notes),
                              onPressed: _togglePanel,
                            ),
                          ],
                        );
                      },
                    ),
                    if (widget.sourcePath != null)
                      PopupMenuButton<bool>(
                        tooltip: 'Export a copy of this PDF with your ink',
                        icon: const Icon(Icons.ios_share),
                        onSelected: (share) => _export(share: share),
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: false,
                            child: ListTile(
                              leading: Icon(Icons.save_alt),
                              title: Text('Save a copy with my ink…'),
                            ),
                          ),
                          PopupMenuItem(
                            value: true,
                            child: ListTile(
                              leading: Icon(Icons.share),
                              title: Text('Share a copy with my ink…'),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Listens without reading the controller's value: the
              // controller only works once the PDF has loaded (some time
              // after the viewer is built), and reading it earlier throws,
              // which took the whole title bar (and its back button) down.
              ListenableBuilder(
                listenable: _controller,
                builder: (context, _) => Text(
                  _controller.isReady
                      ? '${(_controller.currentZoom * 100).round()}%'
                      : '',
                ),
              ),
              const SizedBox(width: 8),
              ValueListenableBuilder(
                valueListenable: _pageNumber,
                builder: (context, page, _) =>
                    page == null || _pageCount == null
                    ? const SizedBox.shrink()
                    : Tooltip(
                        message: 'Go to a page',
                        child: TextButton.icon(
                          icon: const Icon(Icons.find_in_page_outlined),
                          label: Text('Page $page / $_pageCount'),
                          onPressed: _askForPage,
                        ),
                      ),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: ValueListenableBuilder(
            valueListenable: _tools,
            // The toolbar only moves when its dock changes.
            child: Stack(
              key: _pageKey,
              children: [
                _viewer ??
                    _OpeningBanner(
                      title: widget.title,
                      onCancel: _cancelOpening,
                    ),
                Positioned.fill(child: FavouritesBar(controller: _tools)),
                // Shown only while saved ink is still loading.
                ValueListenableBuilder(
                  valueListenable: _inkLoaded,
                  builder: (context, loaded, _) => loaded
                      ? const SizedBox.shrink()
                      : const Positioned(
                          top: 8,
                          left: 0,
                          right: 0,
                          child: Center(child: _LoadingInkChip()),
                        ),
                ),
                // A PDF that is slow to show its first page can be abandoned.
                ValueListenableBuilder(
                  valueListenable: _slowOpen,
                  builder: (context, slow, _) => !slow || _viewer == null
                      ? const SizedBox.shrink()
                      : Positioned(
                          bottom: 16,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: _StillOpeningChip(onCancel: _cancelOpening),
                          ),
                        ),
                ),
              ],
            ),
            builder: (context, tools, pdf) {
              final bar = PenToolbar(controller: _tools);
              final place = SettingsScope.valueOf(context).textPanel;
              final page = TextPanelLayout(
                place: place,
                page: pdf!,
                panel: RecognisedTextPanel(
                  text: _text,
                  ink: _ink,
                  onUnhide: _unhide,
                  page: _pageNumber,
                  place: place,
                  onPlace: _placePanel,
                ),
              );
              return switch (tools.dock) {
                ToolbarDock.top => Column(
                  children: [
                    bar,
                    Expanded(child: page),
                  ],
                ),
                ToolbarDock.left => Row(
                  children: [
                    bar,
                    Expanded(child: page),
                  ],
                ),
                ToolbarDock.right => Row(
                  children: [
                    Expanded(child: page),
                    bar,
                  ],
                ),
              };
            },
          ),
        ),
      ),
    );
  }
}

/// Asks for a page number; returns it, or null if cancelled.
class _GoToPageDialog extends StatefulWidget {
  const _GoToPageDialog({required this.pageCount, required this.current});

  final int pageCount;
  final int current;

  @override
  State<_GoToPageDialog> createState() => _GoToPageDialogState();
}

class _GoToPageDialogState extends State<_GoToPageDialog> {
  late final _text = TextEditingController(text: '${widget.current}')
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: '${widget.current}'.length,
    );

  int? get _page => parsePageNumber(_text.text, widget.pageCount);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _go() {
    final page = _page;
    if (page != null) Navigator.pop(context, page);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Go to page'),
    content: TextField(
      controller: _text,
      autofocus: true,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: 'Page (1 to ${widget.pageCount})',
        errorText: _text.text.isEmpty || _page != null
            ? null
            : 'Enter a number from 1 to ${widget.pageCount}',
      ),
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => _go(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _page == null ? null : _go,
        child: const Text('Go'),
      ),
    ],
  );
}

/// Shown while the PDF is being opened.
class _OpeningBanner extends StatelessWidget {
  const _OpeningBanner({required this.title, required this.onCancel});

  final String title;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('Opening $title…', textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(
              'Large files can take a few seconds.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: onCancel,
              icon: const Icon(Icons.close),
              label: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadingInkChip extends StatelessWidget {
  const _LoadingInkChip();

  @override
  Widget build(BuildContext context) => const Chip(
    avatar: SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(strokeWidth: 2),
    ),
    label: Text('Loading your ink…'),
  );
}

class _StillOpeningChip extends StatelessWidget {
  const _StillOpeningChip({required this.onCancel});

  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Material(
    elevation: 3,
    borderRadius: BorderRadius.circular(24),
    color: Theme.of(context).colorScheme.surfaceContainerHigh,
    child: Padding(
      padding: const EdgeInsets.only(left: 16, right: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          const Text('Still opening…'),
          const SizedBox(width: 8),
          TextButton(onPressed: onCancel, child: const Text('Cancel')),
        ],
      ),
    ),
  );
}

/// Switches between typed text and the handwriting it came from, saying
/// in words which is showing (owner's choice G1).
class TypedSwitchButton extends StatelessWidget {
  const TypedSwitchButton({super.key, required this.showTyped});

  final ValueNotifier<bool> showTyped;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: showTyped,
    builder: (context, typed, _) => Tooltip(
      message: typed
          ? 'Tap to show your handwriting instead'
          : 'Tap to show the typed text instead',
      child: TextButton.icon(
        icon: Icon(typed ? Icons.text_snippet : Icons.gesture),
        label: Text(typed ? 'Showing typed text' : 'Showing handwriting'),
        onPressed: () => showTyped.value = !typed,
      ),
    ),
  );
}

/// The Select tool's bar: what can be done with the selected strokes
/// (owner's choices, 2026-10-14). Moving and resizing are done on the
/// selection itself: drag inside it, or drag its corner dot.
class SelectionBar extends StatelessWidget {
  const SelectionBar({
    super.key,
    required this.count,
    required this.onOneWord,
    required this.onConvert,
    required this.onColour,
    required this.onCopy,
    required this.onDelete,
    required this.onNotWriting,
    required this.onClose,
    required this.onCut,
    required this.onDuplicate,
    required this.onThickness,
    required this.onStraighten,
    required this.onCopyText,
    required this.onShare,
  });

  final int count;
  final VoidCallback onOneWord,
      onConvert,
      onColour,
      onCopy,
      onDelete,
      onNotWriting,
      onClose,
      onCut,
      onDuplicate,
      onThickness,
      onStraighten,
      onCopyText,
      onShare;

  @override
  Widget build(BuildContext context) {
    Widget action(IconData icon, String label, String tip, VoidCallback on) =>
        Tooltip(
          message: tip,
          child: TextButton.icon(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            icon: Icon(icon, size: 18),
            label: Text(label),
            onPressed: on,
          ),
        );
    // The everyday actions on the bar; the rest under "More" (owner:
    // scrolling the bar sideways wasn't obvious).
    final more = <(IconData, String, String, VoidCallback)>[
      (
        Icons.text_snippet_outlined,
        'Copy text',
        'Copy the words read here, to paste in another app',
        onCopyText,
      ),
      (Icons.palette_outlined, 'Colour', 'Change colour', onColour),
      (
        Icons.line_weight,
        'Thickness',
        'Make the lines thinner or thicker',
        onThickness,
      ),
      (
        Icons.straighten,
        'Straighten',
        'Turn slanted writing level',
        onStraighten,
      ),
      (
        Icons.control_point_duplicate,
        'Duplicate',
        'Make a copy just beside it',
        onDuplicate,
      ),
      (Icons.content_cut, 'Cut', 'Cut, to paste on any page', onCut),
      (
        Icons.share_outlined,
        'Share',
        'Share a picture of it with another app',
        onShare,
      ),
      (
        Icons.do_not_disturb_on_outlined,
        'Not writing',
        "This isn't writing: don't read it",
        onNotWriting,
      ),
    ];
    return Material(
      elevation: 3,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            action(
              Icons.join_full,
              'One word',
              'Read these strokes as one word',
              onOneWord,
            ),
            action(
              Icons.keyboard,
              'Convert',
              'Convert to typed text',
              onConvert,
            ),
            action(Icons.copy, 'Copy', 'Copy, to paste on any page', onCopy),
            action(
              Icons.delete_outline,
              'Delete',
              'Delete these strokes',
              onDelete,
            ),
            PopupMenuButton<VoidCallback>(
              tooltip: 'More actions',
              icon: const Icon(Icons.more_vert, size: 20),
              onSelected: (on) => on(),
              itemBuilder: (context) => [
                for (final (icon, label, tip, on) in more)
                  PopupMenuItem(
                    value: on,
                    child: Tooltip(
                      message: tip,
                      child: Row(
                        children: [
                          Icon(icon, size: 20),
                          const SizedBox(width: 12),
                          Text(label),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            IconButton(
              tooltip:
                  'Done (drag inside to move, the bottom-right dot to '
                  'resize, the bottom-left dot to turn)',
              icon: const Icon(Icons.close, size: 18),
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

/// Typing or editing a text box: its text and size. Closes with them, or
/// null (Cancel); an empty text with "Delete".
class TextBoxDialog extends StatefulWidget {
  const TextBoxDialog({
    super.key,
    required this.text,
    required this.size,
    required this.editing,
  });

  final String text;
  final double size;
  final bool editing;

  static const sizes = [8.0, 10.0, 12.0, 14.0, 18.0, 24.0, 32.0];

  @override
  State<TextBoxDialog> createState() => _TextBoxDialogState();
}

class _TextBoxDialogState extends State<TextBoxDialog> {
  late final _field = TextEditingController(text: widget.text);
  late double _size = widget.size;

  /// The sizes offered, with the box's own size (e.g. after resizing it).
  late final _sizes = ({...TextBoxDialog.sizes, widget.size}.toList()..sort());

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.editing ? 'Edit text box' : 'New text box'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _field,
          autofocus: true,
          minLines: 1,
          maxLines: 6,
          decoration: const InputDecoration(labelText: 'Text'),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Text('Size'),
            const SizedBox(width: 12),
            DropdownButton<double>(
              value: _size,
              onChanged: (v) => setState(() => _size = v ?? _size),
              items: [
                for (final s in _sizes)
                  DropdownMenuItem(
                    value: s,
                    child: Text(
                      '${s.toStringAsFixed(s == s.roundToDouble() ? 0 : 1)} pt',
                    ),
                  ),
              ],
            ),
          ],
        ),
      ],
    ),
    actions: [
      if (widget.editing)
        TextButton(
          onPressed: () => Navigator.of(context).pop((text: '', size: _size)),
          child: const Text('Delete'),
        ),
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () =>
            Navigator.of(context).pop((text: _field.text, size: _size)),
        child: const Text('Save'),
      ),
    ],
  );
}
