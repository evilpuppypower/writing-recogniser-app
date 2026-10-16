/// What's printed on a blank page's paper (owner's choice: plain, lined,
/// squared, dotted, and lined to fit the user's writing). Drawn by the app
/// under the ink, and written into exports; never part of the ink. Pure
/// Dart: marks in PDF page coordinates (y up).
library;

import 'ink_export_plan.dart' show ExportLine;
import 'page_layout.dart' show LaidOutPage, Paper;

/// Ruled lines 8 mm apart, like ordinary lined paper.
const ruledGap = 8 / 25.4 * 72;

/// Squares and dots 5 mm apart.
const gridGap = 5 / 25.4 * 72;

/// One mark: a line from (x1, y1) to (x2, y2), or a dot when both ends
/// are the same.
typedef PaperMark = (double x1, double y1, double x2, double y2);

/// The marks on a [width] x [height] page of [paper]; [lineGap] for
/// [Paper.linedToFit] (ruled lines otherwise).
List<PaperMark> paperMarks(
  Paper paper,
  double width,
  double height, {
  double? lineGap,
}) {
  switch (paper) {
    case Paper.plain:
      return const [];
    case Paper.lined:
    case Paper.linedToFit:
      // A saved gap that makes no sense (never written today) can't make
      // endless lines.
      final fit = lineGap ?? ruledGap;
      final gap = paper == Paper.linedToFit && fit.isFinite && fit >= 2
          ? fit
          : ruledGap;
      // Starts one and a half lines down, like a notebook's header space.
      return [
        for (var y = height - gap * 1.5; y > gap * 0.5; y -= gap)
          (0, y, width, y),
      ];
    case Paper.squared:
      return [
        for (var y = height - gridGap; y > 0; y -= gridGap) (0, y, width, y),
        for (var x = gridGap; x < width; x += gridGap) (x, 0, x, height),
      ];
    case Paper.dotted:
      return [
        for (var y = height - gridGap; y > 0; y -= gridGap)
          for (var x = gridGap; x < width; x += gridGap) (x, y, x, y),
      ];
  }
}

/// The space between ruled lines that suits writing whose letters are
/// [letterHeight] points high (the typical height of the user's letters,
/// see groupStrokes): a little over twice it, so there's room for tall
/// letters and tails, kept between 4 and 16 mm.
double lineGapFor(double letterHeight) =>
    (letterHeight * 2.2).clamp(4 / 25.4 * 72, 16 / 25.4 * 72);

/// The typical letter height of the user's writing across [lineHeights]
/// (each line's letter height, from groupStrokes), or null with fewer
/// than 3 lines to go on.
double? typicalLineLetter(List<double> lineHeights) {
  if (lineHeights.length < 3) return null;
  final sorted = [...lineHeights]..sort();
  return sorted[sorted.length ~/ 2];
}

/// How a paper is named in the app.
String paperName(Paper paper) => switch (paper) {
  Paper.plain => 'Plain',
  Paper.lined => 'Lined',
  Paper.squared => 'Squared',
  Paper.dotted => 'Dotted',
  Paper.linedToFit => 'Lined to fit your writing',
};

/// The colour of paper lines: a soft blue-grey, like a notebook's.
const paperArgb = 0xFFB4C3D6;

/// [page]'s paper as lines for an export (dots as very short lines with
/// round ends: some PDF apps skip lines of no length).
List<ExportLine> paperExportLines(LaidOutPage page) {
  final paper = page.paper;
  if (paper == null || paper == Paper.plain) return const [];
  return [
    for (final (x1, y1, x2, y2) in paperMarks(
      paper,
      page.width,
      page.height,
      lineGap: page.lineGap,
    ))
      ExportLine(
        points: x1 == x2 && y1 == y2
            ? [x1 - 0.01, y1, x1 + 0.01, y2]
            : [x1, y1, x2, y2],
        width: x1 == x2 && y1 == y2 ? 1.8 : 0.6,
        colorArgb: paperArgb,
      ),
  ];
}
