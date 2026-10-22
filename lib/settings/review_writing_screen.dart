import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/feedback/correction.dart';
import '../core/feedback/correction_store.dart';
import '../core/ink.dart';
import '../core/event_log.dart';
import '../core/ink_store.dart';
import '../storage/app_database.dart';
import '../storage/sqlite_correction_store.dart';
import '../storage/sqlite_event_log.dart';
import '../storage/sqlite_ink_store.dart';
import '../viewer/ink_text_controller.dart';
import '../viewer/open_document.dart';
import 'review_words.dart';

/// "Review my writing" (owner, 2026-10-22): the words read from all the
/// user's PDFs, one at a time, unsure ones first. "Right" marks the
/// reading as checked; typing the word fixes it and keeps a correction with
/// its ink, as fixing it in the PDF does. Checked and fixed words are
/// certain, so they go into the training data as labelled handwriting.
class ReviewWritingScreen extends StatefulWidget {
  const ReviewWritingScreen({
    super.key,
    this.openInk,
    this.openCorrections,
    this.openEventLog,
  });

  /// For tests; the app's own database otherwise.
  final Future<InkStore> Function()? openInk;
  final Future<CorrectionStore> Function()? openCorrections;
  final Future<EventLog> Function()? openEventLog;

  @override
  State<ReviewWritingScreen> createState() => _ReviewWritingScreenState();
}

class _ReviewWritingScreenState extends State<ReviewWritingScreen> {
  InkStore? _ink;
  List<ReviewItem>? _items;
  Object? _error;
  var _at = 0;
  var _done = 0;
  final _typed = TextEditingController();

  /// PDFs gathered so far, of how many (for the progress bar).
  var _read = 0, _of = 0;

  /// The word showing, in full (with its ink), once loaded; null while
  /// loading.
  RecognizedWord? _word;

  /// An answer being saved: no other until it's done (a quick double tap
  /// would skip a word).
  var _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final ink = await (widget.openInk ?? SqliteInkStore.open)();
      final docs = (await ink.documentsWithInk()).toList()..sort();
      final skip = openDocument.value;
      if (mounted) setState(() => _of = docs.length);
      final unsure = <ReviewItem>[], rest = <ReviewItem>[];
      // One PDF at a time, its words read away from the screen's thread,
      // keeping only what's needed to list them.
      for (final id in docs) {
        if (id != skip) {
          final t = await ink.loadText(id);
          if (t.isNotEmpty) {
            for (final item in await compute(_review, (id, t))) {
              (item.unsure ? unsure : rest).add(item);
            }
          }
        }
        if (!mounted) return;
        setState(() => _read++);
      }
      if (!mounted) return;
      setState(() {
        _ink = ink;
        _items = [...unsure, ...rest];
      });
      await _show();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  static List<ReviewItem> _review((String, Map<int, String>) a) =>
      wordsToReview({a.$1: a.$2});

  /// Loads the word at [_at] in full; words gone since (the page was read
  /// again) are passed over.
  Future<void> _show() async {
    final items = _items, ink = _ink;
    if (items == null || ink == null) return;
    setState(() => _word = null);
    while (_at < items.length) {
      final item = items[_at];
      final json = (await ink.loadText(item.documentId))[item.page];
      final w = json == null ? null : loadWord(json, item.key);
      if (!mounted) return;
      if (w != null && w.text == item.text && !w.corrected && !w.checked) {
        setState(() => _word = w);
        return;
      }
      _at++;
    }
    if (mounted) setState(() {});
  }

