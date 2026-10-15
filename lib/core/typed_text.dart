/// Handwriting converted to typed text (task 2.3b, owner's choices
/// 2026-10-12): each converted word keeps its ink and shows its text in
/// the same place, sized to fit the handwriting, in the ink's colour.
/// Pure Dart: the screen and the PDF export both draw from this.
library;

import 'dart:math' as math;

import 'ink_export_plan.dart' show ExportWord;
import 'page_ink.dart';
import 'stroke_grouping.dart';

/// One converted word on a page.
class TypedWord {
  const TypedWord({
    required this.group,
    required this.text,
    required this.box,
    required this.colorArgb,
    required this.strokeIds,
  });

  /// Identifies the word (see [PageStroke.typedGroup]).
  final String group;
  final String text;

  /// Where the handwriting is, in PDF page coordinates.
  final InkBox box;
  final int colorArgb;
  final Set<String> strokeIds;

  /// The text size, in points, that fits [text] into [box].
  double get fontSize => fitFontSize(text, box);
}

/// The converted words on a page, in writing order. A group whose text was
/// erased with its first stroke is left out (its ink just shows as ink).
List<TypedWord> typedWords(List<PageStroke> strokes) {
  final groups = <String, List<PageStroke>>{};
  for (final s in strokes) {
    final g = s.typedGroup;
    if (g != null && s.points.isNotEmpty) {
      groups.putIfAbsent(g, () => []).add(s);
    }
  }
  return [
    for (final e in groups.entries)
      if (e.value
              .map((s) => s.typedText)
              .firstWhere((t) => t != null && t.isNotEmpty, orElse: () => null)
          case final text?)
        TypedWord(
          group: e.key,
          text: text,
          box: e.value.map(InkBox.of).reduce((a, b) => a.union(b)),
          colorArgb: e.value.first.colorArgb,
          strokeIds: {for (final s in e.value) s.id},
        ),
  ];
}

/// One line of typed text: the converted words written along one line of
/// handwriting, shown together in one box with one text size, so a
/// sentence stays together (owner's choice F1, 2026-10-13).
class TypedLine {
  const TypedLine(this.words, {this.slant});

  /// Left to right.
  final List<TypedWord> words;

  /// Set when the handwriting is at a slant: the text follows it, fitted
  /// to the line turned level ([Slant.box]).
  final Slant? slant;

  String get text => words.map((w) => w.text).join(' ');

  /// Where the handwriting is on the page.
  InkBox get box => words.map((w) => w.box).reduce((a, b) => a.union(b));
  int get colorArgb => words.first.colorArgb;

  /// The text size, in points, that fits the whole line into its box.
  double get fontSize => fitFontSize(text, slant?.box ?? box);
}

/// The converted words on a page, gathered into lines as the handwriting
/// is (see [groupStrokes]: words far apart at the same height are separate
/// lines), top first.
List<TypedLine> typedLines(List<PageStroke> strokes) =>
    _linesCache[strokes] ??= _typedLines(strokes);

/// [typedLines] per stroke list (a page's list is replaced whenever it
/// changes), so screens redrawn while scrolling don't group the page again.
final _linesCache = Expando<List<TypedLine>>();

List<TypedLine> _typedLines(List<PageStroke> strokes) {
  final words = typedWords(strokes);
  if (words.isEmpty) return const [];
  final ids = {for (final w in words) ...w.strokeIds};
  final lines = groupStrokes(
    strokes,
    include: (i) => ids.contains(strokes[i].id),
  );
  final lineOf = <String, int>{
    for (var l = 0; l < lines.length; l++)
      for (final w in lines[l].words)
        for (final i in w.strokes) strokes[i].id: l,
  };
  // A word goes on the line most of its strokes are on.
  int lineOfWord(TypedWord w) {
    final votes = <int, int>{};
    for (final id in w.strokeIds) {
      final l = lineOf[id];
      if (l != null) votes[l] = (votes[l] ?? 0) + 1;
    }
    if (votes.isEmpty) return -1;
    return votes.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  }

  final byLine = <int, List<TypedWord>>{};
  final alone = <TypedLine>[];
  for (final w in words) {
    final l = lineOfWord(w);
    if (l < 0) {
      alone.add(TypedLine([w]));
    } else {
      byLine.putIfAbsent(l, () => []).add(w);
    }
  }
  final keys = byLine.keys.toList()..sort();
  final byId = {for (final s in strokes) s.id: s};
  TypedLine line(int l) {
    final words = byLine[l]!;
    final first = lines[l].words.first.slant;
    if (first == null) {
      return TypedLine(words..sort((a, b) => a.box.left.compareTo(b.box.left)));
    }
    // At a slant: words in order along the line, and the line's box
    // turned level.
    InkBox level(TypedWord w) => [
      for (final id in w.strokeIds)
        if (byId[id] case final s?)
          InkBox.of(
            s.copyWith(
              points: [
                for (final p in s.points)
                  levelPoint(p, first.angle, first.cx, first.cy),
              ],
            ),
          ),
    ].reduce((a, b) => a.union(b));
    final boxes = {for (final w in words) w: level(w)};
    words.sort((a, b) => boxes[a]!.left.compareTo(boxes[b]!.left));
    return TypedLine(
      words,
      slant: (
        angle: first.angle,
        cx: first.cx,
        cy: first.cy,
        box: boxes.values.reduce((a, b) => a.union(b)),
      ),
    );
  }

  return [for (final l in keys) line(l), ...alone];
}

