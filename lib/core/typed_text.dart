/// Handwriting converted to typed text (task 2.3b, owner's choices
/// 2026-10-12): each converted word keeps its ink and shows its text in
/// the same place, sized to fit the handwriting, in the ink's colour.
/// Pure Dart: the screen and the PDF export both draw from this.
library;

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
