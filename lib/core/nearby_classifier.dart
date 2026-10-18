/// Sorting writing from drawing without sending the whole page every time
/// (owner: "insane lag after writing 50 words"). An engine that sorts a
/// whole page at a time (MyScript's Raw Content) took longer with every
/// stroke, and each pause waited for it before reading the new word. Now
/// only new strokes, their lines and the ink around them are sent (see
/// [NearbyClassifier.nearby]); the rest keep the answer they had. Works with any classifier. Pure Dart.
library;

import 'dart:math' as math;

import 'ink_classifier.dart';
import 'page_ink.dart';
import 'printed_text.dart';
import 'stroke_grouping.dart';

class NearbyClassifier implements InkClassifier {
  NearbyClassifier(this.inner, {this.reach = 3, this.trusted});

  final InkClassifier inner;

  /// Whether [inner]'s last answer can be kept (an engine that hit an
  /// error and answered with a fallback says no): if not, those strokes
  /// are sorted again next time instead of keeping a stand-in answer.
  final bool Function()? trusted;

  /// How far round the new strokes is sorted again with them, in letter
  /// heights of their own line (a word finished, a stroke that turns a
  /// letter into a box).
  final double reach;

  /// Each stroke's last answer (a changed stroke is a new object, so it's
  /// sorted again).
  final _kinds = Expando<InkKind>();

  /// Stand-in answers (from a fallback, see [trusted]): used until the
  /// stroke is next sorted with new ink near it. They used to be dropped,
  /// so after a fallback every pause sorted the whole page again and
  /// writing slowed as the page filled (owner, 2026-10-18).
  final _standIn = Expando<InkKind>();

  /// How many strokes the last call sent to [inner], and whether its
  /// answer was a stand-in (for the diagnostic log).
  int lastSent = 0;
  bool lastFellBack = false;

  /// [printed]: the page's printed text, so lines are found as reading
  /// finds them (see groupStrokes).
  @override
  Future<List<InkKind>> classify(
    List<PageStroke> strokes, {
    PrintedText? printed,
  }) async {
    final fresh = [
      for (var i = 0; i < strokes.length; i++)
        if (_kinds[strokes[i]] == null &&
            _standIn[strokes[i]] == null &&
            strokes[i].points.isNotEmpty)
          i,
    ];
    lastSent = 0;
    lastFellBack = false;
    if (fresh.isEmpty) {
      return [
        for (final s in strokes) _kinds[s] ?? _standIn[s] ?? InkKind.writing,
      ];
    }
    // Mostly new (a page opened for the first time): the whole page.
    if (fresh.length * 2 >= strokes.length) {
      await _sort(strokes);
    } else {
      await _sort([
        for (final i in nearby(strokes, fresh, reach: reach, printed: printed))
          strokes[i],
      ]);
    }
    return [
      for (final s in strokes) _kinds[s] ?? _standIn[s] ?? InkKind.writing,
    ];
  }

  /// The strokes sorted again with the new ones ([fresh], indexes into
  /// [strokes]), in page order (owner: writing as small and as large as
  /// they please, around printed text): the new strokes, the whole of each
  /// line they're on (so a long sentence is never cut off), and ink within
  /// [reach] letters of them, measured in the letters of their own line
  /// (or the nearest line, for a stroke that isn't on one), so tiny margin
  /// notes and big writing each get a border their own size. Each new
  /// stroke gets its own border, so strokes far apart don't drag in the
  /// page between them.
  static List<int> nearby(
    List<PageStroke> strokes,
    List<int> fresh, {
    double reach = 3,
    PrintedText? printed,
  }) {
    final lines = groupStrokes(strokes, printed: printed);
    final lineOf = <int, int>{};
    for (var l = 0; l < lines.length; l++) {
      for (final w in lines[l].words) {
        for (final i in w.strokes) {
          lineOf[i] = l;
        }
      }
    }
    final boxes = [
      for (final s in strokes) s.points.isEmpty ? null : InkBox.of(s),
    ];
    final send = <int>{...fresh};
    final areas = <InkBox>[];
    final lineBoxes = [for (final l in lines) l.box];
    final pageLetter = typicalLetterHeight([for (final b in boxes) ?b]);
    for (final i in fresh) {
      final b = boxes[i];
      if (b == null) continue; // erased to nothing: no place on the page
      final l = lineOf[i];
      double letter;
      if (l != null) {
        letter = lines[l].letterHeight;
        for (final w in lines[l].words) {
          send.addAll(w.strokes);
        }
      } else {
        letter = pageLetter;
        var nearest = double.infinity;
        for (var k = 0; k < lines.length; k++) {
          final d = _distance(b, lineBoxes[k]);
          if (d < nearest) {
            nearest = d;
            letter = lines[k].letterHeight;
          }
        }
      }
      final m = letter * reach;
      areas.add(InkBox(b.left - m, b.bottom - m, b.right + m, b.top + m));
    }
    for (var i = 0; i < strokes.length; i++) {
      final b = boxes[i];
      if (b == null || send.contains(i)) continue;
      for (final a in areas) {
        if (_overlaps(b, a)) {
          send.add(i);
          break;
        }
      }
    }
    return send.toList()..sort();
  }