/// The converted words' groups on a page (cheap: no boxes are worked out).
Set<String> convertedGroups(List<PageStroke> strokes) => {
  for (final s in strokes)
    if (s.typedGroup != null && (s.typedText?.isNotEmpty ?? false))
      s.typedGroup!,
};

/// The stroke ids of converted words on a page, cached per stroke list (a
/// page's list is replaced whenever it changes), for checks run for every
/// word on every rebuild.
Set<String> convertedStrokeIds(List<PageStroke> strokes) {
  final cached = _idsCache[strokes];
  if (cached != null) return cached;
  final groups = convertedGroups(strokes);
  final ids = {
    for (final s in strokes)
      if (groups.contains(s.typedGroup)) s.id,
  };
  _idsCache[strokes] = ids;
  return ids;
}

final _idsCache = Expando<Set<String>>();

/// Whether most of a recognised word's strokes ([key]: comma-separated
/// ids) are among [converted] — after a stroke is added or rubbed out
/// nearby, the word read may not match the converted one exactly.
bool mostlyConverted(String key, Set<String> converted) {
  if (key.isEmpty || converted.isEmpty) return false;
  final ids = key.split(',');
  return ids.where(converted.contains).length * 2 > ids.length;
}

/// Average width of a character, as a share of the font size (Helvetica is
/// about half as wide as it is tall).
const averageCharWidth = 0.52;

/// The font size (points) that fits [text] into [box]: as tall as the
/// handwriting allows, narrowed if the text would be wider, never below a
/// readable minimum.
double fitFontSize(String text, InkBox box) {
  final chars = text.trim().length;
  final byHeight = box.height * 0.8;
  final byWidth = chars == 0
      ? byHeight
      : box.width / (chars * averageCharWidth);
  final size = byHeight < byWidth ? byHeight : byWidth;
  return size < minTypedFontSize ? minTypedFontSize : size;
}

/// Typed text is never smaller than this (points).
const minTypedFontSize = 5.0;

/// Whether [s] should be drawn as ink when typed text is shown: everything
/// except the strokes of converted words.
bool showsAsInkWhenTyped(PageStroke s, Set<String> convertedGroups) =>
    s.typedGroup == null || !convertedGroups.contains(s.typedGroup);

/// Whether ([x], [y]) is inside the closed loop [polygon] (even-odd rule).
bool insideLoop(List<PageInkPoint> polygon, double x, double y) {
  var inside = false;
  for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    final a = polygon[i], b = polygon[j];
    if ((a.y > y) != (b.y > y) &&
        x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x) {
      inside = !inside;
    }
  }
  return inside;
}

/// The ids of the strokes on a page that a lasso [loop] goes around: at
/// least [share] of a stroke's points must be inside, so a loop that
/// clips the edge of a neighbouring word doesn't take it.
Set<String> strokesInLoop(
  List<PageStroke> strokes,
  List<PageInkPoint> loop, {
  double share = 0.6,
}) {
  if (loop.length < 3) return const {};
  return {
    for (final s in strokes)
      if (s.points.isNotEmpty &&
          s.points.where((p) => insideLoop(loop, p.x, p.y)).length >=
              share * s.points.length)
        s.id,
  };
}

/// How handwriting goes into an exported PDF (task 2.3d, owner's choice
/// 5b: chosen at export time).
enum ExportHandwriting {
  ink('My handwriting'),
  typed('Typed text'),
  both('Both: handwriting with the typed text under it');

  const ExportHandwriting(this.label);
  final String label;
}

/// [ink] as it goes into an export with [mode]: for typed text only, the
/// ink of converted words is left out (everything else stays).
DocumentInk inkForExport(DocumentInk ink, ExportHandwriting mode) {
  if (mode != ExportHandwriting.typed) return ink;
  final out = DocumentInk();
  for (final page in ink.pagesWithInk) {
    final strokes = ink.strokesOn(page);
    final groups = {for (final w in typedWords(strokes)) w.group};
    out.setPage(page, [
      for (final s in strokes)
        if (!groups.contains(s.typedGroup)) s,
    ]);
  }
  return out;
}

