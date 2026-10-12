import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/event_log.dart';
import '../core/feedback/correction.dart';
import '../core/feedback/correction_store.dart';
import '../core/feedback/feedback_layer.dart';
import '../core/ink.dart';
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
    this.key = '',
    this.engineText,
    this.autoReplaced = false,
    this.corrected = false,
    this.previousWord = '',
    this.ink = const [],
  });

  final String text;

  /// Other readings, best first (for corrections, task 2.4).
  final List<String> alternatives;

  /// Where the word is, in PDF page coordinates.
  final InkBox box;

  /// Line number on the page, top first.
  final int line;

  /// Identifies the word's strokes (see wordKey).
  final String key;

  /// What the engine itself read, before the feedback layer (defaults to
  /// [text]).
  final String? engineText;

  /// Swapped automatically from an earlier correction (shown underlined;
  /// undoable).
  final bool autoReplaced;

  /// Set by the user.
  final bool corrected;

  /// The word before it, for context-aware corrections.
  final String previousWord;

  /// The word's ink as sent to the engine (kept with corrections, rule 4).
  final List<InkStroke> ink;

  String get engineReading => engineText ?? text;

  RecognizedWord copyWith({
    String? text,
    List<String>? alternatives,
    int? line,
    bool? autoReplaced,
    bool? corrected,
  }) => RecognizedWord(
    text: text ?? this.text,
    alternatives: alternatives ?? this.alternatives,
    box: box,
    line: line ?? this.line,
    key: key,
    engineText: engineText,
    autoReplaced: autoReplaced ?? this.autoReplaced,
    corrected: corrected ?? this.corrected,
    previousWord: previousWord,
    ink: ink,
  );
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
    FeedbackLayer? feedback,
    this.corrections,
    this.documentId,
  }) : feedback = feedback ?? CorrectionMemory();

  /// Re-ranks or swaps the engine's words using the user's corrections.
  final FeedbackLayer feedback;

  /// Where corrections are saved (null: kept only while the PDF is open).
  CorrectionStore? corrections;

  /// The open PDF (for corrections limited to one PDF).
  final String? documentId;

  /// Teaches the feedback layer every saved correction. Call once when the
  /// PDF opens; corrections only affect words read from then on.
  Future<void> loadCorrections() async {
    final store = corrections;
    if (store == null) return;
    for (final c in await store.all()) {
      feedback.learn(c);
    }
  }

  /// The user says [word] on [page] really reads [text]: shows it, saves
  /// the correction with the word's ink (rule 4) and teaches the feedback
  /// layer, so the same misreading is fixed next time.
  Future<void> correct(int page, RecognizedWord word, String text) async {
    final t = text.trim();
    final words = _words[page];
    if (t.isEmpty || words == null || !words.containsKey(word.key)) return;
    words[word.key] = word.copyWith(
      text: t,
      alternatives: [
        word.engineReading,
        ...word.alternatives.where((a) => a != t && a != word.engineReading),
      ],
      corrected: true,
      autoReplaced: false,
    );
    _notify();
    final undo = t == word.engineReading; // undoing a swap
    if (undo) {
      _logCorrection(page, word, t, undo: true);
      return; // nothing to learn
    }
    final record = CorrectionRecord(
      recognized: word.engineReading,
      corrected: t,
      previousWord: word.previousWord,
      strokes: word.ink,
      at: DateTime.now(),
      documentId: documentId,
    );
    feedback.learn(record);
    unawaited(corrections?.add(record).catchError((_) {}));
    _logCorrection(page, word, t, at: record.at);
  }

  void _logCorrection(
    int page,
    RecognizedWord word,
    String corrected, {
    bool undo = false,
    DateTime? at,
  }) => _log(
    LoggedEvent(
      type: 'correction',
      at: at ?? DateTime.now(),
      engine: engine.name,
      data: {
        'source': 'pdf',
        'page': page,
        'recognized': word.engineReading,
        'shown': word.text,
        'corrected': corrected,
        'wasAutoReplaced': word.autoReplaced,
        'undo': undo,
        'word': word.key,
        'doc': ?documentId,
      },
    ),
  );

  void _log(LoggedEvent e) =>
      unawaited(eventLog?.log(e).catchError((_) {}) ?? Future<void>.value());

  /// The user says this ink isn't writing (a drawing, a tick): it's no
  /// longer read on this page. (The mark is saved on the strokes
  /// themselves by [DocumentInkController.markNotWriting].)
  void markNotWriting(int page, RecognizedWord word) {
    _notWriting.putIfAbsent(page, () => {}).addAll(word.key.split(','));
    _log(
      LoggedEvent(
        type: 'not_writing',
        at: DateTime.now(),
        engine: engine.name,
        data: {'page': page, 'word': word.key, 'doc': ?documentId},
      ),
    );
    _words[page]?.remove(word.key);
    _notify();
  }

  final _notWriting = <int, Set<String>>{};

  static String _lastWord(String text) {
    final parts = text.trim().split(RegExp(r'\s+'));
    return parts.isEmpty ? '' : parts.last;
  }

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

  /// Reads [page] now (no pause) and waits until its words are ready, e.g.
  /// to make an export searchable (task 1.4b). Words already read and
  /// unchanged aren't sent to the engine again. Returns the page's words;
  /// none if the engine isn't set up (see [problem]).
  ///
  /// [stop] ends the wait early (e.g. the user cancelled).
  Future<List<RecognizedWord>> readNow(
    int page,
    List<PageStroke> strokes, {
    bool Function()? stop,
  }) async {
    _timers.remove(page)?.cancel();
    if (strokes.any(isWriting) && !_disposed) {
      _pending[page] = strokes;
      // Waits for this run without blocking on it, so a hung engine call
      // can't stop [stop] being checked.
      var finished = false;
      unawaited(_run(page).whenComplete(() => finished = true));
      while (!finished && !_disposed && !(stop?.call() ?? false)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      // A newer run may have been queued meanwhile; wait for that too.
      while (!_disposed &&
          !(stop?.call() ?? false) &&
          (_running.contains(page) ||
              _again.contains(page) ||
              _pending.containsKey(page))) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    return wordsOn(page);
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
      final flipped = _notWriting[page] ?? const <String>{};
      final plan = planRecognition(
        strokes,
        known,
        include: (i) =>
            !strokes[i].notWriting &&
            (i >= kinds.length || kinds[i] == InkKind.writing) &&
            (flipped.isEmpty || !flipped.contains(strokes[i].id)),
      );
      final before = words.length;
      words.removeWhere((key, _) => !plan.keys.contains(key));
      // Lines can be renumbered when a line is added above.
      for (var l = 0; l < plan.lines.length; l++) {
        for (final w in plan.lines[l].words) {
          final key = wordKey(strokes, w);
          final old = words[key];
          if (old != null && old.line != l) {
            words[key] = old.copyWith(line: l);
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
        final engineTexts = [
          for (final c in candidates)
            if (c.text.trim().isNotEmpty) c.text.trim(),
        ];
        if (engineTexts.isEmpty) continue;
        // The feedback layer (task 2.6) re-ranks or swaps using the user's
        // corrections.
        final previous = _lastWord(_textBefore(words, job));
        final fed = feedback.apply([
          for (final t in engineTexts) Candidate(t),
        ], FeedbackContext(previousWord: previous, documentId: documentId));
        final texts = [for (final c in fed.candidates) c.text];
        words[job.key] = RecognizedWord(
          text: texts.first,
          alternatives: texts.skip(1).toList(),
          box: job.word.box,
          line: job.line,
          key: job.key,
          engineText: engineTexts.first,
          autoReplaced: fed.autoReplaced,
          previousWord: previous,
          ink: ink,
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
                        // For the learning screen (task 3.1): what the
                        // engine read before the feedback layer, and which
                        // word this is, to match later corrections.
                        'engineText': engineTexts.first,
                        'autoReplaced': fed.autoReplaced,
                        'word': job.key,
                        'doc': ?documentId,
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
