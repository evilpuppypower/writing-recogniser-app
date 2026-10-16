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
      if (l.words.length < 3 || !l.measured) continue;
      // A line written at a slant knows its angle; a nearly level one is
      // measured from where its words sit.
      final deg = (l.angle != 0 ? l.angle : _baseline(l)) * 180 / math.pi;
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
  /// The slope of the line through the feet of [l]'s words (radians).
  static double _baseline(InkLine l) {
    final xs = [for (final w in l.words) (w.box.left + w.box.right) / 2];
    final ys = [for (final w in l.words) w.box.bottom];
    final n = xs.length;
    final mx = xs.reduce((a, b) => a + b) / n;
    final my = ys.reduce((a, b) => a + b) / n;
    var sxy = 0.0, sxx = 0.0;
    for (var i = 0; i < n; i++) {
      sxy += (xs[i] - mx) * (ys[i] - my);
      sxx += (xs[i] - mx) * (xs[i] - mx);
    }
    return sxx == 0 ? 0 : math.atan(sxy / sxx);
  }

  /// The words learned from already (a short fingerprint of each word's
  /// strokes, the newest [_keepSeen]), kept with the profile so a page
  /// read again, even after reopening, counts once.
  final _seen = <int>{};
  static const _keepSeen = 5000;

  static int _fingerprint(String key) {
    var h = 0x811c9dc5;
    for (final c in key.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF;
    }
    return h;
  }

  /// Learns from the lines of [strokes] with at least 3 words not learned
  /// from before.
  void learnNew(List<PageStroke> strokes, Iterable<InkLine> found) {
    final fresh = <InkLine>[];
    for (final l in found) {
      // Assumed sizes teach nothing, and the line is learned once measured.
      if (!l.measured) continue;
      final keys = [for (final w in l.words) _fingerprint(wordKey(strokes, w))];
      if (keys.where((k) => !_seen.contains(k)).length < 3) continue;
      _seen.addAll(keys);
      fresh.add(l);
    }
    while (_seen.length > _keepSeen) {
      _seen.remove(_seen.first);
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
    _clear();
    // A PDF open meanwhile mustn't save the old values back.
    setAt = DateTime.now().millisecondsSinceEpoch;
  }

  void _clear() {
    _letter = null;
    _slant = null;
    _lines = 0;
    setAt = 0;
    _seen.clear();
  }

  Map<String, Object?> toJson() => {
    if (_letter != null) 'letter': _letter,
    if (_slant != null) 'slant': _slant,
    'lines': _lines,
    if (setAt != 0) 'setAt': setAt,
    'seen': _seen.toList(),
  };

  void load(Object? j) {
    _clear();
    if (j is! Map) return;
    final l = j['letter'], s = j['slant'], n = j['lines'];
    if (l is num && l.isFinite) {
      _letter = l.toDouble().clamp(minLetter, maxLetter);
    }
    if (s is num && s.isFinite) _slant = s.toDouble().clamp(-30.0, 30.0);
    if (n is int && n >= 0) _lines = n;
    final at = j['setAt'];
    if (at is int) setAt = at;
    final seen = j['seen'];
    if (seen is List) _seen.addAll(seen.whereType<int>());
  }

  /// Where it's kept (SharedPreferences, as JSON).
  static const prefsKey = 'writing.profile';
}

/// Points to millimetres and back.
double pointsToMm(double pt) => pt / 72 * 25.4;
double mmToPoints(double mm) => mm / 25.4 * 72;
