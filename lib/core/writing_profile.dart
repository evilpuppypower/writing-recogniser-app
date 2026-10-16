/// The user's usual letter size and slant (owner's approved idea 6, and:
/// editable in Settings, with learning carrying on from what's set). Used
/// to read a page's first few words before it has enough writing to
/// measure, and to space "Lined to fit your writing". Pure Dart.
library;

import 'dart:math' as math;

import 'page_ink.dart';
import 'page_recognition.dart' show wordKey;
import 'stroke_grouping.dart' show InkLine;

class WritingProfile {
  WritingProfile({double? letterHeight, double? slantDegrees})
    : _letter = letterHeight,
      _slant = slantDegrees;

  double? _letter, _slant;
  int _lines = 0;

  /// When the user last set the values (ms since epoch; 0: never), so a
  /// PDF open meanwhile doesn't save over them.
  int setAt = 0;

  /// Usual letter height in points, once known.
  double? get letterHeight => _letter;

  /// Usual slant of the writing's lines, in degrees (anticlockwise from
  /// level), once known.
  double? get slantDegrees => _slant;

  /// Lines learned from so far.
  int get lines => _lines;

  /// Letter heights the app trusts, in points (about 1 to 25 mm).
  static const minLetter = 3.0, maxLetter = 70.0;

  /// Each line moves the usual values this much of the way, once a few
  /// lines are in (faster at first).
  static const _rate = 0.05;

  /// Learns from [found] (a page's lines): lines of at least 3 words,
  /// written within 30 degrees of level.
  void learn(Iterable<InkLine> found) {
    for (final l in found) {
      if (l.words.length < 3) continue;
      final deg = l.angle * 180 / math.pi;
      if (deg.abs() > 30) continue;
      if (l.letterHeight < minLetter || l.letterHeight > maxLetter) continue;
      _lines++;
      final rate = math.max(_rate, 1 / _lines);
      _letter = _letter == null
          ? l.letterHeight
          : _letter! + (l.letterHeight - _letter!) * rate;
      _slant = _slant == null ? deg : _slant! + (deg - _slant!) * rate;
    }
  }

  /// Set by the user (Settings): learning carries on from these.
  /// Learns from the lines of [strokes] with at least 3 words not learned
  /// from before ([seen]: word keys, added to), so a page read again and
  /// again counts once.
  void learnNew(
    List<PageStroke> strokes,
    Iterable<InkLine> found,
    Set<String> seen,
  ) {
    final fresh = <InkLine>[];
    for (final l in found) {
      final keys = [for (final w in l.words) wordKey(strokes, w)];
      if (keys.where((k) => !seen.contains(k)).length < 3) continue;
      seen.addAll(keys);
      fresh.add(l);
    }
    learn(fresh);
  }

  void set({double? letterHeight, double? slantDegrees}) {
    if (letterHeight != null) {
      _letter = letterHeight.clamp(minLetter, maxLetter);
    }
    if (slantDegrees != null) _slant = slantDegrees.clamp(-30.0, 30.0);
    // What's set counts like a good few lines, so it isn't swept away by
    // the next one.
    _lines = math.max(_lines, 20);
    setAt = DateTime.now().millisecondsSinceEpoch;
  }

  void forget() {
    _letter = null;
    _slant = null;
    _lines = 0;
    setAt = 0;
  }

  Map<String, Object?> toJson() => {
    if (_letter != null) 'letter': _letter,
    if (_slant != null) 'slant': _slant,
    'lines': _lines,
    if (setAt != 0) 'setAt': setAt,
  };

  void load(Object? j) {
    forget();
    if (j is! Map) return;
    final l = j['letter'], s = j['slant'], n = j['lines'];
    if (l is num && l.isFinite) {
      _letter = l.toDouble().clamp(minLetter, maxLetter);
    }
    if (s is num && s.isFinite) _slant = s.toDouble().clamp(-30.0, 30.0);
    if (n is int && n >= 0) _lines = n;
    final at = j['setAt'];
    if (at is int) setAt = at;
  }

  /// Where it's kept (SharedPreferences, as JSON).
  static const prefsKey = 'writing.profile';
}

/// Points to millimetres and back.
double pointsToMm(double pt) => pt / 72 * 25.4;
double mmToPoints(double mm) => mm / 25.4 * 72;
