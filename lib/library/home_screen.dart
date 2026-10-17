import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_settings.dart' show PageColours;
import '../core/document_colours.dart';
import '../core/document_state.dart';
import '../core/page_layout.dart';
import '../core/page_templates.dart';
import '../core/paper.dart' show NotebookSize, ruledGap;
import '../core/page_ink.dart';
import '../core/recent_pdfs.dart';
import '../core/stored_copy.dart';
import '../core/tags.dart';
import '../storage/sqlite_tag_store.dart';
import '../platform/backup_channel.dart';
import 'library_search_screen.dart';
import 'library_search_service.dart';
import 'tags_sheet.dart';
import '../handwriting/handwriting_test_screen.dart';
import '../import/import_progress_screen.dart';
import '../import/pdf_import_channel.dart';
import '../platform/diagnostics.dart';
import '../settings/settings_controller.dart';
import '../settings/backup_screen.dart';
import '../settings/settings_screen.dart';
import '../storage/sqlite_document_colours_store.dart';
import '../storage/sqlite_document_store.dart';
import '../storage/sqlite_ink_store.dart';
import '../storage/sqlite_page_layout_store.dart';
import '../viewer/page_colours_dialog.dart';
import '../viewer/paper_painter.dart' show PaperChoice, PaperChooser;
import '../viewer/pdf_viewer_screen.dart';
import 'locate_copy.dart';
import 'notebooks.dart';
import 'recent_store.dart';
import 'thumbnails.dart';

/// When CI built this APK, in the owner's local time (set by the CI workflow).
const buildStamp = String.fromEnvironment(
  'BUILD_STAMP',
  defaultValue: 'local build',
);

/// Everything the home page talks to, so tests can swap in fakes.
class LibraryServices {
  const LibraryServices({
    this.pick = PdfImportChannel.pick,
    this.inspect = PdfImportChannel.inspect,
    this.listCopies = PdfImportChannel.listCopies,
    this.setPinned = PdfImportChannel.setPinned,
    this.releaseAccess = PdfImportChannel.releaseAccess,
    this.recents = const RecentStore(),
    this.thumbnails = const Thumbnails(),
    this.readingPositions = _loadPositions,
    this.inkDocuments = _loadInkDocuments,
    this.lastCrash = lastCrashReport,
    this.clearLastCrash = clearLastCrashReport,
    this.fileExists = _fileExists,
    this.firstPageInk = _loadFirstPageInk,
    this.documentColours = SqliteDocumentColoursStore.open,
    this.pageLayouts = SqlitePageLayoutStore.open,
    this.newNotebookFile = createNotebookFile,
    this.restoreNotebooks = restoreNotebookFiles,
    this.tags = SqliteTagStore.open,
    this.handwritingOf = _loadHandwriting,
    this.librarySearch = LibrarySearchService.open,
    this.restoreProblem = _restoreProblem,
    this.backupReminder = BackupReminder.load,
    this.snoozeBackupReminder = BackupReminder.snooze,
  });

  /// Whether to remind about backups now (owner: a reminder after 7 days).
  final Future<bool> Function() backupReminder;
  final Future<void> Function() snoozeBackupReminder;

  /// Why the last restore couldn't be put in place, or null.
  final Future<String?> Function() restoreProblem;

  static Future<String?> _restoreProblem() =>
      const AndroidBackupService().restoreProblem();

  /// What the search of every document looks through.
  final Future<LibrarySearchService> Function() librarySearch;

  /// Tags, and which documents have them (owner: several per document,
  /// colour-coded).
  final Future<TagStore> Function() tags;

  /// What's written in a document, as words (to suggest tags from).
  final Future<String> Function(String id) handwritingOf;

  static Future<String> _loadHandwriting(String id) async => handwritingText(
    (await (await SqliteInkStore.open()).loadText(id)).values,
  );

  /// Each document's pages (blank pages, notebooks).
  final Future<PageLayoutStore> Function() pageLayouts;

  /// Makes a new notebook's file (owner: notebooks without a PDF).
  final Future<({String id, String path})> Function(String name)
  newNotebookFile;

  /// Puts back notebook files the system cleared away.
  final Future<void> Function(Iterable<String> ids) restoreNotebooks;

  /// Each PDF's own page colours (owner: dark pages are chosen per PDF).
  final Future<DocumentColoursStore> Function() documentColours;

