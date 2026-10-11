import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/event_log.dart';
import '../core/ink_classifier.dart';
import '../core/page_ink.dart';
import '../core/page_recognition.dart';
import '../core/recognition/recognizer.dart';
import '../core/stroke_grouping.dart';

/// A recognised handwritten word on a page.
class RecognizedWord {
  const RecognizedWord({
    required this.text,
    required this.alternatives,
    required this.box,
    required this.line,
  });

  final String text;

  /// Other readings, best first (for corrections, task 2.4).
  final List<String> alternatives;

  /// Where the word is, in PDF page coordinates.
  final InkBox box;

  /// Line number on the page, top first.
  final int line;
}

/// Recognises the handwriting on a PDF's pages (task 2.3): after the pen
/// pauses on a page, new or changed words go to the [Recognizer] (with the
/// text before them as context) and their text is kept for display. Works
/// with any engine (CLAUDE.md rule 1); the feedback layer (task 2.6) will
/// sit between the engine and this.
class InkTextController extends ChangeNotifier {
  InkTextController({
    required this.engine,
    this.eventLog,
    this.classifier = const ShapeInkClassifier(),
  });

  /// Sorts writing from drawings (underlines, circles, arrows), so only
  /// writing is read (task 2.2b).
  final InkClassifier classifier;

  final Recognizer engine;

  /// Where recognitions are logged (CLAUDE.md rule 5); can be set later.
  EventLog? eventLog;

  /// Engines expect writing about the size it is on screen: the typical
  /// letter is scaled to this many pixels.
  static const engineLetterPixels = 50.0;

  final _words = <int, Map<String, RecognizedWord>>{};
  final _timers = <int, Timer>{};
  final _running = <int>{};
  final _again = <int>{};
  final _pending = <int, List<PageStroke>>{};
  bool? _ready;
  bool _disposed = false;

  /// Why recognition isn't running (e.g. MyScript keys missing), if so.
  String? problem;

  /// Words on [page] in reading order (top line first, left to right).
  List<RecognizedWord> wordsOn(int page) {
    final words = _words[page]?.values.toList() ?? <RecognizedWord>[];
    words.sort(
      (a, b) => a.line != b.line
          ? a.line.compareTo(b.line)
          : a.box.left.compareTo(b.box.left),
    );
    return words;
  }

  /// The recognised text of [page], one line per handwritten line.
  String textOf(int page) {
    final lines = <int, List<String>>{};
    for (final w in wordsOn(page)) {
      lines.putIfAbsent(w.line, () => []).add(w.text);
    }
    return [for (final l in lines.values) l.join(' ')].join('\n');
  }

  /// The ink on [page] changed: recognise it once the pen has paused for
  /// [pause]. [strokes] is the page's ink at this moment.
  void inkChanged(int page, List<PageStroke> strokes, Duration pause) {
    _pending[page] = strokes;
    _timers[page]?.cancel();
    _timers[page] = Timer(pause, () => _run(page));
  }

  /// Recognises [page] straight away if it has ink that hasn't been
  /// recognised yet (e.g. ink saved earlier, when the page is first shown).
  void ensure(int page, List<PageStroke> strokes) {
    if (_words.containsKey(page) || _pending.containsKey(page)) return;
    if (!strokes.any(isWriting)) return;
    _pending[page] = strokes;
    _run(page);
  }

  Future<bool> _isReady() async {
    if (_ready != null) return _ready!;
    try {
      final s = await engine.status();
      _ready = s.isReady;
      problem = s.isReady ? null : s.message;
    } catch (e) {
      _ready = false;
      problem = '$e';
    }
    return _ready!;
  }

  Future<void> _run(int page) async {
    if (_running.contains(page)) {
      _again.add(page); // run once more when the current run finishes
      return;
    }
    final strokes = _pending.remove(page);
    if (strokes == null || !await _isReady() || _disposed) return;
    _running.add(page);
    try {
      final words = _words.putIfAbsent(page, () => {});
      final known = {for (final e in words.entries) e.key: e.value.text};
      final kinds = await classifier.classify(strokes);
      if (_disposed) return;
      final plan = planRecognition(
        strokes,
        known,
        include: (i) => i >= kinds.length || kinds[i] == InkKind.writing,
      );
      final before = words.length;
      words.removeWhere((key, _) => !plan.keys.contains(key));
      // Lines can be renumbered when a line is added above.
      for (var l = 0; l < plan.lines.length; l++) {
        for (final w in plan.lines[l].words) {
          final key = wordKey(strokes, w);
          final old = words[key];
          if (old != null && old.line != l) {
            words[key] = RecognizedWord(
              text: old.text,
              alternatives: old.alternatives,
              box: old.box,
              line: l,
            );
          }
        }
      }
      if (words.length != before) _notify();
      final scale = engineLetterPixels / plan.letterHeight;
      for (final job in plan.jobs) {
        if (_disposed) return;
        final ink = wordInk(strokes, job.word, scale: scale);
        final sent = DateTime.now().millisecondsSinceEpoch;
        List<Candidate> candidates;
        try {
          candidates = await engine.recognize(
            ink,
            RecognitionContext(
              // Includes words recognised earlier in this same run.
              preContext: _textBefore(words, job),
              writingAreaWidth: job.word.box.width * scale,
              writingAreaHeight: job.word.box.height * scale,
            ),
          );
        } on RecognitionException catch (e) {
          problem = e.message;
          _notify();
          continue;
        }
        if (_disposed) return;
        final texts = [
          for (final c in candidates)
            if (c.text.trim().isNotEmpty) c.text.trim(),
        ];
        if (texts.isEmpty) continue;
        words[job.key] = RecognizedWord(
          text: texts.first,
          alternatives: texts.skip(1).toList(),
          box: job.word.box,
          line: job.line,
        );
        problem = null;
        _notify();
        final now = DateTime.now().millisecondsSinceEpoch;
        unawaited(
          eventLog
                  ?.log(
                    LoggedEvent(
                      type: 'recognition',
                      at: DateTime.fromMillisecondsSinceEpoch(now),
                      engine: engine.name,
                      latencyMs: now - job.word.end,
                      data: {
                        'source': 'pdf',
                        'page': page,
                        'text': texts.first,
                        'alternatives': texts.skip(1).take(4).toList(),
                        'engineMs': now - sent,
                      },
                    ),
                  )
                  .catchError((_) {}) ??
              Future<void>.value(),
        );
      }
    } finally {
      _running.remove(page);
      if (_again.remove(page) && !_disposed) unawaited(_run(page));
    }
  }

  static String _textBefore(
    Map<String, RecognizedWord> words,
    RecognitionJob job,
  ) {
    final before =
        [
          for (final w in words.values)
            if (w.line < job.line ||
                (w.line == job.line && w.box.left < job.word.box.left))
              w,
        ]..sort(
          (a, b) => a.line != b.line
              ? a.line.compareTo(b.line)
              : a.box.left.compareTo(b.box.left),
        );
    final text = before.map((w) => w.text).join(' ');
    return text.length > preContextChars
        ? text.substring(text.length - preContextChars)
        : text;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final t in _timers.values) {
      t.cancel();
    }
    super.dispose();
  }
}
