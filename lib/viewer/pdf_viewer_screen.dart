import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import '../core/app_settings.dart';
import '../core/document_state.dart';
import '../core/feedback/correction_store.dart';
import '../core/ink_export_plan.dart' show ExportWord;
import '../core/ink_classifier.dart';
import '../core/event_log.dart';
import '../core/ink_store.dart';
import '../core/open_timing.dart';
import '../core/page_coordinates.dart';
import '../core/page_ink.dart';
import '../core/page_recognition.dart' show HiddenInk, hiddenInkAt;
import '../core/typed_text.dart';
import '../core/pen_tools.dart';
import '../core/recognition/recognizer.dart';
import '../core/transfer_estimate.dart' show formatBytes, formatRemaining;
import '../export/pdf_exporter.dart';
import '../platform/file_transfer.dart';
import '../platform/share_file.dart';
import '../recognition/engines.dart';
import '../recognition/myscript_ink_classifier.dart';
import '../settings/settings_controller.dart';
import '../storage/app_database.dart';
import '../storage/sqlite_correction_store.dart';
import '../storage/sqlite_document_store.dart';
import '../storage/sqlite_event_log.dart';
import '../storage/sqlite_ink_store.dart';
import 'ink_text_controller.dart';
import 'page_ink_layer.dart';
import 'correct_word_sheet.dart';
import 'export_options_dialog.dart';
import 'page_text_labels.dart';
import 'page_typed_text.dart';
import 'pen_toolbar.dart';
import 'pen_tools_controller.dart';
import 'text_panel.dart';

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

  /// Whether [w]'s ink is converted and the typed text is showing, so its
  /// label is left out.
  bool _shownTyped(int page, RecognizedWord w) =>
      _showTyped.value && _isConverted(page, w);

  /// Whether (most of) [w]'s strokes were converted to typed text.
  bool _isConverted(int page, RecognizedWord w) =>
      mostlyConverted(w.key, convertedStrokeIds(_ink.ink.strokesOn(page)));

  bool get _hasTyped => _ink.ink.pagesWithInk.any(
    (p) => _ink.ink.strokesOn(p).any((s) => s.typedText?.isNotEmpty ?? false),
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
    final w = typedWordAt(_ink.ink.strokesOn(page), at, geometry, viewWidth);
    return w == null ? null : () => _editTyped(page, w);
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

  /// Converts [words] on [page] to typed text and shows it (task 2.3c).
  void _convertWords(int page, List<RecognizedWord> words) {
    final messenger = ScaffoldMessenger.of(context);
    final map = <Set<String>, String>{
      for (final w in words)
        if (w.key.isNotEmpty && w.text.trim().isNotEmpty)
          w.key.split(',').toSet(): w.text,
    };
    if (map.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No handwriting was read there.')),
      );
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
          'Converted ${map.length} word${map.length == 1 ? '' : 's'} to '
          'typed text. Undo takes it back; tap a word to edit it.',
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
  Future<void> _lassoDrawn(int page, List<PageInkPoint> loop) async {
    final picked = strokesInLoop(_ink.ink.strokesOn(page), loop);
    final messenger = ScaffoldMessenger.of(context);
    if (picked.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Nothing inside the loop. Draw it all the way around the '
            'handwriting.',
          ),
        ),
      );
      return;
    }
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Convert to typed text?'),
        content: const Text(
          'The handwriting inside the loop is shown as typed text. Your ink '
          'is kept: switch back any time with the handwriting button.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Convert'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    final words = await _readPage(page);
    if (words == null || !mounted) return;
    // Words mostly inside the loop.
    _convertWords(page, [
      for (final w in words)
        if (w.key.isNotEmpty &&
            w.key.split(',').where(picked.contains).length * 2 >=
                w.key.split(',').length)
          w,
    ]);
  }

  /// Tap on typed text: edit it (owner's choice 4a). The edit also teaches
  /// the learning layer, like a correction.
  Future<void> _editTyped(int page, TypedWord typed) async {
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
    _ink.setTypedText(page, typed.group, t);
    // The same word as read (mostly the same strokes): teach the learning
    // layer, like a correction.
    for (final w in _text.wordsOn(page)) {
      if (mostlyConverted(w.key, typed.strokeIds)) {
        await _text.correct(page, w, t);
        break;
      }
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

  void _inkChangedForText(int page) => _text.inkChanged(
    page,
    _ink.ink.strokesOn(page),
    Duration(milliseconds: SettingsScope.of(context).value.recognitionPauseMs),
  );
  InkAutosaver? _autosaver;
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
    Positioned.fill(
      // Finger tap on typed text: edit it (task 2.3c). Fingers otherwise
      // pass through to scroll and zoom.
      child: GestureDetector(
        supportedDevices: const {PointerDeviceKind.touch},
        behavior: HitTestBehavior.translucent,
        onTapUp: (d) => _typedTapAt(
          page.pageNumber,
          d.localPosition,
          _geometryOf(page),
          pageRect.width,
        )?.call(),
        child: PageInkLayer(
          pageNumber: page.pageNumber,
          geometry: _geometryOf(page),
          viewWidth: pageRect.width,
          controller: _ink,
          tools: _tools,
          showTyped: _showTyped,
          onLasso: (loop) => _lassoDrawn(page.pageNumber, loop),
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
  ];

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
      onHide: () => _autosaver?.flush(),
      onPause: () => _autosaver?.flush(),
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

  Future<void> _loadInk() async {
    try {
      final store = await widget.openInkStore();
      final saved = await store.load(widget.documentId);
      if (!mounted) return;
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
    } catch (e) {
      if (mounted) _saveFailed(e);
    } finally {
      if (mounted) _inkLoaded.value = true;
    }
  }

  /// Reads the handwriting on [only] (or every page with ink) so the export
  /// can carry it as searchable text (task 1.4b), with a progress bar and
  /// the time left. Null if the user cancels.
  Future<Map<int, List<ExportWord>>?> _readForExport(Set<int>? only) async {
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
            if (w.text.trim().isNotEmpty)
              ExportWord(
                w.text,
                w.box.left,
                w.box.bottom,
                w.box.right,
                w.box.top,
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
    final choice = await showExportOptions(
      context,
      pageCount: _pageCount ?? _ink.ink.pagesWithInk.fold(1, math.max),
      share: share,
    );
    if (choice == null || !mounted) return;
    var text = const <int, List<ExportWord>>{};
    if (choice.searchable) {
      final read = await _readForExport(choice.pages);
      if (read == null || !mounted) return; // cancelled
      text = read;
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
    try {
      bytes = await widget.exportPdf(
        sourcePath: source,
        ink: _ink.ink,
        pressure: pressure,
        text: text,
        onlyPages: choice.pages,
      );
    } catch (e) {
      error = e;
    }
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // the progress dialog
    if (bytes == null) {
      messenger.showSnackBar(
        SnackBar(content: Text("Couldn't export the PDF: $error")),
      );
      return;
    }
    final took = (watch.elapsedMilliseconds / 1000).toStringAsFixed(1);
    bool saved;
    try {
      saved = await (share ? widget.shareFile : widget.saveFile)(
        exportFileName(widget.title),
        'application/pdf',
        bytes,
      );
    } catch (e) {
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
          '(${formatBytes(bytes.length)}, made in $took s). '
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
    _ink.dispose();
    _tools.dispose();
    _showTyped.dispose();
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
        _autosaver?.flush();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title, overflow: TextOverflow.ellipsis),
          actions: [
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
                  IconButton(
                    tooltip: "Convert this page's handwriting to typed text",
                    icon: const Icon(Icons.keyboard),
                    onPressed: _convertPage,
                  ),
                  if (_hasTyped)
                    ValueListenableBuilder(
                      valueListenable: _showTyped,
                      builder: (context, typed, _) => IconButton(
                        tooltip: typed
                            ? 'Showing typed text. Tap to show your handwriting'
                            : 'Showing your handwriting. Tap to show typed '
                                  'text',
                        isSelected: typed,
                        icon: Icon(typed ? Icons.text_snippet : Icons.gesture),
                        onPressed: () => _showTyped.value = !typed,
                      ),
                    ),
                  Builder(
                    builder: (context) {
                      final s = SettingsScope.valueOf(context);
                      final labels = s.textLabels != TextLabelPlace.off;
                      final panel = s.textPanel != TextPanelPlace.off;
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: labels
                                ? 'Hide recognised text over the ink'
                                : 'Show recognised text over the ink',
                            isSelected: labels,
                            icon: const Icon(Icons.text_fields),
                            onPressed: _toggleLabels,
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
              builder: (context, page, _) => page == null || _pageCount == null
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
                  _OpeningBanner(title: widget.title, onCancel: _cancelOpening),
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