  final Future<PickedPdf?> Function() pick;
  final Future<PickedPdf?> Function(String uri) inspect;
  final Future<List<StoredCopy>> Function() listCopies;
  final Future<void> Function(StoredCopy copy, bool pinned, int keep) setPinned;
  final Future<void> Function(String uri) releaseAccess;
  final RecentStore recents;
  final Thumbnails thumbnails;

  /// Where each PDF was left (page and page count), by library id.
  final Future<Map<String, DocumentState>> Function() readingPositions;

  static Future<Map<String, DocumentState>> _loadPositions() async =>
      (await SqliteDocumentStore.open()).all();

  /// Library ids of PDFs with saved ink (task 1.3).
  final Future<Set<String>> Function() inkDocuments;

  static Future<Set<String>> _loadInkDocuments() async =>
      (await SqliteInkStore.open()).documentsWithInk();

  /// Details of a crash since the last launch, if any (see App.kt).
  final Future<String?> Function() lastCrash;
  final Future<void> Function() clearLastCrash;

  /// Whether a file is (still) at this path.
  final Future<bool> Function(String path) fileExists;

  static Future<bool> _fileExists(String path) => File(path).exists();

  /// The ink saved on page 1 of a PDF (for its home-page picture).
  final Future<List<PageStroke>> Function(String id) firstPageInk;

  static Future<List<PageStroke>> _loadFirstPageInk(String id) async {
    var key = 1;
    try {
      final layout = PageLayout.fromJson(
        await (await SqlitePageLayoutStore.open()).load(id),
      );
      // The picture is of the PDF's page 1; a notebook's is of its first
      // blank page.
      if (layout != null && layout.notebook) key = layout.keyAt(1);
    } catch (_) {}
    return (await (await SqliteInkStore.open()).load(id)).strokesOn(key);
  }
}

/// One PDF card on the home page.
class _Item {
  const _Item({
    required this.name,
    required this.cacheId,
    this.recent,
    this.copy,
  });

  final String name;
  final String cacheId;

  /// Set if the PDF is in the Recent list (so it can be re-imported).
  final RecentPdf? recent;

  /// Set if a stored copy exists (so it opens instantly).
  final StoredCopy? copy;

  bool get cached => copy != null;
  bool get pinned => copy?.pinned ?? false;
}

