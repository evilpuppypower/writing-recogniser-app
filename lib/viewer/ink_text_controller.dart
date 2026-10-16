import 'dart:async';
import 'dart:math' as math;
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/event_log.dart';
import '../core/feedback/correction.dart';
import '../core/feedback/correction_store.dart';
import '../core/feedback/feedback_layer.dart';
import '../core/feedback/personal_words.dart';
import '../core/feedback/vocabulary.dart';
import '../core/ink.dart';
import '../core/ink_classifier.dart';
import '../core/nearby_classifier.dart';
import '../core/personal_ink_kinds.dart';
import '../core/printed_text.dart';
import '../core/page_ink.dart';
import '../core/page_recognition.dart';
import '../core/recognition/recognizer.dart';
import '../core/stroke_grouping.dart';
import '../core/typed_text.dart';

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
    this.engineReadings,
    this.slant,
    this.byLine = false,
    this.unsure = false,
    this.fromYourWords = false,
  });

  /// Worth asking the user about (owner's approved idea 3): shown with a
  /// "?" until they correct it or say it's right.
  final bool unsure;

  /// Swapped automatically to a word the user often writes (rather than
  /// from an earlier correction).
  final bool fromYourWords;

  /// Found by an engine reading its whole line (so its strokes are the
  /// engine's word, kept as it split them).
  final bool byLine;

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

  /// What the engine itself offered, best first, before the feedback layer
  /// and never changed by corrections (for training a model to pick among
  /// them, task 4.2). Null for words saved before this was kept.
  final List<String>? engineReadings;

  /// Set when the word is written at a slant (its label follows it).
  final Slant? slant;

  String get engineReading => engineText ?? text;

  /// Saved with the ink (see [InkTextController.restore]).
  Map<String, Object?> toJson() => {
    'text': text,
    'alt': alternatives,
    'box': [box.left, box.bottom, box.right, box.top],
    'line': line,
    'key': key,
    'engine': ?engineText,
    if (autoReplaced) 'auto': true,
    if (corrected) 'corrected': true,
    if (previousWord.isNotEmpty) 'prev': previousWord,
    'ink': [for (final s in ink) s.toJson()],
    'readings': ?engineReadings,
    if (byLine) 'byLine': true,
    if (unsure) 'unsure': true,
    if (fromYourWords) 'yours': true,
    if (slant case final s?)
      'slant': [
        s.angle,
        s.cx,
        s.cy,
        s.box.left,
        s.box.bottom,
        s.box.right,
        s.box.top,
      ],
  };

  factory RecognizedWord.fromJson(Map<String, Object?> j) {
    final b = [for (final v in j['box']! as List) (v as num).toDouble()];
    return RecognizedWord(
      text: j['text']! as String,
      alternatives: [for (final a in j['alt'] as List? ?? const []) '$a'],
      box: InkBox(b[0], b[1], b[2], b[3]),
      line: (j['line'] as num?)?.toInt() ?? 0,
      key: j['key'] as String? ?? '',
      engineText: j['engine'] as String?,
      autoReplaced: j['auto'] == true,
      corrected: j['corrected'] == true,
      previousWord: j['prev'] as String? ?? '',
      ink: [
        for (final s in j['ink'] as List? ?? const [])
          InkStroke.fromJson(s as List),
      ],
      engineReadings: switch (j['readings']) {
        final List r => [for (final x in r) '$x'],
        _ => null,
      },
      byLine: j['byLine'] == true,
      unsure: j['unsure'] == true,
      fromYourWords: j['yours'] == true,
      slant: switch (j['slant']) {
        final List v when v.length == 7 => () {
          final n = [for (final x in v) (x as num).toDouble()];
          return (
            angle: n[0],
            cx: n[1],
            cy: n[2],
            box: InkBox(n[3], n[4], n[5], n[6]),
          );
        }(),
        _ => null,
      },
    );
  }

  RecognizedWord copyWith({
    String? text,
    List<String>? alternatives,
    int? line,
    InkBox? box,
    bool? autoReplaced,
    bool? corrected,
    bool? unsure,
    Object? slant = _keep,
  }) => RecognizedWord(
    text: text ?? this.text,
    alternatives: alternatives ?? this.alternatives,
    box: box ?? this.box,
    line: line ?? this.line,
    key: key,
    engineText: engineText,
    autoReplaced: autoReplaced ?? this.autoReplaced,
    corrected: corrected ?? this.corrected,
    previousWord: previousWord,
    ink: ink,
    engineReadings: engineReadings,
    slant: identical(slant, _keep) ? this.slant : slant as Slant?,
    byLine: byLine,
    unsure: unsure ?? this.unsure,
    fromYourWords: (autoReplaced ?? this.autoReplaced) && fromYourWords,
  );
}

