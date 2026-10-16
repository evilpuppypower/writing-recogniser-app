/// Learning how exact a shape must be before it's tidied (owner's approved
/// idea 8): when the user undoes or erases a tidied shape straight away a
/// second time, shapes of that kind were tidied too eagerly, so they must
/// be closer to a neat shape before they're tidied again; tidied shapes
/// that are kept bring it back a quarter of the way each. Pure Dart.
library;

import 'shapes.dart';

class ShapeLearning {
  /// How far off (a share of the shape's size, on average) a drawn shape
  /// can be and still be tidied, per kind.
  final _tolerance = <ShapeKind, double>{};

  /// Taken back since the last tightening, per kind (and how far off).
  final _takenBack = <ShapeKind, List<double>>{};

  /// Takings-back before shapes of a kind get stricter (one could be a
  /// slip).
  static const takeBacksToLearn = 2;

  /// The usual tolerance, and the strictest it gets.
  static const usual = 0.05, strictest = 0.015;

  /// Taken back within this long counts as "didn't want it tidied".
  static const rejectWithin = Duration(seconds: 20);

  double toleranceFor(ShapeKind kind) => _tolerance[kind] ?? usual;

  /// Whether a shape of [kind], [error] off, is tidied now.
  bool accepts(ShapeKind kind, double error) => error <= toleranceFor(kind);

  /// The user took back a tidied [kind] that was [error] off: shapes like
  /// it aren't tidied any more.
  void rejected(ShapeKind kind, double error) {
    final back = _takenBack.putIfAbsent(kind, () => [])..add(error);
    if (back.length < takeBacksToLearn) return;
    // Below the roughest of them, so none of those would be tidied again.
    final roughest = back.reduce((a, b) => a > b ? a : b);
    back.clear();
    final now = toleranceFor(kind);
    final next = (roughest * 0.9).clamp(strictest, usual);
    if (next < now) _tolerance[kind] = next;
  }

  /// A tidied [kind] was kept: a tenth of the way back to [usual].
  void kept(ShapeKind kind) {
    final now = toleranceFor(kind);
    if (now >= usual) return;
    _tolerance[kind] = now + (usual - now) * 0.25;
    _takenBack[kind]?.clear();
  }

  /// Back to the usual (Settings).
  void forget() {
    _tolerance.clear();
    _takenBack.clear();
  }

  /// Whether anything was learned.
  bool get learned => _tolerance.values.any((t) => t < usual);

  Map<String, double> toJson() => {
    for (final e in _tolerance.entries) e.key.name: e.value,
  };

  void load(Object? json) {
    _tolerance.clear();
    if (json is! Map) return;
    for (final k in ShapeKind.values) {
      final v = json[k.name];
      if (v is num && v.isFinite) {
        _tolerance[k] = v.toDouble().clamp(strictest, usual);
      }
    }
  }
}