/// Home page: open buttons, then Pinned and Recent PDFs.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.services = const LibraryServices()});

  final LibraryServices services;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// Library ids of notebooks (no Unpin: they're always kept).
  Set<String> _notebooks = {};

  /// Names the user gave notebooks (owner: notebooks can be renamed).
  Map<String, String> _titles = {};

  /// Every tag, each document's tags, and the tag the list is narrowed to.
  List<Tag> _tagList = const [];
  Map<String, Set<String>> _docTags = const {};
  String? _filter;
  TagStore? _tagStore;

  LibraryServices get _s => widget.services;

  List<RecentPdf> _recents = [];

  /// The library has been read at least once.
  bool _loadedOnce = false;

  /// No backup for a week (and there's writing to lose).
  bool _remindBackup = false;
  List<StoredCopy> _copies = [];
  Map<String, DocumentState> _positions = {};

  /// Library ids of PDFs with saved ink; these stay pinned.
  Set<String> _withInk = {};

  @override
  void initState() {
    super.initState();
    _reload();
    _reportLastCrash();
    _reportRestoreProblem();
  }

  /// A restore that couldn't be put in place (nothing changed): says so.
  Future<void> _reportRestoreProblem() async {
    final problem = await _s.restoreProblem().catchError((_) => null);
    if (problem == null || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('The backup wasn\'t restored'),
        content: Text(
          '$problem\n\nEverything is as it was before. You can try '
          'restoring again in Settings → Backups.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// If the app crashed last time, offers the details so the owner can
  /// paste them to Claude (the tablet's own logs aren't reachable).
  Future<void> _reportLastCrash() async {
    final report = await _s.lastCrash().catchError((_) => null);
    if (report == null || report.isEmpty || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('The app closed unexpectedly last time'),
        content: SingleChildScrollView(
          child: Text(
            'Please copy these details and paste them to Claude so the '
            'problem can be fixed.\n\n$report',
            style: const TextStyle(fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Dismiss'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.copy),
            label: const Text('Copy details'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: report));
              Navigator.pop(context);
            },
          ),
        ],
      ),
    );
    await _s.clearLastCrash().catchError((_) {});
  }

  Future<void> _reload() async {
    // Notebooks' files are only an empty page each: put back any the
    // system cleared, so every notebook shows (its writing is kept apart).
    try {
      final layouts = await _s.pageLayouts();
      final notebooks = await layouts.notebooks();
      _notebooks = notebooks.toSet();
      _titles = {
        for (final id in notebooks)
          id: ?PageLayout.fromJson(await layouts.load(id))?.title,
      };
      await _s.restoreNotebooks(notebooks);
    } catch (_) {}
    // Either can fail (e.g. in tests, or if storage is unreadable); the
    // page then just shows fewer items.
    final recents = await _s.recents.load().catchError((_) => <RecentPdf>[]);
    final copies = await _s.listCopies().catchError((_) => <StoredCopy>[]);
    var copies2 = copies;
    final positions = await _s.readingPositions().catchError(
      (_) => <String, DocumentState>{},
    );
    final withInk = await _s.inkDocuments().catchError((_) => <String>{});
    var tagList = _tagList;
    var docTags = _docTags;
    try {
      final store = _tagStore ??= await _s.tags();
      tagList = await store.tags();
      docTags = await store.documentTags();
    } catch (_) {
      // Tags just aren't shown this time.
    }
    // PDFs you've written on are kept permanently (plan, task 1.3), so the
    // storage limit never removes them.
    final toKeep = [
      for (final c in copies)
        if (!c.pinned && withInk.contains(c.id)) c,
    ];
    if (toKeep.isNotEmpty && mounted) {
      final keep = SettingsScope.of(context).value.cachedPdfLimit;
      for (final c in toKeep) {
        await _s.setPinned(c, true, keep).catchError((_) {});
      }
      copies2 = await _s.listCopies().catchError((_) => copies);
    }
    if (!mounted) return;
    // Checked after, so it never holds up the list.
    if (withInk.isEmpty) {
      _remindBackup = false;
    } else {
      unawaited(
        _s.backupReminder().catchError((_) => false).then((remind) {
          if (mounted && remind != _remindBackup) {
            setState(() => _remindBackup = remind);
          }
        }),
      );
    }
    setState(() {
      _loadedOnce = true;
      _recents = recents;
      _copies = copies2;
      _positions = positions;
      _withInk = withInk;
      _tagList = tagList;
      _docTags = docTags;
      if (_filter != null && !tagList.any((t) => t.name == _filter)) {
        _filter = null;
      }
    });
  }

  ({List<_Item> pinned, List<_Item> recent}) get _items {
    final all = _itemsUnfiltered;
    // Narrowed to one tag (owner: the home screen filters by tag).
    final f = _filter;
    if (f == null) return all;
    bool has(_Item i) => _docTags[i.cacheId]?.contains(f) ?? false;
    return (
      pinned: all.pinned.where(has).toList(),
      recent: all.recent.where(has).toList(),
    );
  }

  ({List<_Item> pinned, List<_Item> recent}) get _itemsUnfiltered {
    final copiesById = {for (final c in _copies) c.id: c};
    final recentById = {for (final r in _recents) r.cacheId: r};
    final pinned = [
      for (final c in sortForDisplay(_copies.where((c) => c.pinned)))
        _Item(
          name: _titles[c.id] ?? recentById[c.id]?.name ?? c.displayName,
          cacheId: c.id,
          recent: recentById[c.id],
          copy: c,
        ),
    ];
    final recent = [
      for (final r in _recents)
        if (!(copiesById[r.cacheId]?.pinned ?? false))
          _Item(
            name: r.name,
            cacheId: r.cacheId,
            recent: r,
            copy: copiesById[r.cacheId],
          ),
    ];
    return (pinned: pinned, recent: recent);
  }

  /// Chooses [item]'s tags (owner: suggested from its name, and from what's
  /// written in it when that's allowed in Settings).
  Future<void> _editTags(_Item item) async {
    TagStore store;
    try {
      store = _tagStore ??= await _s.tags();
    } catch (e) {
      _message("Couldn't open the tags: $e");
      return;
    }
    if (!mounted) return;
    final fromContents = SettingsScope.of(context)
        .value
        .suggestTagsFromContents;
    final current = _docTags[item.cacheId] ?? const <String>{};
    List<String> suggest(String contents) => suggestTags(
      name: item.name,
      contents: contents,
      known: [for (final t in _tagList) t.name],
      current: current,
    );
    // Reading what's written can take a moment: the sheet opens straight
    // away and those suggestions follow.
    final result = await showModalBottomSheet<TagsChoice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => TagsSheet(
        documentName: item.name,
        known: _tagList,
        current: current,
        suggestions: suggest(''),
        moreSuggestions: fromContents
            ? _s.handwritingOf(item.cacheId).catchError((_) => '').then(suggest)
            : null,
      ),
    );
    if (result == null) return;
    try {
      await store.setDocumentTags(
        item.cacheId,
        result.names,
        newTags: result.newTags,
      );
    } catch (e) {
      _message("Couldn't save the tags: $e");
    }
    await _reload();
  }

  /// A tag's colour, or the tag deleted (long-press on it in the row).
  Future<void> _editTag(Tag tag) async {
    final store = _tagStore;
    if (store == null) return;
    final result = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      builder: (_) => TagColourSheet(
        tag: tag,
        usedBy: _docTags.values.where((t) => t.contains(tag.name)).length,
      ),
    );
    try {
      if (result is int) await store.saveTag(Tag(tag.name, result));
      if (result == TagColourSheet.delete) await store.deleteTag(tag.name);
    } catch (e) {
      _message("Couldn't change the tag: $e");
    }
    await _reload();
  }

  // ---- Searching everything ----------------------------------------------

  /// Searches every document (owner, 2026-10-16), whatever the tag filter.
  Future<void> _searchAll() async {
    // Every stored copy and every recent PDF (also unpinned copies no
    // longer in Recent).
    final all = _itemsUnfiltered;
    final items = [...all.pinned, ...all.recent];
    final listed = {for (final i in items) i.cacheId};
    final recentById = {for (final r in _recents) r.cacheId: r};
    for (final c in _copies) {
      if (listed.add(c.id)) {
        items.add(
          _Item(
            name: _titles[c.id] ?? recentById[c.id]?.name ?? c.displayName,
            cacheId: c.id,
            recent: recentById[c.id],
            copy: c,
          ),
        );
      }
    }
    final byId = {for (final i in items) i.cacheId: i};
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LibrarySearchScreen(
          service: _s.librarySearch,
          // Until the library has loaded, what isn't listed isn't gone.
          complete: _loadedOnce,
          entries: [
            for (final i in items)
              SearchEntry(
                id: i.cacheId,
                name: i.name,
                tags: (_docTags[i.cacheId] ?? const <String>{}).toList(),
                path: (i.copy?.path.isNotEmpty ?? false) ? i.copy!.path : null,
                size: i.copy?.size ?? 0,
                notebook: _notebooks.contains(i.cacheId),
              ),
          ],
          onOpen: (id, page, query) async {
            final item = byId[id];
            if (item == null) return;
            await _openItem(item, page: page, search: query);
          },
        ),
      ),
    );
    await _reload();
  }

  // ---- Opening -----------------------------------------------------------

  Route<void> _viewerRoute(
    String name,
    String id,
    String path,
    Duration? importTook,
    DateTime tappedAt, {
    int? page,
    String? search,
  }) => MaterialPageRoute<void>(
    builder: (_) => PdfViewerScreen(
      title: name,
      documentId: id,
      importTook: importTook,
      tappedAt: tappedAt,
      openAtPage: page,
      openWithSearch: search,
      sourcePath: path,
      locateSource: () => locateStoredCopy(
        id: id,
        path: path,
        fileExists: _s.fileExists,
        listCopies: _s.listCopies,
      ),
      viewerBuilder: (controller, params, page) => PdfViewer.file(
        path,
        controller: controller,
        params: params,
        initialPageNumber: page,
      ),
    ),
  );

  /// Adds the PDF to Recent and saves its first-page picture.
  Future<void> _remember(PickedPdf pdf, String path) async {
    final updated = recordOpened(
      _recents,
      RecentPdf(
        uri: pdf.uri,
        name: pdf.name,
        cacheId: pdf.cacheId,
        lastOpened: DateTime.now(),
      ),
    );
    _saveRecents(updated);
    unawaited(_s.thumbnails.ensure(pdf.cacheId, path));
  }

  /// Opens [pdf]: straight away if a copy is stored, otherwise imports it.
  Future<void> _openPicked(
    PickedPdf pdf, {
    DateTime? tappedAt,
    int? page,
    String? search,
  }) async {
    final tapped = tappedAt ?? DateTime.now();
    final cached = pdf.cachedPath;
    if (cached != null) {
      await _remember(pdf, cached);
      if (!mounted) return;
      await Navigator.of(context).push(
        _viewerRoute(
          pdf.name,
          pdf.cacheId,
          cached,
          null,
          tapped,
          page: page,
          search: search,
        ),
      );
    } else {
      // The import screen hands over to the viewer, which ends this push
      // straight away; wait for the viewer itself to close before reloading,
      // or the reload could move the file the viewer is using.
      Future<void>? viewerClosed;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ImportProgressScreen(
            pdf: pdf,
            keep: SettingsScope.of(context).value.cachedPdfLimit,
            onDone: (context, path, took) {
              _remember(pdf, path);
              final route = _viewerRoute(
                pdf.name,
                pdf.cacheId,
                path,
                took,
                tapped,
                page: page,
                search: search,
              );
              viewerClosed = route.popped;
              Navigator.of(context).pushReplacement(route);
            },
          ),
        ),
      );
      if (viewerClosed != null) await viewerClosed;
    }
    await _reload();
    await _refreshThumbnail(pdf.cacheId);
  }

  /// Redraws a PDF's home-page picture with the ink on its first page, so
  /// writing on page 1 shows on the home page after closing the PDF.
  Future<void> _refreshThumbnail(String id) async {
    try {
      final ink = await _s.firstPageInk(id);
      if (ink.isEmpty) return;
      final copy = _copies.where((c) => c.id == id).firstOrNull;
      if (copy == null || copy.path.isEmpty) return;
      await _s.thumbnails.ensure(id, copy.path, ink: ink);
      if (mounted) setState(() {});
    } catch (_) {
      // Keep the old picture.
    }
  }

  Future<void> _openFromDevice() async {
    final PickedPdf? pdf;
    try {
      pdf = await _s.pick();
    } catch (e) {
      _message("Couldn't open the file: $e");
      return;
    }
    if (pdf == null || !mounted) return;
    await _openPicked(pdf);
  }

  /// A notebook without a PDF (owner's choice): asks for its paper, then
  /// opens it on its first blank page.
  Future<void> _newNotebook() async {
    SharedPreferencesAsync? prefs;
    try {
      prefs = SharedPreferencesAsync();
    } catch (_) {} // remembered choices just aren't used
    var last = Paper.plain;
    try {
      final name = await prefs?.getString('paper.last');
      last = Paper.values.firstWhere(
        (p) => p.name == name,
        orElse: () => Paper.plain,
      );
    } catch (_) {}
    // The user's own templates (owner's idea 20).
    final templates = TemplateLibrary();
    try {
      final raw = await prefs?.getString(TemplateLibrary.prefsKey);
      if (raw != null) templates.load(jsonDecode(raw));
    } catch (_) {}
    if (!mounted) return;
    var size = NotebookSize.a4;
    final chosen = await showModalBottomSheet<PaperChoice>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => PaperChooser(
        title: 'New notebook',
        start: last,
        doneLabel: 'Create',
        onSize: (s) => size = s,
        templates: templates.templates,
        onRemoveTemplate: (t) async {
          templates.remove(t.name);
          try {
            await prefs?.setString(
              TemplateLibrary.prefsKey,
              jsonEncode(templates.toJson()),
            );
          } catch (_) {}
        },
      ),
    );
    if (chosen == null || !mounted) return;
    final tapped = DateTime.now();
    final template = chosen.template;
    double? gap = template?.lineGap;
    if (template == null && chosen.paper == Paper.linedToFit) {
      try {
        gap = await prefs?.getDouble('paper.fitGap');
      } catch (_) {}
      gap ??= ruledGap;
    }
    if (template == null) {
      try {
        await prefs?.setString('paper.last', chosen.paper.name);
      } catch (_) {}
    }
    final name = 'Notebook ${formatDateTime(tapped).replaceAll(':', '.')}';
    final ({String id, String path}) file;
    try {
      file = await _s.newNotebookFile(name);
      final layout = PageLayout.newNotebook(
        paper: chosen.paper,
        lineGap: gap,
        width: size.width,
        height: size.height,
      );
      // A template's ink on the first page.
      if (template != null && template.strokes.isNotEmpty) {
        await (await SqliteInkStore.open()).savePage(
          file.id,
          layout.keyAt(1),
          template.strokesFor(
            size.width.toDouble(),
            size.height.toDouble(),
            now: tapped.millisecondsSinceEpoch,
          ),
        );
      }
      await (await _s.pageLayouts()).save(file.id, layout);
    } catch (e) {
      _message("Couldn't make the notebook: $e");
      return;
    }
    await _reload();
    if (!mounted) return;
    await Navigator.of(context)
        .push(_viewerRoute('$name.pdf', file.id, file.path, null, tapped));
    await _reload();
    await _refreshThumbnail(file.id);
  }

  /// Gives a notebook another name (kept with its pages; its file keeps
  /// its own name, so nothing written in it moves).
  Future<void> _rename(_Item item) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) =>
          _RenameDialog(start: item.name.replaceAll(RegExp(r'\.pdf$'), '')),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    try {
      final store = await _s.pageLayouts();
      final layout = PageLayout.fromJson(await store.load(item.cacheId));
      if (layout == null) return;
      await store.save(item.cacheId, layout.named(name));
    } catch (e) {
      _message("Couldn't rename it: $e");
      return;
    }
    await _reload();
  }

  Future<void> _openItem(_Item item, {int? page, String? search}) async {
    final tapped = DateTime.now();
    final recent = item.recent;
    if (recent != null) {
      // Looking it up also marks its stored copy as just used.
      final pdf = await _s.inspect(recent.uri);
      if (!mounted) return;
      if (pdf != null) {
        return _openPicked(pdf, tappedAt: tapped, page: page, search: search);
      }
    }
    final copy = item.copy;
    if (copy != null && copy.path.isNotEmpty) {
      await Navigator.of(context).push(
        _viewerRoute(
          item.name,
          item.cacheId,
          copy.path,
          null,
          tapped,
          page: page,
          search: search,
        ),
      );
      await _reload();
      await _refreshThumbnail(item.cacheId);
      return;
    }
    _message(
      "Can't find ${item.name} any more. It may have been moved or "
      'deleted. Open it again with "Open a PDF from this tablet".',
      action: recent == null
          ? null
          : SnackBarAction(
              label: 'Remove',
              onPressed: () => _removeRecent(recent),
            ),
    );
  }

  /// Saves the Recent list and gives back file access for any PDF that
  /// dropped off it.
  Future<void> _saveRecents(List<RecentPdf> updated) async {
    final kept = {for (final r in updated) r.uri};
    final dropped = {
      for (final r in _recents)
        if (!kept.contains(r.uri)) r.uri,
    };
    _recents = updated;
    await _s.recents.save(updated).catchError((_) {});
    for (final uri in dropped) {
      unawaited(_s.releaseAccess(uri).catchError((_) {}));
    }
  }

  // ---- Card actions ------------------------------------------------------

  Future<void> _removeRecent(RecentPdf recent) async {
    await _saveRecents(removeRecent(_recents, recent));
    await _reload();
  }

  Future<void> _setPinned(_Item item, bool pinned) async {
    final copy = item.copy;
    if (copy == null) return;
    final keep = SettingsScope.of(context).value.cachedPdfLimit;
    await _s.setPinned(copy, pinned, keep);
    await _reload();
  }

  Future<void> _showActions(_Item item) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(item.name, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                item.cached
                    ? 'Stored in the app: opens instantly'
                    : 'Not stored: will be imported again when opened',
              ),
            ),
            if (item.cached && _withInk.contains(item.cacheId))
              const ListTile(
                leading: Icon(Icons.push_pin),
                title: Text('Kept because it has your ink'),
                subtitle: Text(
                  "PDFs you've written on are never removed by the storage "
                  'limit',
                ),
              )
            else if (item.cached && !_notebooks.contains(item.cacheId))
              ListTile(
                leading: Icon(
                  item.pinned ? Icons.push_pin_outlined : Icons.push_pin,
                ),
                title: Text(item.pinned ? 'Unpin' : 'Pin'),
                subtitle: Text(
                  item.pinned
                      ? 'May be removed when you go over your storage limit'
                      : 'Always keep its stored copy',
                ),
                onTap: () {
                  Navigator.pop(context);
                  _setPinned(item, !item.pinned);
                },
              ),
            if (_notebooks.contains(item.cacheId))
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline),
                title: const Text('Rename'),
                onTap: () {
                  Navigator.pop(context);
                  _rename(item);
                },
              ),
            ListTile(
              leading: const Icon(Icons.sell_outlined),
              title: const Text('Tags'),
              subtitle: _docTags[item.cacheId]?.isNotEmpty ?? false
                  ? Text((_docTags[item.cacheId]!.toList()..sort()).join(', '))
                  : null,
              onTap: () {
                Navigator.pop(context);
                _editTags(item);
              },
            ),
            ListTile(
              leading: const Icon(Icons.contrast),
              title: const Text('Page colours'),
              subtitle: const Text('Light or dark pages for this PDF'),
              onTap: () {
                Navigator.pop(context);
                _choosePageColours(item);
              },
            ),
            if (item.recent != null)
              ListTile(
                leading: const Icon(Icons.history_toggle_off),
                title: const Text('Remove from Recent'),
                subtitle: const Text('Your original file is not touched'),
                onTap: () {
                  Navigator.pop(context);
                  _removeRecent(item.recent!);
                },
              ),
          ],
        ),
      ),
    );
  }

  /// Light or dark pages for one PDF (owner: dark pages are chosen when a
  /// PDF comes in, at export and in Settings; not in the toolbar).
  Future<void> _choosePageColours(_Item item) async {
    final byDefault = SettingsScope.of(context).value.pageColours;
    DocumentColoursStore store;
    PageColours? current;
    try {
      store = await _s.documentColours();
      current = await store.get(item.cacheId);
    } catch (e) {
      _message("Couldn't open this PDF's page colours: $e");
      return;
    }
    if (!mounted) return;
    final pick = await askPageColours(
      context,
      byDefault: byDefault,
      current: current,
    );
    if (pick == null) return;
    try {
      await store.set(item.cacheId, pick.colours);
    } catch (e) {
      _message("Couldn't save the page colours: $e");
    }
  }

  void _message(String text, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), action: action));
  }

  // ---- Layout ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _items;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Writing Recogniser'),
        actions: [
          IconButton(
            tooltip: 'Search all documents',
            icon: const Icon(Icons.search),
            onPressed: _searchAll,
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
              );
              await _reload();
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        FilledButton.icon(
                          icon: const Icon(Icons.folder_open),
                          label: const Text('Open a PDF from this tablet'),
                          onPressed: _openFromDevice,
                        ),
                        const SizedBox(height: 12),
                        FilledButton.tonalIcon(
                          icon: const Icon(Icons.edit_note),
                          label: const Text('New notebook'),
                          onPressed: _newNotebook,
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.draw_outlined),
                          label: const Text('Handwriting test'),
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const HandwritingTestScreen(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (_remindBackup)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Card(
                    child: ListTile(
                      leading: const Icon(Icons.backup_outlined),
                      title: const Text('No backup for over a week'),
                      subtitle: const Text(
                        'A backup keeps your PDFs and writing safe if the '
                        'tablet is lost or breaks.',
                      ),
                      trailing: Wrap(
                        spacing: 4,
                        children: [
                          TextButton(
                            onPressed: () async {
                              setState(() => _remindBackup = false);
                              await _s.snoozeBackupReminder().catchError(
                                (_) {},
                              );
                            },
                            child: const Text('Not now'),
                          ),
                          FilledButton(
                            onPressed: () async {
                              await Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => const BackupScreen(),
                                ),
                              );
                              await _reload();
                            },
                            child: const Text('Back up'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (_tagList.isNotEmpty)
              SliverToBoxAdapter(
                child: TagFilterRow(
                  tags: _tagList,
                  selected: _filter,
                  onSelected: (name) => setState(() => _filter = name),
                  onEdit: _editTag,
                ),
              ),
            if (items.pinned.isNotEmpty) ...[
              const _SectionHeader('Pinned'),
              _grid(items.pinned),
            ],
            const _SectionHeader('Recent'),
            if (items.recent.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    _filter != null
                        ? (items.pinned.isEmpty
                              ? 'No documents with this tag.'
                              : 'No other documents with this tag.')
                        : 'PDFs you open will appear here.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              )
            else
              _grid(items.recent),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Build: $buildStamp',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _grid(List<_Item> items) => SliverPadding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    sliver: SliverGrid(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 170,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.62,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, i) => _PdfCard(
          item: items[i],
          tags: [
            for (final t in _tagList)
              if (_docTags[items[i].cacheId]?.contains(t.name) ?? false) t,
          ],
          position: _positions[items[i].cacheId],
          thumbnails: _s.thumbnails,
          onTap: () => _openItem(items[i]),
          onLongPress: () => _showActions(items[i]),
        ),
        childCount: items.length,
      ),
    ),
  );
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
      child: Text(text, style: Theme.of(context).textTheme.titleMedium),
    ),
  );
}

