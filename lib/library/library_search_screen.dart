import 'dart:async';

import 'package:flutter/material.dart';

import '../core/library_search.dart';
import '../core/transfer_estimate.dart';
import 'library_search_service.dart';

/// A document the search looks through.
class SearchEntry {
  const SearchEntry({
    required this.id,
    required this.name,
    this.tags = const [],
    this.path,
    this.size = 0,
    this.notebook = false,
  });

  final String id;
  final String name;
  final List<String> tags;

  /// Its stored file, if there is one (to read its printed text from).
  final String? path;

  /// The file's size in bytes (for the time left while reading).
  final int size;

  /// Notebooks have no printed text.
  final bool notebook;
}

/// Searching every document from the home screen (owner, 2026-10-16):
/// names, tags, handwriting and printed text. Printed text is read once
/// per PDF, the first time, with a progress bar; search works on what's
/// ready meanwhile.
class LibrarySearchScreen extends StatefulWidget {
  const LibrarySearchScreen({
    super.key,
    required this.entries,
    required this.service,
    required this.onOpen,
    this.complete = true,
    this.savingBattery = false,
  });

  final List<SearchEntry> entries;

  /// [entries] is the whole library, so printed text kept for documents
  /// not in it can be forgotten.
  final bool complete;

  /// Battery saver is on: PDFs' printed text is read only when asked.
  final bool savingBattery;
  final Future<LibrarySearchService> Function() service;

  /// Opens a document, at [page] if given, with [query] searched in it.
  final Future<void> Function(String id, int? page, String query) onOpen;

  @override
  State<LibrarySearchScreen> createState() => _LibrarySearchScreenState();
}

class _LibrarySearchScreenState extends State<LibrarySearchScreen> {
  final _field = TextEditingController();
  LibrarySearchService? _service;

  /// What's ready to search, by document id.
  final _docs = <String, SearchableDocument>{};
  bool _loading = true;

  /// Not read yet because battery saver is on.
  List<SearchEntry> _waiting = const [];

  /// Documents loaded so far (while loading).
  int _loaded = 0;
  String _query = '';
  List<DocumentMatch> _results = const [];
  Timer? _typing;

  /// Pages shown per document before "Show all".
  static const _shownPages = 5;
  final _showAll = <String>{};

