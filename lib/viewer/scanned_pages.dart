import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../core/scanned_text.dart';
import '../core/transfer_estimate.dart';
import '../platform/ocr_channel.dart';
import 'scanned_reading.dart';

/// The answer to "This PDF looks scanned": whether to read it, and
/// whether to do the same for other scanned PDFs.
typedef ScannedAnswer = ({bool read, bool same});

/// Asks once per PDF (owner, 2026-10-17) whether to read its scanned
/// pages. [haveReader] says whether a text reader is downloaded yet (if
/// not, reading starts by downloading one). Null if dismissed.
Future<ScannedAnswer?> askReadScanned(
  BuildContext context, {
  required bool haveReader,
}) => showDialog<ScannedAnswer>(
  context: context,
  // An answer is needed (or it would be asked again every time).
  barrierDismissible: false,
  builder: (context) => _AskScanned(haveReader: haveReader),
);

class _AskScanned extends StatefulWidget {
  const _AskScanned({required this.haveReader});

  final bool haveReader;

  @override
  State<_AskScanned> createState() => _AskScannedState();
}

class _AskScannedState extends State<_AskScanned> {
  var _same = false;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('This PDF looks scanned'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Its pages are pictures, so their words can\'t be searched yet. '
          'The tablet can read them, here on the tablet (nothing is sent '
          'anywhere).'
          '${widget.haveReader ? '' : ' It needs a text reader first, '
                    'downloaded once.'}',
        ),
        const SizedBox(height: 8),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _same,
          onChanged: (v) => setState(() => _same = v ?? false),
          title: const Text('Do the same for other scanned PDFs'),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop((read: false, same: _same)),
        child: const Text('Not this PDF'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop((read: true, same: _same)),
        child: Text(widget.haveReader ? 'Read it' : 'Get a reader'),
      ),
    ],
  );
}

/// How far reading a PDF's scanned pages has got.
typedef ScanProgress = ({int done, int total, Duration? left});

/// Reads a PDF's scanned pages in the background while it's open, one
/// page at a time, keeping each as it goes ([progress] for the card).
class ScannedPagesReader {
  ScannedPagesReader({
    required this.documentId,
    required this.store,
    required this.reader,
  });

  final String documentId;
  final ScannedTextStore store;
  final TextReaderService reader;

  final progress = ValueNotifier<ScanProgress?>(null);

  /// Paused by the user (owner, 2026-10-18: pause and resume reading a
  /// big scan): it waits before the next page until resumed.
  final paused = ValueNotifier<bool>(false);
  var _stop = false;
  var _disposed = false;

  bool get running => progress.value != null;

  /// The PDF's own pages (1 to [pageCount]) not read yet.
  Future<List<int>> pagesLeft(int pageCount) async {
    final done = await store.pagesRead(documentId);
    return [
      for (var p = 1; p <= pageCount; p++)
        if (!done.contains(p)) p,
    ];
  }

  /// Reads [pages] with [modelId]. Returns how many pages were read and
  /// whether it finished (false if stopped, or it failed: then [error]).
  Future<({int read, bool finished, Object? error})> run(
    List<int> pages,
    String modelId,
    Future<PageImage?> Function(int page) render, {
    void Function(Duration took)? onPageTook,
    Future<void> Function()? pause,
  }) async {
    if (running || pages.isEmpty || _disposed) {
      return (read: 0, finished: pages.isEmpty, error: null);
    }
    _stop = false;
    paused.value = false;
    final started = DateTime.now();
    // Time spent paused isn't counted in the time left.
    var pausedFor = Duration.zero;
    final estimate = TransferEstimator(totalBytes: pages.length);
    var read = 0;
    progress.value = (done: 0, total: pages.length, left: null);
    try {
      final finished = await readScannedPages(
        documentId: documentId,
        pages: pages,
        store: store,
        reader: reader,
        modelId: modelId,
        render: render,
        stop: () => _stop || _disposed,
        pause: () async {
          await pause?.call();
          if (!paused.value) return;
          final from = DateTime.now();
          while (paused.value && !_stop && !_disposed) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
          pausedFor += DateTime.now().difference(from);
        },
        onPage: (done, total, took) {
          read = done;
          onPageTook?.call(took);
          estimate.update(
            bytesDone: done,
            elapsed: DateTime.now().difference(started) - pausedFor,
          );
          if (!_disposed) {
            progress.value = (
              done: done,
              total: total,
              left: estimate.remaining,
            );
          }
        },
      );
      return (read: read, finished: finished, error: null);
    } catch (e) {
      return (read: read, finished: false, error: e);
    } finally {
      if (!_disposed) progress.value = null;
    }
  }

  bool get stopped => _stop;

  void stop() => _stop = true;

  void pause() => paused.value = true;

  void resume() => paused.value = false;

  void dispose() {
    _disposed = true;
    _stop = true;
    progress.dispose();
    paused.dispose();
  }
}

/// [PdfDocument] page drawing for [ScannedPagesReader.run].
Future<PageImage?> Function(int page) renderPagesOf(PdfDocument document) =>
    (page) => renderForReading(document, page);

/// "Reading scanned pages: 3 of 20 · about 1 min left", with Pause (or
/// Resume) and Stop.
class ScannedProgressCard extends StatelessWidget {
  const ScannedProgressCard({
    super.key,
    required this.progress,
    required this.onStop,
    this.paused = false,
    this.onPause,
    this.onResume,
  });

  final ScanProgress progress;
  final VoidCallback onStop;
  final bool paused;
  final VoidCallback? onPause, onResume;

  @override
  Widget build(BuildContext context) {
    final left = progress.left;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      paused
                          ? 'Paused: ${progress.done} of ${progress.total} '
                                'scanned pages read'
                          : 'Reading scanned pages: ${progress.done} of '
                                '${progress.total}'
                                '${left == null ? '' : ' · ${formatRemaining(left)}'}',
                    ),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: progress.total == 0
                          ? null
                          : progress.done / progress.total,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (paused && onResume != null)
                TextButton(onPressed: onResume, child: const Text('Resume'))
              else if (onPause != null)
                TextButton(onPressed: onPause, child: const Text('Pause')),
              TextButton(onPressed: onStop, child: const Text('Stop')),
            ],
          ),
        ),
      ),
    );
  }
}

/// [inner], also telling [onSaved] about each page kept (so the open PDF
/// can search it straight away).
class TellingScannedTextStore implements ScannedTextStore {
  TellingScannedTextStore(this.inner, this.onSaved);

  final ScannedTextStore inner;
  final void Function(int page, List<ScannedLine> lines) onSaved;

  @override
  Future<Map<int, List<ScannedLine>>> load(String documentId) =>
      inner.load(documentId);

  @override
  Future<Set<int>> pagesRead(String documentId) => inner.pagesRead(documentId);

  @override
  Future<void> savePage(
    String documentId,
    int page,
    List<ScannedLine> lines,
  ) async {
    await inner.savePage(documentId, page, lines);
    onSaved(page, lines);
  }

  @override
  Future<Set<String>> documents() => inner.documents();

  @override
  Future<void> forget(String documentId) => inner.forget(documentId);
}