/// The typed lines of a page as visible export text: over the handwriting
/// for [ExportHandwriting.typed], just under it for [ExportHandwriting.both]
/// (the writer places it, following the page's rotation).
List<ExportWord> typedForExport(
  List<PageStroke> strokes,
  ExportHandwriting mode,
) {
  if (mode == ExportHandwriting.ink) return const [];
  return [
    for (final w in typedLines(strokes))
      if (w.slant?.box ?? w.box case final b)
        ExportWord(
          w.text,
          b.left,
          b.bottom,
          b.right,
          b.top,
          colorArgb: w.colorArgb,
          fontSize: w.fontSize,
          under: mode == ExportHandwriting.both,
          angle: w.slant?.angle ?? 0,
          cx: w.slant?.cx ?? 0,
          cy: w.slant?.cy ?? 0,
        ),
  ];
}

/// Where typed text goes on a PDF page shown turned [quarterTurns]
/// clockwise: the text matrix (a, b, c, d, e, f) that draws it upright on
/// screen at [size] points, starting at the box's on-screen left and
/// centred in it (or just under it when [under]). Box in page coordinates.
({double a, double b, double c, double d, double e, double f}) typedPlacement(
  ExportWord w,
  int quarterTurns,
  double size,
) {
  // Screen-right (u) and screen-up (v) as page directions.
  final (ux, uy, vx, vy) = switch (quarterTurns & 3) {
    0 => (1.0, 0.0, 0.0, 1.0),
    1 => (0.0, 1.0, -1.0, 0.0),
    2 => (-1.0, 0.0, 0.0, -1.0),
    _ => (0.0, -1.0, 1.0, 0.0),
  };
  double u(double x, double y) => x * ux + y * uy;
  double v(double x, double y) => x * vx + y * vy;
  final us = [u(w.left, w.bottom), u(w.right, w.top)];
  final vs = [v(w.left, w.bottom), v(w.right, w.top)];
  final uMin = us.reduce((a, b) => a < b ? a : b);
  final vMin = vs.reduce((a, b) => a < b ? a : b);
  final vMax = vs.reduce((a, b) => a > b ? a : b);
  // Capital letters are about 0.7 of the size tall.
  final baseline = w.under
      ? vMin - size * 0.85
      : vMin + (vMax - vMin - size * 0.7) / 2;
  // Back to page coordinates: (u, v) -> u * U + v * V.
  return (
    a: size * ux,
    b: size * uy,
    c: size * vx,
    d: size * vy,
    e: uMin * ux + baseline * vx,
    f: uMin * uy + baseline * vy,
  );
}

/// The size typed text gets on a page turned [quarterTurns]: fitted to the
/// handwriting as seen on screen.
double typedSizeOnPage(ExportWord w, int quarterTurns) {
  final size = w.fontSize;
  if (w.fixedSize && size != null) return size;
  final box = quarterTurns.isOdd
      ? InkBox(w.bottom, w.left, w.top, w.right)
      : InkBox(w.left, w.bottom, w.right, w.top);
  return fitFontSize(w.text, box);
}

/// A text matrix [m] (see [typedPlacement]) for text placed with its line
/// turned level, turned back by [angle] about ([cx], [cy]) so the text
/// follows writing at a slant.
({double a, double b, double c, double d, double e, double f}) atSlant(
  ({double a, double b, double c, double d, double e, double f}) m,
  double angle,
  double cx,
  double cy,
) {
  if (angle == 0) return m;
  final cs = math.cos(angle), sn = math.sin(angle);
  return (
    a: cs * m.a - sn * m.b,
    b: sn * m.a + cs * m.b,
    c: cs * m.c - sn * m.d,
    d: sn * m.c + cs * m.d,
    e: cx + cs * (m.e - cx) - sn * (m.f - cy),
    f: cy + sn * (m.e - cx) + cs * (m.f - cy),
  );
}

/// The text boxes on a page (see InkTool.text) as visible export text, one
/// line each, at their own size: always exported, whatever is chosen for
/// the handwriting.
List<ExportWord> textBoxesForExport(List<PageStroke> strokes) => [
  for (final s in strokes)
    if (s.isTextBox && s.points.length >= 2 && (s.typedText ?? '').isNotEmpty)
      for (final (i, line) in s.typedText!.split('\n').indexed)
        if (line.trim().isNotEmpty)
          ExportWord(
            line,
            math.min(s.points.first.x, s.points.last.x),
            math.max(s.points.first.y, s.points.last.y) -
                (i + 1) * s.width * 1.25,
            math.max(s.points.first.x, s.points.last.x),
            math.max(s.points.first.y, s.points.last.y) - i * s.width * 1.25,
            colorArgb: s.colorArgb,
            fontSize: s.width,
            fixedSize: true,
          ),
];