  // Reading printed text for the first time.
  bool _stop = false;
  bool _reading = false;
  String? _readingName;
  int _readingAt = 0, _readingCount = 0;
  double? _fraction;
  Duration? _left;
  int _notStored = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _stop = true;
    _typing?.cancel();
    _field.dispose();
    super.dispose();
  }

  SearchableDocument _doc(SearchEntry e, List<PageText> pages) =>
      SearchableDocument(id: e.id, name: e.name, tags: e.tags, pages: pages);

  Future<void> _load() async {
    final LibrarySearchService service;
    try {
      service = _service ??= await widget.service();
    } catch (_) {
      // Names and tags can still be searched.
      if (!mounted) return;
      setState(() {
        for (final e in widget.entries) {
          _docs[e.id] = _doc(e, const []);
        }
        _loading = false;
      });
      return;
    }
    final toRead = <SearchEntry>[];
    for (final e in widget.entries) {
      if (!mounted) return;
      setState(() => _loaded++);
      final hand = await service
          .handwriting(e.id)
          .catchError((_) => <PageText>[]);
      var printed = await service
          .savedPrinted(e.id)
          .catchError((_) => <PageText>[]);
      if (printed == null) {
        if (e.notebook) {
          await service.noPrinted(e.id).catchError((_) {});
        } else if (e.path != null) {
          toRead.add(e);
        } else {
          _notStored++;
        }
        printed = const [];
      }
      _docs[e.id] = _doc(e, [...hand, ...printed]);
      if (!mounted) return;
    }
    if (widget.complete && widget.entries.isNotEmpty) {
      unawaited(
        service
            .keepOnly({for (final e in widget.entries) e.id})
            .catchError((_) {}),
      );
    }
    setState(() {
      _loading = false;
      _search();
    });
    if (widget.savingBattery && toRead.isNotEmpty) {
      setState(() => _waiting = toRead);
      return;
    }
    await _readPrinted(service, toRead);
  }

  /// Reads the printed text of [entries] (first time only), one after
  /// another, adding each to the search when done.
  Future<void> _readPrinted(
    LibrarySearchService service,
    List<SearchEntry> entries,
  ) async {
    if (entries.isEmpty) return;
    final total = entries.fold<int>(0, (n, e) => n + e.size);
    final estimate = TransferEstimator(totalBytes: total, smoothing: 0.2);
    final started = DateTime.now();
    var done = 0;
    setState(() {
      _reading = true;
      _readingCount = entries.length;
    });
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      if (_stop || !mounted) break;
      setState(() {
        _readingName = e.name;
        _readingAt = i + 1;
      });
      final ok = await service
          .readPrinted(
            e.id,
            e.path!,
            (page, pages) {
              if (!mounted || pages == 0) return;
              estimate.update(
                bytesDone: done + (e.size * page / pages).round(),
                elapsed: DateTime.now().difference(started),
              );
              setState(() {
                _fraction =
                    estimate.fraction ?? (i + page / pages) / entries.length;
                _left = estimate.remaining;
              });
            },
            () => _stop || !mounted,
            pause: () => _paused?.future ?? Future.value(),
          )
          .catchError((_) => false);
      done += e.size;
      if (!mounted) return;
      if (ok) {
        final printed =
            await service.savedPrinted(e.id).catchError((_) => null) ??
            const <PageText>[];
        final had = _docs[e.id]?.pages ?? const <PageText>[];
        _docs[e.id] = _doc(e, [...had, ...printed]);
      }
      if (!mounted) return;
      setState(_search);
    }
    if (mounted) setState(() => _reading = false);
  }

  void _changed(String text) {
    _typing?.cancel();
    _typing = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      setState(() {
        _query = text.trim();
        _showAll.clear();
        _search();
      });
    });
  }

  void _search() => _results = searchLibrary(_docs.values, _query);

  /// Set while a document opened from here is open: reading printed text
  /// waits, so it doesn't slow the document down.
  Completer<void>? _paused;

  Future<void> _open(String id, int? page) async {
    final pause = _paused ??= Completer<void>();
    try {
      await widget.onOpen(id, page, tidySearch(_query));
    } finally {
      _paused = null;
      pause.complete();
    }
    // What's written, and its pages, may have changed there.
    final service = _service;
    final e = widget.entries.where((e) => e.id == id).firstOrNull;
    if (service == null || e == null || !mounted) return;
    final hand = await service.handwriting(id).catchError((_) => <PageText>[]);
    final printed =
        await service.savedPrinted(id).catchError((_) => null) ??
        const <PageText>[];
    if (!mounted) return;
    setState(() {
      _docs[id] = _doc(e, [...hand, ...printed]);
      _search();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _field,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Search all documents',
            border: InputBorder.none,
          ),
          onChanged: _changed,
        ),
        actions: [
          if (_field.text.isNotEmpty)
            IconButton(
              tooltip: 'Clear the search',
              icon: const Icon(Icons.close),
              onPressed: () {
                _field.clear();
                _changed('');
              },
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_reading) _readingBar(theme),
          if (!_reading && _waiting.isNotEmpty)
            Material(
              color: theme.colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Battery saver is on, so the printed text of '
                        '${_waiting.length} '
                        '${_waiting.length == 1 ? 'PDF' : 'PDFs'} isn\'t read '
                        'yet.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        final service = _service;
                        final toRead = _waiting;
                        setState(() => _waiting = const []);
                        if (service != null) _readPrinted(service, toRead);
                      },
                      child: const Text('Read now'),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(child: _body(theme)),
        ],
      ),
    );
  }

  Widget _readingBar(ThemeData theme) {
    final left = _left;
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Reading printed text, first time only: '
                    '${_readingName ?? ''} ($_readingAt of $_readingCount)'
                    '${left == null ? '' : ' · ${formatRemaining(left)}'}',
                    style: theme.textTheme.bodySmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _stop = true;
                    _reading = false;
                  }),
                  child: const Text('Stop'),
                ),
              ],
            ),
            LinearProgressIndicator(value: _fraction),
          ],
        ),
      ),
    );
  }

  Widget _body(ThemeData theme) {
    if (_loading) {
      final n = widget.entries.length;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Getting your documents ready… ($_loaded of $n)'),
              const SizedBox(height: 12),
              LinearProgressIndicator(value: n == 0 ? null : _loaded / n),
            ],
          ),
        ),
      );
    }
    if (_query.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Finds words in document names, tags, handwriting and printed '
          'text, across all ${widget.entries.length} documents.'
          '${_notStored > 0 ? '\n\n$_notStored PDFs aren\'t stored on this '
                    'tablet, so their printed text is searched only once '
                    'they\'re opened again.' : ''}',
          style: theme.textTheme.bodyMedium,
        ),
      );
    }
    if (_results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text('Nothing found for “$_query”.'),
      );
    }
    return ListView(children: [for (final m in _results) ..._result(theme, m)]);
  }

  List<Widget> _result(ThemeData theme, DocumentMatch m) {
    final where = [
      if (m.inName) 'in its name',
      for (final t in m.tags) 'tag “$t”',
      if (m.count > 0)
        '${m.count} ${m.count == 1 ? 'match' : 'matches'} on '
            '${m.pages.map((p) => p.page).toSet().length} '
            '${m.pages.map((p) => p.page).toSet().length == 1 ? 'page' : 'pages'}',
    ];
    final all = _showAll.contains(m.id);
    final pages = all ? m.pages : m.pages.take(_shownPages).toList();
    return [
      ListTile(
        leading: const Icon(Icons.description_outlined),
        title: Text(m.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(where.join(' · ')),
        onTap: () => _open(m.id, null),
      ),
      for (final p in pages)
        ListTile(
          dense: true,
          contentPadding: const EdgeInsets.only(left: 72, right: 16),
          title: Text(
            'Page ${p.page} · '
            '${p.kind == FoundIn.handwriting ? 'handwriting' : 'printed'}'
            '${p.count > 1 ? ' · ${p.count} times' : ''}',
            style: theme.textTheme.labelMedium,
          ),
          subtitle: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: p.before),
                TextSpan(
                  text: p.match,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                TextSpan(text: p.after),
              ],
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => _open(m.id, p.page),
        ),
      if (!all && m.pages.length > _shownPages)
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 64),
            child: TextButton(
              onPressed: () => setState(() => _showAll.add(m.id)),
              child: Text('Show all ${m.pages.length} pages'),
            ),
          ),
        ),
      const Divider(height: 1),
    ];
  }
}