  static double _distance(InkBox a, InkBox b) {
    final dx = math.max(0.0, a.horizontalGap(b));
    final dy = math.max(
      0.0,
      math.max(a.bottom, b.bottom) - math.min(a.top, b.top),
    );
    return math.sqrt(dx * dx + dy * dy);
  }

  Future<void> _sort(List<PageStroke> strokes) async {
    lastSent = strokes.length;
    final kinds = await inner.classify(strokes);
    final kept = trusted?.call() ?? true;
    lastFellBack = !kept;
    for (var i = 0; i < strokes.length && i < kinds.length; i++) {
      if (kept) {
        _kinds[strokes[i]] = kinds[i];
        _standIn[strokes[i]] = null;
      } else if (_kinds[strokes[i]] == null) {
        // Sorted again (by [inner]) only when new ink comes near it.
        _standIn[strokes[i]] = kinds[i];
      }
    }
  }

  static bool _overlaps(InkBox a, InkBox b) =>
      a.left <= b.right &&
      a.right >= b.left &&
      a.bottom <= b.top &&
      a.top >= b.bottom;
}

/// Reading times after pauses, gathered into one diagnostic entry every
/// [every] reads (sizes and times only), so the log doesn't grow by one
/// entry per pause.
class ReadSummary {
  ReadSummary({this.every = 20});

  final int every;
  final _total = <int>[], _sort = <int>[];
  int _strokes = 0, _sorted = 0, _calls = 0, _queued = 0, _fellBack = 0;
  String? _problem;

  /// Adds one read's timings (see InkTextController.onRead); returns the
  /// summary to log once [every] reads are in, else null.
  Map<String, Object?>? add(Map<String, Object?> t) {
    _total.add((t['totalMs'] as int?) ?? 0);
    _sort.add((t['sortMs'] as int?) ?? 0);
    _strokes = (t['strokes'] as int?) ?? _strokes;
    _sorted = _sorted > ((t['sorted'] as int?) ?? 0)
        ? _sorted
        : (t['sorted'] as int?) ?? 0;
    _calls += (t['engineCalls'] as int?) ?? 0;
    if (t['queued'] == true) _queued++;
    if (t['fellBack'] == true) _fellBack++;
    _problem = (t['sortProblem'] as String?) ?? _problem;
    if (_total.length < every) return null;
    int median(List<int> v) => ([...v]..sort())[v.length ~/ 2];
    int worst(List<int> v) => v.reduce((a, b) => a > b ? a : b);
    final out = {
      'reads': _total.length,
      'medianMs': median(_total),
      'worstMs': worst(_total),
      'medianSortMs': median(_sort),
      'worstSortMs': worst(_sort),
      'mostSorted': _sorted,
      'strokesOnPage': _strokes,
      'engineCalls': _calls,
      'queued': _queued,
      // Reads where the writing/drawing sorter fell back to the shape
      // check, and why (an error message, no words or ink).
      if (_fellBack > 0) 'fellBack': _fellBack,
      if (_fellBack > 0 && _problem != null) 'sortProblem': _problem,
    };
    _total.clear();
    _sort.clear();
    _sorted = _calls = _queued = _fellBack = 0;
    _problem = null;
    return out;
  }
}
