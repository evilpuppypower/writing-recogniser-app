import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/feedback/correction.dart';
import '../core/feedback/correction_store.dart';
import '../core/ink.dart';
import '../core/ink_store.dart';
import '../storage/sqlite_correction_store.dart';
import '../storage/sqlite_ink_store.dart';
import '../viewer/open_document.dart';
import 'review_words.dart';

/// "Review my writing" (owner, 2026-10-22): the words read from all the
/// user's PDFs, one at a time, unsure ones first. "Right" marks the
/// reading as checked; typing the word fixes it and keeps a correction with
/// its ink, as fixing it in the PDF does. Checked and fixed words are
/// certain, so they go into the training data as labelled handwriting.
class ReviewWritingScreen extends StatefulWidget {
  const ReviewWritingScreen({super.key, this.openInk, this.openCorrections});

  /// For tests; the app's own database otherwise.
  final Future<InkStore> Function()? openInk;
  final Future<CorrectionStore> Function()? openCorrections;

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
      final texts = <String, Map<int, String>>{};
      for (final id in await ink.documentsWithInk()) {
        final t = await ink.loadText(id);
        if (t.isNotEmpty) texts[id] = t;
      }
      // Many pages of words: read away from the screen's thread.
      final items = await compute(_review, (texts, openDocument.value));
      if (!mounted) return;
      setState(() {
        _ink = ink;
        _items = items;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  static List<ReviewItem> _review((Map<String, Map<int, String>>, String?) a) =>
      wordsToReview(a.$1, skipDocument: a.$2);

  /// Saves the answer for the word showing ([text] null: it's right) and
  /// shows the next one.
  Future<void> _answer({String? text}) async {
    final items = _items, ink = _ink;
    if (items == null || ink == null || _at >= items.length) return;
    final item = items[_at];
    final messenger = ScaffoldMessenger.of(context);
    try {
      final pages = await ink.loadText(item.documentId);
      final json = pages[item.page];
      final updated = json == null
          ? null
          : answerWord(json, item.word.key, text: text);
      if (updated != null) {
        await ink.saveText(item.documentId, item.page, updated);
        final t = text?.trim() ?? '';
        if (t.isNotEmpty && t != item.word.text) {
          final store =
              await (widget.openCorrections ?? SqliteCorrectionStore.open)();
          await store.add(
            CorrectionRecord(
              recognized: item.word.engineReading,
              corrected: t,
              previousWord: item.word.previousWord,
              strokes: item.word.ink,
              at: DateTime.now(),
              documentId: item.documentId,
            ),
          );
        }
        _done++;
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text("Couldn't save that word: $e")),
      );
      return;
    }
    if (!mounted) return;
    _typed.clear();
    setState(() => _at++);
  }

  void _skip() {
    _typed.clear();
    setState(() => _at++);
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: const Text('Review my writing')),
      body: _error != null
          ? Center(child: Text("Couldn't read your words: $_error"))
          : items == null
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('Gathering the words from your PDFs…'),
                ],
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
          : _card(context, items),
    );
  }

  Widget _card(BuildContext context, List<ReviewItem> items) {
    final item = items[_at];
    final w = item.word;
    final scheme = Theme.of(context).colorScheme;
    final unsureLeft = items.skip(_at).where((i) => i.word.unsure).length;
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
