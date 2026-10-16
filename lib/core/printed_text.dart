/// Where a PDF page's own printed text sits (owner: handwriting in the
/// margins stops and works its way around the printed text). Grouping uses
/// it so a note isn't joined to the one on the other side of a printed
/// column, and a sentence written straight on past printed text is kept
/// together; reading uses it so each note follows on from the writing
/// above it, not from a note across the page. Pure Dart: the boxes are in
/// PDF page coordinates, from whatever reads the PDF.
library;

import 'dart:math' as math;

import 'stroke_grouping.dart' show InkBox;

class PrintedText {
  /// [boxes]: printed text, in any pieces (characters, words or lines).
  /// Pieces next to each other on a printed line are joined, so there are
  /// fewer to look through.
  PrintedText(Iterable<InkBox> boxes) : boxes = _joined(boxes) {
    for (var i = 0; i < this.boxes.length; i++) {
      final b = this.boxes[i];
      for (var x = _cell(b.left); x <= _cell(b.right); x++) {
        for (var y = _cell(b.bottom); y <= _cell(b.top); y++) {
          (_grid[(x, y)] ??= []).add(i);
        }
      }
    }
  }

  /// A page without printed text (or not read yet).
  static final none = PrintedText(const []);

  final List<InkBox> boxes;
  final _grid = <(int, int), List<int>>{};

  static const _size = 48.0;
  static int _cell(double v) => (v / _size).floor();

  bool get isEmpty => boxes.isEmpty;

  /// The printed pieces that overlap [area].
  Iterable<InkBox> within(InkBox area) sync* {
    if (boxes.isEmpty) return;
    final seen = <int>{};
    for (var x = _cell(area.left); x <= _cell(area.right); x++) {
      for (var y = _cell(area.bottom); y <= _cell(area.top); y++) {
        for (final i in _grid[(x, y)] ?? const <int>[]) {
          if (!seen.add(i)) continue;
          final b = boxes[i];
          if (b.left < area.right &&
              b.right > area.left &&
              b.bottom < area.top &&
              b.top > area.bottom) {
            yield b;
          }
        }
      }
    }
  }

  /// How much of the stretch from [left] to [right] printed text covers,
  /// counting only printed text that shares at least a third of the
  /// height band [bottom]..[top] (so a printed line just touching the
  /// band doesn't count).
  double covered(double left, double right, double bottom, double top) {
    if (right <= left || boxes.isEmpty) return 0;
    final band = InkBox(left, bottom, right, top);
    final spans = <(double, double)>[];
    for (final b in within(band)) {
      if (b.verticalOverlap(band) < 1 / 3) continue;
      spans.add((math.max(b.left, left), math.min(b.right, right)));
    }
    spans.sort((a, c) => a.$1.compareTo(c.$1));
    var total = 0.0, end = left;
    for (final (s, e) in spans) {
      final from = math.max(s, end);
      if (e > from) {
        total += e - from;
        end = e;
      }
    }
    return total;
  }

  /// Joins pieces on the same printed line that are less than one of
  /// their heights apart.
  static List<InkBox> _joined(Iterable<InkBox> pieces) {
    final sorted = [
      for (final b in pieces)
        if (b.width > 0 && b.height > 0) b,
    ]..sort((a, c) => a.left.compareTo(c.left));
    final out = <InkBox>[];
    // Lines still open for joining, newest last.
    final open = <int>[];
    for (final b in sorted) {
      int? into;
      for (final i in open.reversed) {
        final o = out[i];
        if (b.verticalOverlap(o) >= 0.5 &&
            b.left - o.right < math.min(b.height, o.height)) {
          into = i;
          break;
        }
      }
      if (into == null) {
        out.add(b);
        open.add(out.length - 1);
      } else {
        out[into] = out[into].union(b);
      }
      // Lines that ended well to the left can't take more pieces.
      open.removeWhere((i) => b.left - out[i].right > out[i].height * 2);
    }
    return out;
  }
}
