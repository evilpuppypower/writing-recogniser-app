/// Colours on dark pages (owner's choice: reading comforts). Pure Dart, so
/// the export can use it too.
library;

/// An ink colour as shown on a dark page: the same hue with its lightness
/// turned round, so black ink shows white and dark blue shows light blue.
/// Transparency is kept.
int nightArgb(int argb) {
  final a = argb >> 24 & 0xFF;
  final r = (argb >> 16 & 0xFF) / 255;
  final g = (argb >> 8 & 0xFF) / 255;
  final b = (argb & 0xFF) / 255;
  final hi = [r, g, b].reduce((x, y) => x > y ? x : y);
  final lo = [r, g, b].reduce((x, y) => x < y ? x : y);
  final l = (hi + lo) / 2;
  final d = hi - lo;
  var h = 0.0, s = 0.0;
  if (d > 0) {
    s = d / (1 - (2 * l - 1).abs());
    if (hi == r) {
      h = ((g - b) / d) % 6;
    } else if (hi == g) {
      h = (b - r) / d + 2;
    } else {
      h = (r - g) / d + 4;
    }
    h *= 60;
  }
  // Back from hue, saturation and the turned-round lightness.
  final nl = 1 - l;
  final c = (1 - (2 * nl - 1).abs()) * s;
  final x = c * (1 - ((h / 60) % 2 - 1).abs());
  final m = nl - c / 2;
  final (r1, g1, b1) = switch (h) {
    < 60 => (c, x, 0.0),
    < 120 => (x, c, 0.0),
    < 180 => (0.0, c, x),
    < 240 => (0.0, x, c),
    < 300 => (x, 0.0, c),
    _ => (c, 0.0, x),
  };
  int byte(double v) => ((v + m) * 255).round().clamp(0, 255);
  return a << 24 | byte(r1) << 16 | byte(g1) << 8 | byte(b1);
}
