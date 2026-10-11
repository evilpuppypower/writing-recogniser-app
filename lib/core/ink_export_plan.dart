/// Turns saved strokes into simple lines to draw onto a PDF when exporting
/// (task 1.4). Pure Dart so it can be tested and reused on Windows; the
/// PDFium drawing lives in lib/export.
library;

import 'page_ink.dart';
import 'pen_tools.dart';

/// One polyline to draw: points in PDF page coordinates (x0, y0, x1, y1,
/// ...), one width and colour.
class ExportLine {
  const ExportLine({
    required this.points,
    required this.width,
    required this.colorArgb,
    this.highlighter = false,
  });

  final List<double> points;

  /// Width in PDF points.
  final double width;
  final int colorArgb;

  /// See-through and multiplied, so printed text stays readable.
  final bool highlighter;

  /// Alpha 0..255 as drawn (the highlighter is 40% opaque, as on screen).
  int get alpha => highlighter ? 102 : (colorArgb >> 24) & 0xFF;

  /// For sending to the PDFium worker isolate (plain data only).
  List<Object> toMessage() => [points, width, colorArgb, highlighter];

  static ExportLine fromMessage(List<Object?> m) => ExportLine(
    points: (m[0]! as List).cast<double>(),
    width: m[1]! as double,
    colorArgb: m[2]! as int,
    highlighter: m[3]! as bool,
  );
}

/// Widths are rounded to steps this small (PDF points) so a pressure-varying
/// pen stroke becomes a few lines rather than one per point.
const exportWidthStep = 0.1;

/// The lines for one page's [strokes]. Pen strokes follow pressure (scaled
/// as set in Settings, as on screen): runs of
/// points with the same rounded width become one line. Arrowheads become two
/// short lines.
List<ExportLine> exportLines(
  List<PageStroke> strokes, {
  PressureResponse pressure = const PressureResponse(),
}) {
  final out = <ExportLine>[];
  for (final s in strokes) {
    if (s.points.isEmpty) continue;
    final style = PenStyle(
      tool: s.tool,
      colorArgb: s.colorArgb,
      width: s.width,
      arrow: s.arrow,
    );
    final highlighter = s.tool == InkTool.highlighter;
    ExportLine line(List<double> pts, double w) => ExportLine(
      points: pts,
      width: w,
      colorArgb: s.colorArgb,
      highlighter: highlighter,
    );

    if (s.points.length == 1) {
      // A dot: a tiny line with round ends.
      final p = s.points.first;
      final w = _round(widthAtPressure(style, p.pressure, pressure));
      out.add(line([p.x, p.y, p.x + 0.01, p.y], w));
    } else if (highlighter) {
      out.add(
        line([
          for (final p in s.points) ...[p.x, p.y],
        ], s.width),
      );
    } else {
      // Split into runs of equal (rounded) width; consecutive runs share
      // their joining point so the line has no gaps.
      var run = <double>[s.points.first.x, s.points.first.y];
      double? runWidth;
      for (var i = 1; i < s.points.length; i++) {
        final a = s.points[i - 1], b = s.points[i];
        final w = _round(
          widthAtPressure(style, (a.pressure + b.pressure) / 2, pressure),
        );
        if (runWidth != null && w != runWidth) {
          out.add(line(run, runWidth));
          run = [a.x, a.y];
        }
        runWidth = w;
        run.addAll([b.x, b.y]);
      }
      out.add(line(run, runWidth!));
    }

    if (s.arrow && s.points.length > 1) {
      final tip = s.points.last;
      for (final (x, y) in arrowheadPoints(s.points, arrowheadSize(s.width))) {
        out.add(line([tip.x, tip.y, x, y], s.width));
      }
    }
  }
  return out;
}

double _round(double w) =>
    ((w / exportWidthStep).round() * exportWidthStep).clamp(0.1, 1000.0);