/// A PDF card: first-page picture with a ✓ if a copy is stored (and a pin if
/// pinned), the name, and when it was last opened.
class _PdfCard extends StatelessWidget {
  const _PdfCard({
    required this.item,
    this.position,
    required this.thumbnails,
    required this.onTap,
    required this.onLongPress,
    this.tags = const [],
  });

  final _Item item;

  /// Its tags, shown as coloured chips under its name.
  final List<Tag> tags;

  /// Where the PDF was left, if it has been opened in the viewer.
  final DocumentState? position;
  final Thumbnails thumbnails;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lastOpened = item.recent?.lastOpened ?? item.copy?.lastUsed;
    return Semantics(
      button: true,
      label:
          '${item.name}${item.cached ? ', stored' : ''}'
          '${item.pinned ? ', pinned' : ''}',
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The picture takes whatever space the name and date leave, so
            // the card never overflows (e.g. with large system text).
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Card(
                    margin: EdgeInsets.zero,
                    clipBehavior: Clip.antiAlias,
                    child: FutureBuilder(
                      future: thumbnails.find(item.cacheId),
                      builder: (context, snap) => snap.data == null
                          ? Icon(
                              Icons.picture_as_pdf_outlined,
                              size: 48,
                              color: scheme.outline,
                            )
                          : Image.file(
                              snap.data!,
                              // Full page width; a tall page is cut off at
                              // the bottom rather than shrunk.
                              fit: BoxFit.fitWidth,
                              alignment: Alignment.topCenter,
                            ),
                    ),
                  ),
                  if (item.pinned)
                    Positioned(
                      top: 6,
                      left: 6,
                      child: _Badge(
                        icon: Icons.push_pin,
                        tooltip: 'Pinned: always kept',
                        background: scheme.secondaryContainer,
                        foreground: scheme.onSecondaryContainer,
                      ),
                    ),
                  if (item.cached)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: _Badge(
                        icon: Icons.check,
                        tooltip: 'Stored in the app: opens instantly',
                        background: scheme.primary,
                        foreground: scheme.onPrimary,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              item.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
            if (tags.isNotEmpty) TagDots(tags: tags),
            if (lastOpened != null)
              Text(
                formatDateTime(lastOpened),
                style: theme.textTheme.bodySmall,
              ),
            if (position case final p? when p.pageCount > 0) ...[
              const SizedBox(height: 4),
              Tooltip(
                message: 'Opens on page ${p.lastPage}',
                child: Row(
                  children: [
                    Expanded(
                      child: LinearProgressIndicator(
                        value: p.lastPage / p.pageCount,
                        minHeight: 3,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'p. ${p.lastPage}/${p.pageCount}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.icon,
    required this.tooltip,
    required this.background,
    required this.foreground,
  });

  final IconData icon;
  final String tooltip;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: background,
        shape: BoxShape.circle,
        boxShadow: const [BoxShadow(blurRadius: 2, color: Colors.black26)],
      ),
      child: Icon(icon, size: 16, color: foreground),
    ),
  );
}

/// Asks for a notebook's new name; pops it (or null).
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.start});

  final String start;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _field = TextEditingController(text: widget.start);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Rename notebook'),
    content: TextField(
      controller: _field,
      autofocus: true,
      textCapitalization: TextCapitalization.sentences,
      decoration: const InputDecoration(labelText: 'Name'),
      onSubmitted: (v) => Navigator.of(context).pop(v),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(_field.text),
        child: const Text('Rename'),
      ),
    ],
  );
}