  /// Saves the answer for the word showing ([text] null: it's right) and
  /// shows the next one.
  Future<void> _answer({String? text}) async {
    final items = _items, ink = _ink, w = _word;
    if (_busy || items == null || ink == null || w == null) return;
    if (_at >= items.length) return;
    final item = items[_at];
    final messenger = ScaffoldMessenger.of(context);
    _busy = true;
    try {
      final json = (await ink.loadText(item.documentId))[item.page];
      final updated = json == null
          ? null
          : answerWord(json, item.key, text: text, shown: w.text);
      if (updated != null) {
        await ink.saveText(item.documentId, item.page, updated);
        final t = text?.trim() ?? '';
        final fixed = t.isNotEmpty && t != w.text;
        // Putting back what the engine read (the app had swapped it): an
        // undo, nothing to learn, as in the PDF.
        final undo = fixed && t == w.engineReading;
        if (fixed && !undo) {
          final store =
              await (widget.openCorrections ?? SqliteCorrectionStore.open)();
          await store.add(
            CorrectionRecord(
              recognized: w.engineReading,
              corrected: t,
              previousWord: w.previousWord,
              strokes: w.ink,
              at: DateTime.now(),
              documentId: item.documentId,
            ),
          );
        }
        // Logged like answers in the PDF (rule 5).
        await _log(
          fixed
              ? LoggedEvent(
                  type: 'correction',
                  at: DateTime.now(),
                  data: {
                    'source': 'review',
                    'page': item.page,
                    'recognized': w.engineReading,
                    'shown': w.text,
                    'corrected': t,
                    'wasAutoReplaced': w.autoReplaced,
                    'undo': undo,
                    'doc': item.documentId,
                  },
                )
              : LoggedEvent(
                  type: 'accept',
                  at: DateTime.now(),
                  data: {
                    'source': 'review',
                    'page': item.page,
                    'text': w.text,
                    'asked': true,
                    'doc': item.documentId,
                  },
                ),
        );
        _done++;
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text("Couldn't save that word: $e")),
      );
      return;
    } finally {
      _busy = false;
    }
    if (!mounted) return;
    _typed.clear();
    _at++;
    await _show();
  }

  Future<void> _log(LoggedEvent e) async {
    try {
      final log =
          await (widget.openEventLog ??
              () async => SqliteEventLog(await AppDatabase.open()))();
      await log.log(e);
    } catch (_) {
      // Logging never stops an answer being saved.
    }
  }

  void _skip() {
    if (_busy) return;
    _typed.clear();
    _at++;
    unawaited(_show());
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: const Text('Review my writing')),
      body: _error != null
          ? Center(child: Text("Couldn't read your words: $_error"))
          : items == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LinearProgressIndicator(
                      value: _of == 0 ? null : _read / _of,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _of == 0
                          ? 'Gathering the words from your PDFs…'
                          : 'Gathering the words from your PDFs: $_read of $_of…',
                    ),
                  ],
                ),
              ),
            )
          : _at >= items.length
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  items.isEmpty
                      ? 'Nothing to review: every word read from your PDFs '
                            'has been checked or fixed.'
                      : 'All done for now: $_done '
                            '${_done == 1 ? 'word' : 'words'} checked or fixed.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : _word == null
          ? const Center(child: CircularProgressIndicator())
          : _card(context, items),
    );
  }

  Widget _card(BuildContext context, List<ReviewItem> items) {
    final w = _word!;
    final scheme = Theme.of(context).colorScheme;
    final unsureLeft = items.skip(_at).where((i) => i.unsure).length;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Word ${_at + 1} of ${items.length}'
          '${unsureLeft > 0 ? ' · $unsureLeft the app wasn\'t sure of' : ''}',
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                SizedBox(
                  height: 160,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _InkPainter(w.ink, scheme.onSurface),
                  ),
                ),
                const SizedBox(height: 12),
                Text(w.text, style: Theme.of(context).textTheme.headlineMedium),
                Text(
                  w.unsure
                      ? 'Read as this, but the app wasn\'t sure'
                      : 'Read as this',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                icon: const Icon(Icons.check),
                label: const Text('Right'),
                onPressed: () => _answer(),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton(onPressed: _skip, child: const Text('Skip')),
          ],
        ),
        const SizedBox(height: 16),
        if (w.alternatives.isNotEmpty) ...[
          const Text('Or it says:'),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            children: [
              for (final a in w.alternatives.take(5))
                if (a.isNotEmpty && a != w.text)
                  ActionChip(
                    label: Text(a),
                    onPressed: () => _answer(text: a),
                  ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        TextField(
          controller: _typed,
          decoration: InputDecoration(
            labelText: 'It says…',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: 'Save this word',
              icon: const Icon(Icons.send),
              onPressed: () => _answer(text: _typed.text),
            ),
          ),
          textInputAction: TextInputAction.done,
          onSubmitted: (t) => _answer(text: t),
        ),
      ],
    );
  }
}

/// A word's ink, fitted to the space and centred.
class _InkPainter extends CustomPainter {
  _InkPainter(this.ink, this.colour);

  final List<InkStroke> ink;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final pts = [for (final s in ink) ...s.points];
    if (pts.isEmpty) return;
    var l = pts.first.x, r = l, t = pts.first.y, b = t;
    for (final p in pts) {
      if (p.x < l) l = p.x;
      if (p.x > r) r = p.x;
      if (p.y < t) t = p.y;
      if (p.y > b) b = p.y;
    }
    final w = (r - l).clamp(1.0, double.infinity);
    final h = (b - t).clamp(1.0, double.infinity);
    final k = [
      size.width / w,
      size.height / h,
      4.0,
    ].reduce((a, c) => a < c ? a : c);
    final dx = (size.width - w * k) / 2 - l * k;
    final dy = (size.height - h * k) / 2 - t * k;
    final paint = Paint()
      ..color = colour
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    for (final s in ink) {
      if (s.points.isEmpty) continue;
      final path = Path()
        ..moveTo(s.points.first.x * k + dx, s.points.first.y * k + dy);
      for (final p in s.points.skip(1)) {
        path.lineTo(p.x * k + dx, p.y * k + dy);
      }
      if (s.points.length == 1) {
        path.lineTo(s.points.first.x * k + dx + 0.1, s.points.first.y * k + dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_InkPainter old) => old.ink != ink || old.colour != colour;
}