const _keep = Object();

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
  }) : feedback = feedback ?? PersonalWords();

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

  /// Teaches the feedback layer the user's vocabulary: every word kept on
  /// their pages ([pages]: saved page text, as [pageJson] makes it), in
  /// every PDF (see [vocabularyFromPages]).
  void loadVocabulary(Iterable<String> pages) =>
      _useVocabulary(vocabularyFromPages(pages.toList()));

  /// As [loadVocabulary], with the words still being read (away from the
  /// screen's thread): new writing is read once they're in, so it gets the
  /// user's words from the start.
  void loadVocabularyLater(Future<List<UsedWord>> words) {
    final loading = words.then(_useVocabulary, onError: (_) {});
    _vocabulary = loading;
    loading.whenComplete(() {
      if (identical(_vocabulary, loading)) _vocabulary = null;
    });
  }

  /// The vocabulary still being read (null once it's in, or if none is).
  Future<void>? _vocabulary;

  void _useVocabulary(List<UsedWord> words) {
    for (final w in words) {
      feedback.used(w.word, previousWord: w.previous);
    }
  }

  /// The user says [word] on [page] was read right (it was shown with a
  /// "?"): no more "?", and the word is one they write from now on. Logged
  /// as an accept (rule 5).
  void confirm(int page, RecognizedWord word) {
    final words = _words[page];
    // As it is now (it may have moved or been read again since the pop-up
    // opened); nothing to confirm if it now reads differently.
    final now = words?[word.key];
    if (words == null || now == null || now.text != word.text) return;
    words[word.key] = now.copyWith(unsure: false);
    _notify();
    _wordsChanged(page);
    feedback.used(word.text, previousWord: word.previousWord);
    unawaited(
      eventLog
              ?.log(
                LoggedEvent(
                  type: 'accept',
                  at: DateTime.now(),
                  engine: engine.name,
                  data: {'page': page, 'text': word.text, 'asked': true},
                ),
              )
              .catchError((_) {}) ??
          Future.value(),
    );
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
      unsure: false,
    );
    _notify();
    _wordsChanged(page);
    final undo = t == word.engineReading; // undoing a swap
    if (undo) {
      // Never swapped that way again.
      if (word.autoReplaced) feedback.undone(word.engineReading, word.text);
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
    _wordsChanged(page);
  }

  final _notWriting = <int, Set<String>>{};

  /// Reverses [markNotWriting] for the strokes [strokeIds] on [page]
  /// (task 2.4d): they're read again once the ink is next looked at. (The
  /// strokes themselves are unmarked by [DocumentInkController.markWriting],
  /// which also triggers that reading.)
  void markWriting(int page, Set<String> strokeIds) {
    _notWriting[page]?.removeAll(strokeIds);
    _log(
      LoggedEvent(
        type: 'is_writing',
        at: DateTime.now(),
        engine: engine.name,
        data: {
          'page': page,
          'word': (strokeIds.toList()..sort()).join(','),
          'doc': ?documentId,
        },
      ),
    );
    _notify();
  }

  static bool _sameBox(InkBox a, InkBox b) =>
      a.left == b.left &&
      a.bottom == b.bottom &&
      a.right == b.right &&
      a.top == b.top;

  static bool _sameSlant(Slant? a, Slant? b) => a == null || b == null
      ? a == b
      : a.angle == b.angle &&
            a.cx == b.cx &&
            a.cy == b.cy &&
            _sameBox(a.box, b.box);

  static bool _slantChanged(Slant? a, Slant? b) => a == null || b == null
      ? (a == null) != (b == null)
      : _turnBetween(a.angle, b.angle) > 3 * math.pi / 180;

  /// The turn from one direction to another (radians, 0..pi): writing at
  /// 179 degrees and at -179 degrees is only 2 degrees apart.
  static double _turnBetween(double a, double b) {
    final d = (a - b).abs() % (2 * math.pi);
    return math.min(d, 2 * math.pi - d);
  }

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

  /// Lines (their word keys) an engine couldn't read whole this session,
  /// so they aren't sent whole again until they change.
  final _lineFailed = <String>{};

  final _words = <int, Map<String, RecognizedWord>>{};
  final _timers = <int, Timer>{};
  final _running = <int>{};
  final _again = <int>{};
  final _pending = <int, List<PageStroke>>{};
  bool? _ready;
  bool _disposed = false;

  /// Why recognition isn't running (e.g. MyScript keys missing), if so.
  String? problem;

  /// Called when a page's words change (read, corrected, marked), so they
  /// can be saved with the ink.
  void Function(int page)? onWordsChanged;

  /// Puts back [page]'s words saved earlier ([pageJson]), before its ink is
  /// looked at, so only new or changed handwriting is read again (owner's
  /// report: reopening a PDF read everything again). [ensure] still checks
  /// them against the ink (see [upToDate]). Unreadable saved text is
  /// ignored: the page is simply read again.
  void restore(int page, String json) {
    try {
      final saved = (jsonDecode(json) as Map).cast<String, Object?>();
      final words = {
        for (final w in saved['words']! as List)
          if (RecognizedWord.fromJson((w as Map).cast<String, Object?>())
              case final word when word.key.isNotEmpty)
            word.key: word,
      };
      final seen = {for (final id in saved['seen'] as List? ?? const []) '$id'};
      _words[page] = words;
      _seen[page] = seen;
      _notify();
    } catch (_) {
      // Read again instead.
    }
  }

  /// [page]'s words as JSON, to save, with the strokes they were read from;
  /// null when there is nothing to keep.
  String? pageJson(int page) {
    final words = _words[page] ?? const {};
    final seen = _seen[page] ?? const <String>{};
    if (words.isEmpty && seen.isEmpty) return null;
    return jsonEncode({
      'seen': seen.toList(),
      'words': [for (final w in words.values) w.toJson()],
    });
  }

  /// The stroke ids of each page when it was last read in full, to tell
  /// whether its words still match its ink.
  final _seen = <int, Set<String>>{};

  /// Whether [page]'s words were read from exactly these [strokes] (so
  /// there's nothing new to read or to drop).
  bool upToDate(int page, List<PageStroke> strokes) {
    final seen = _seen[page];
    return seen != null &&
        seen.length == strokes.length &&
        strokes.every((s) => seen.contains(s.id));
  }

  void _wordsChanged(int page) {
    if (!_disposed) onWordsChanged?.call(page);
  }

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
    if (_pending.containsKey(page)) return;
    // Read already (this time, or saved from before): only if the ink has
    // changed since, e.g. the PDF closed before a pause ended.
    if (_words.containsKey(page) && upToDate(page, strokes)) return;
    if (!strokes.any(isWriting) && (_words[page]?.isEmpty ?? true)) return;
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
    if (strokes == null) return;
    // Words whose strokes are gone (erased) go at once, even if the engine
    // isn't ready to read anything new.
    final ids = {for (final s in strokes) s.id};
    final current = _words[page];
    if (current != null) {
      final before = current.length;
      current.removeWhere(
        (k, _) => k.split(',').any((id) => !ids.contains(id)),
      );
      if (current.length != before) {
        _notify();
        _wordsChanged(page);
      }
    }
    if (!await _isReady() || _disposed) return;
    final vocabulary = _vocabulary;
    if (vocabulary != null) {
      await vocabulary;
      if (_disposed) return;
    }
    _running.add(page);
    final watch = Stopwatch()..start();
    var sortMs = 0, engineCalls = 0;
    var dirty = false;
    var complete = true; // every word was read (none failed)
    try {
      final words = _words.putIfAbsent(page, () => {});
      final known = {for (final e in words.entries) e.key: e.value.text};
      // Text boxes aren't ink: never sent to be sorted (they're drawings
      // as far as reading goes).
      final inkOnly = [
        for (var i = 0; i < strokes.length; i++)
          if (!strokes[i].isTextBox) i,
      ];
      final printed = printedText?.call(page);
      final c = classifier;
      final ink = [for (final i in inkOnly) strokes[i]];
      final sorted = c is NearbyClassifier
          ? await c.classify(ink, printed: printed)
          : await c.classify(ink);
      sortMs = watch.elapsedMilliseconds;
      final allKinds = List.filled(strokes.length, InkKind.drawing);
      for (var k = 0; k < inkOnly.length && k < sorted.length; k++) {
        allKinds[inkOnly[k]] = sorted[k];
      }
      // The user's own marks teach what they draw and what they write
      // (owner's approved idea 7).
      final mine = personalKinds?.apply(strokes, allKinds) ?? allKinds;
      final kinds = reconcileKinds(
        strokes,
        mine,
        // Already the shape check's answer: not worked out twice (it's the
        // slowest step on a heavily written page).
        shape:
            classifier is ShapeInkClassifier && inkOnly.length == strokes.length
            ? allKinds
            : null,
      );
      if (_disposed) return;
      final flipped = _notWriting[page] ?? const <String>{};
      final lineEngine = engine is LineRecognizer
          ? engine as LineRecognizer
          : null;
      final plan = planRecognition(
        strokes,
        known,
        printed: printed,
        params: GroupingParams(usualLetter: usualLetter),
        // With an engine that reads whole lines, its words stay as it split
        // them (each word's key lists its strokes).
        hints: lineEngine == null
            ? null
            : {
                for (final w in words.values)
                  if (w.byLine)
                    for (final id in w.key.split(',')) id: w.key,
              },
        // Lines read word by word before (e.g. by an older version) are
        // read once more as a whole, unless the user corrected a word on
        // them.
        lineNeedsReading: lineEngine == null
            ? null
            : (keys) {
                if (_lineFailed.contains(keys.join('|'))) return false;
                final ws = [for (final k in keys) ?words[k]];
                return ws.any((w) => !w.byLine) && !ws.any((w) => w.corrected);
              },
        include: (i) =>
            !strokes[i].notWriting &&
            (i >= kinds.length || kinds[i] == InkKind.writing) &&
            (flipped.isEmpty || !flipped.contains(strokes[i].id)),
        // Read tilted before its slant was noticed (or at another slant):
        // read again level, unless the user corrected it.
        reread: (key, w) {
          final old = words[key];
          return old != null &&
              !old.corrected &&
              _slantChanged(old.slant, w.slant);
        },
      );
      final before = words.length;
      onLines?.call(strokes, plan.lines);
      words.removeWhere((key, _) => !plan.keys.contains(key));
      // Lines can be renumbered when a line is added above.
      for (var l = 0; l < plan.lines.length; l++) {
        for (final w in plan.lines[l].words) {
          final key = wordKey(strokes, w);
          final old = words[key];
          // Lines renumbered, or the word moved (Select tool): same
          // strokes, so the same text, in its new place.
          if (old != null &&
              (old.line != l ||
                  !_sameBox(old.box, w.box) ||
                  !_sameSlant(old.slant, w.slant))) {
            words[key] = old.copyWith(line: l, box: w.box, slant: w.slant);
            dirty = true;
          }
        }
      }
      if (words.length != before || dirty) {
        dirty = true;
        _notify();
      }
      // Whole lines, for an engine that reads them and splits them into
      // words itself (owner, 2026-10-15); a line it can't read this way is
      // read word by word below.
      final readLines = <int>{};
      for (final job
          in lineEngine == null ? const <LineJob>[] : plan.lineJobs) {
        if (_disposed) return;
        final line = plan.lines[job.line];
        final all = lineAsWord(strokes, line);
        final scale = engineLetterPixels / job.letterHeight;
        final ink = wordInk(strokes, all, scale: scale);
        final sent = DateTime.now().millisecondsSinceEpoch;
        List<LineWord>? got;
        try {
          engineCalls++;
          got = await lineEngine!.recognizeLine(
            ink,
            RecognitionContext(
              preContext: job.preContext,
              writingAreaWidth: (all.slant?.box ?? all.box).width * scale,
              writingAreaHeight: (all.slant?.box ?? all.box).height * scale,
            ),
          );
        } on RecognitionException catch (e) {
          complete = false;
          problem = e.message;
          _notify();
          readLines.add(job.line);
          continue;
        }
        if (_disposed) return;
        // Only sound answers: every word with a reading and strokes of
        // this line, and every stroke in one word.
        final usable = [
          for (final g in got ?? const <LineWord>[])
            if (g.candidates.any((c) => c.trim().isNotEmpty) &&
                g.strokes.isNotEmpty &&
                g.strokes.every((k) => k >= 0 && k < all.strokes.length))
              g,
        ];
        final covered = {for (final g in usable) ...g.strokes};
        if (usable.isEmpty || covered.length != all.strokes.length) {
          // Not this way (this session): its words are read one by one.
          _lineFailed.add(
            [for (final w in line.words) wordKey(strokes, w)].join('|'),
          );
          continue;
        }
        final found = _withManualWords(strokes, [
          for (final g in usable)
            (
              readings: [
                for (final c in g.candidates)
                  if (c.trim().isNotEmpty) c.trim(),
              ],
              strokes: [for (final k in g.strokes.toSet()) all.strokes[k]],
            ),
        ]);
        final slant = all.slant;
        final lineIds = {for (final k in all.strokes) strokes[k].id};
        final keep = <String>{};
        for (final f in found) {
          final w = wordOfStrokes(
            strokes,
            f.strokes,
            slant: slant == null
                ? null
                : (angle: slant.angle, cx: slant.cx, cy: slant.cy),
          );
          final key = wordKey(strokes, w);
          keep.add(key);
          final old = words[key];
          if (old != null) {
            // The same strokes as a word already read (perhaps corrected
            // by the user): it stays as it is, now marked as the engine's.
            words[key] = RecognizedWord.fromJson({
              ...old.toJson(),
              'byLine': true,
            }).copyWith(line: job.line, box: w.box, slant: w.slant);
            continue;
          }
          _keep(
            page,
            words,
            key: key,
            word: w,
            line: job.line,
            engineTexts: f.readings,
            ink: wordInk(strokes, w, scale: scale),
            sent: sent,
            byLine: true,
          );
        }
        // The line's other old words go.
        words.removeWhere(
          (key, _) =>
              !keep.contains(key) && key.split(',').any(lineIds.contains),
        );
        readLines.add(job.line);
        dirty = true;
      }
      for (final job in plan.jobs) {
        if (_disposed) return;
        if (readLines.contains(job.line)) continue;
        final scale = engineLetterPixels / job.letterHeight;
        final ink = wordInk(strokes, job.word, scale: scale);
        final sent = DateTime.now().millisecondsSinceEpoch;
        List<Candidate> candidates;
        try {
          engineCalls++;
          candidates = await engine.recognize(
            ink,
            RecognitionContext(
              // Includes words recognised earlier in this same run.
              preContext: _textBefore(words, job.line, job.word.box.left),
              writingAreaWidth:
                  (job.word.slant?.box ?? job.word.box).width * scale,
              writingAreaHeight:
                  (job.word.slant?.box ?? job.word.box).height * scale,
            ),
          );
        } on RecognitionException catch (e) {
          complete = false;
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
        _keep(
          page,
          words,
          key: job.key,
          word: job.word,
          line: job.line,
          engineTexts: engineTexts,
          ink: ink,
          sent: sent,
        );
        dirty = true;
      }
    } finally {
      _running.remove(page);
      if (complete && !_disposed) {
        final seen = {for (final s in strokes) s.id};
        if (!setEquals(seen, _seen[page])) dirty = true;
        _seen[page] = seen;
      }
      if (dirty) _wordsChanged(page);
      final c = classifier;
      onRead?.call({
        'strokes': strokes.length,
        'sortMs': sortMs,
        if (c is NearbyClassifier) 'sorted': c.lastSent,
        'engineCalls': engineCalls,
        'totalMs': watch.elapsedMilliseconds,
        'queued': _again.contains(page),
      });
      if (_again.remove(page) && !_disposed) unawaited(_run(page));
    }
  }

  /// What this user draws and writes, learned from their marks (null: not
  /// used).
  PersonalInkKinds? personalKinds;

  /// Where each page's printed text sits (page number -> text), so
  /// writing around it is grouped and read as written (see PrintedText).
  /// Null, or none for a page: grouped from the ink alone.
  PrintedText? Function(int page)? printedText;

  /// Told how long each read took after a pause (sizes and times only),
  /// for the diagnostic report.
  void Function(Map<String, Object?> timings)? onRead;

  /// The lines of handwriting found on a page each time it's read (to
  /// learn the user's usual size and slant, see WritingProfile).
  void Function(List<PageStroke> strokes, List<InkLine> lines)? onLines;

  /// The user's usual letter height in points, for pages with little
  /// writing yet (see GroupingParams.usualLetter).
  double? usualLetter;

  /// Keeps what the engine read for [word] (after the feedback layer,
  /// task 2.6, re-ranks or swaps it using the user's corrections), and logs
  /// it (rule 5).
  void _keep(
    int page,
    Map<String, RecognizedWord> words, {
    required String key,
    required InkWord word,
    required int line,
    required List<String> engineTexts,
    required List<InkStroke> ink,
    required int sent,
    bool byLine = false,
  }) {
    final previous = _lastWord(_textBefore(words, line, word.box.left));
    final fed = feedback.apply([
      for (final t in engineTexts) Candidate(t),
    ], FeedbackContext(previousWord: previous, documentId: documentId));
    final texts = [for (final c in fed.candidates) c.text];
    words[key] = RecognizedWord(
      text: texts.first,
      alternatives: texts.skip(1).toList(),
      box: word.box,
      slant: word.slant,
      line: line,
      key: key,
      engineText: engineTexts.first,
      engineReadings: engineTexts,
      autoReplaced: fed.autoReplaced,
      fromYourWords: fed.fromYourWords,
      unsure: fed.unsure,
      previousWord: previous,
      ink: ink,
      byLine: byLine,
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
                  // Pen lift to text, only for writing done just now (not
                  // ink read again when a PDF is reopened).
                  latencyMs: now - word.end < 60000 ? now - word.end : null,
                  data: {
                    'source': 'pdf',
                    'page': page,
                    'text': texts.first,
                    'alternatives': texts.skip(1).take(4).toList(),
                    'engineMs': now - sent,
                    // For the learning screen (task 3.1): what the engine
                    // read before the feedback layer, and which word this
                    // is, to match later corrections.
                    'engineText': engineTexts.first,
                    'autoReplaced': fed.autoReplaced,
                    'word': key,
                    'doc': ?documentId,
                  },
                ),
              )
              .catchError((_) {}) ??
          Future<void>.value(),
    );
  }

  /// The engine's words with strokes the user marked "One word" kept
  /// together: words sharing such strokes become one, their readings
  /// joined.
  static List<({List<String> readings, List<int> strokes})> _withManualWords(
    List<PageStroke> strokes,
    List<({List<String> readings, List<int> strokes})> found,
  ) {
    final into = List<int>.generate(found.length, (k) => k);
    int root(int k) => into[k] == k ? k : into[k] = root(into[k]);
    final firstWith = <String, int>{};
    for (var k = 0; k < found.length; k++) {
      for (final i in found[k].strokes) {
        final mark = strokes[i].manualWord;
        if (mark == null) continue;
        final other = firstWith.putIfAbsent(mark, () => k);
        if (root(other) != root(k)) into[root(k)] = root(other);
      }
    }
    final merged = <int, ({List<String> readings, List<int> strokes})>{};
    for (var k = 0; k < found.length; k++) {
      final r = root(k);
      final had = merged[r];
      merged[r] = had == null
          ? found[k]
          : (
              readings: ['${had.readings.first}${found[k].readings.first}'],
              strokes: [...had.strokes, ...found[k].strokes],
            );
    }
    return merged.values.toList();
  }

  static String _textBefore(
    Map<String, RecognizedWord> words,
    int line,
    double left,
  ) {
    final before =
        [
          for (final w in words.values)
            if (w.line < line || (w.line == line && w.box.left < left)) w,
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

/// What converting [words] stores (owner's choice F1): one piece of typed
/// text per line of handwriting, its words left to right, keyed by all
/// their strokes' ids.
Map<Set<String>, String> typedTextByLine(List<RecognizedWord> words) {
  final byLine = <int, List<RecognizedWord>>{};
  for (final w in words) {
    if (w.key.isNotEmpty && w.text.trim().isNotEmpty) {
      byLine.putIfAbsent(w.line, () => []).add(w);
    }
  }
  return {
    for (final line in byLine.values)
      {
        for (final w in line) ...w.key.split(','),
      }: (line..sort((a, b) => a.box.left.compareTo(b.box.left)))
          .map((w) => w.text.trim())
          .join(' '),
  };
}

/// A copy of [ink] with the handwriting on [pages] that isn't converted
/// yet converted too, from the words read there ([wordsOn]), one piece per
/// line (owner's choice 1b: "Also convert handwriting I haven't converted"
/// at export). [ink] itself is left as it is.
DocumentInk inkWithRestConverted(
  DocumentInk ink,
  Iterable<int> pages,
  List<RecognizedWord> Function(int page) wordsOn,
) {
  final copy = DocumentInk();
  for (final p in ink.pagesWithInk) {
    copy.setPage(p, ink.strokesOn(p));
  }
  for (final p in pages) {
    final done = convertedStrokeIds(ink.strokesOn(p));
    copy.convert(
      p,
      typedTextByLine([
        // A word with any converted stroke is left as it is: converting
        // the rest of it would repeat the converted part's text.
        for (final w in wordsOn(p))
          if (!w.key.split(',').any(done.contains)) w,
      ]),
    );
  }
  return copy;
}
