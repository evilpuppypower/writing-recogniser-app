/// How pen pressure changes line thickness. Pure Dart; shared by the PDF
/// pen, the export and the handwriting boxes so they all agree.
library;

class PressureResponse {
  const PressureResponse({this.strength = 1, this.range = defaultRange});

  /// Lines keep the same thickness whatever the pressure.
  static const none = PressureResponse(strength: 0);

  /// Pressing hardest at full strength makes a line 40% thicker and
  /// pressing lightest 40% thinner (60%..140%).
  static const defaultRange = 0.4;

  /// The thinnest a line can get, as a share of its set width.
  static const thinnest = 0.1;

  /// How much of the effect to use, 0..1 (the "How much" slider).
  final double strength;

  /// How far the thickness can change at full strength: hardest press is
  /// (1 + range) times the set width, lightest is (1 - range) times it but
  /// never below [thinnest].
  final double range;

  /// Multiply the set width by this at [pressure] (0..1; 0.5 is normal).
  double factor(double pressure) {
    final s = strength.clamp(0.0, 1.0) * range.clamp(0.0, 10.0);
    final d = 2 * (pressure.clamp(0.0, 1.0) - 0.5); // -1 light .. 1 hard
    return d >= 0 ? 1 + s * d : 1 + (s < 1 - thinnest ? s : 1 - thinnest) * d;
  }

  @override
  bool operator ==(Object other) =>
      other is PressureResponse &&
      other.strength == strength &&
      other.range == range;

  @override
  int get hashCode => Object.hash(strength, range);
}
