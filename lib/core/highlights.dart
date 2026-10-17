/// The highlights summary (owner's approved idea, answer 17): the printed
/// text you highlighted, and your notes with the printed line each is
/// next to, page by page, to copy or save for revision. Pure Dart: the
/// printed text comes from whatever reads the PDF, the ink and notes from
/// the stores.
library;

import 'dart:math' as math;

import 'page_ink.dart';
import 'stroke_grouping.dart' show InkBox;

/// One printed character and where it is (PDF page coordinates).
typedef PrintedChar = ({String char, InkBox box});

/// A line of your writing on a page, as text.
typedef NoteLine = ({String text, InkBox box});

/// A note and the printed line it's next to (null if none is near).
typedef Note = ({String note, String? nextTo});

class PageHighlights {
  const PageHighlights({
    required this.page,
    this.highlights = const [],
    this.notes = const [],
  });

  final int page;
  final List<String> highlights;
  final List<Note> notes;

  bool get isEmpty => highlights.isEmpty && notes.isEmpty;
}

bool _wordChar(String c) => RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(c);

double _distance(double px, double py, PageInkPoint a, PageInkPoint b) {
  final dx = b.x - a.x, dy = b.y - a.y;
  final len = dx * dx + dy * dy;
  var t = len == 0 ? 0.0 : ((px - a.x) * dx + (py - a.y) * dy) / len;
  t = t.clamp(0.0, 1.0);
  final x = a.x + t * dx - px, y = a.y + t * dy - py;
  return math.sqrt(x * x + y * y);
}

/// Whether [stroke] runs over [box]: its line passes within half its
/// width (or half the character's height, if more) of the box's middle.
bool _covers(PageStroke stroke, InkBox box) {
  final cx = (box.left + box.right) / 2, cy = box.centerY;
  final reach = math.max(stroke.width / 2, box.height / 2);
  final pts = stroke.points;
  if (pts.length == 1) return _distance(cx, cy, pts[0], pts[0]) <= reach;
  for (var i = 1; i < pts.length; i++) {
    if (_distance(cx, cy, pts[i - 1], pts[i]) <= reach) return true;
  }
  return false;
}

/// The passages of [chars] (in reading order) that highlighter strokes in
/// [strokes] run over, each made out to whole words.
List<String> highlightedText(
  List<PageStroke> strokes,
  List<PrintedChar> chars,
) {
  final marks = [
    for (final s in strokes)
      if (s.tool == InkTool.highlighter && s.points.isNotEmpty) s,
  ];
  if (marks.isEmpty || chars.isEmpty) return const [];
  final boxes = [for (final m in marks) InkBox.of(m)];
  final on = List<bool>.filled(chars.length, false);
  for (var i = 0; i < chars.length; i++) {
    final c = chars[i];
    if (c.char.trim().isEmpty || c.box.width <= 0) continue;
    for (var k = 0; k < marks.length; k++) {
      final b = boxes[k], w = marks[k].width / 2 + c.box.height;
      // Quick check first: near the stroke at all?
      if (c.box.right < b.left - w ||
          c.box.left > b.right + w ||
          c.box.top < b.bottom - w ||
          c.box.bottom > b.top + w) {
        continue;
      }
      if (_covers(marks[k], c.box)) {
        on[i] = true;
        break;
      }
    }
  }
  // Out to whole words.
  for (var i = 0; i < chars.length; i++) {
    if (!on[i] || !_wordChar(chars[i].char)) continue;
    for (var j = i - 1; j >= 0 && !on[j] && _wordChar(chars[j].char); j--) {
      on[j] = true;
    }
    for (
      var j = i + 1;
      j < chars.length && !on[j] && _wordChar(chars[j].char);
      j++
    ) {
      on[j] = true;
    }
  }
  // Runs, joined across the spaces between highlighted words.
  final out = <String>[];
  var i = 0;
  while (i < chars.length) {
    if (!on[i]) {
      i++;
      continue;
    }
    final run = StringBuffer();
    var j = i;
    while (j < chars.length) {
      if (on[j]) {
        run.write(chars[j].char);
        j++;
        continue;
      }
      // A gap of spaces (or a line break) between two highlighted parts.
      var k = j;
      while (k < chars.length && !on[k] && chars[k].char.trim().isEmpty) {
        k++;
      }
      if (k < chars.length && on[k] && k > j) {
        run.write(' ');
        j = k;
        continue;
      }
      break;
    }
    final text = run.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isNotEmpty) out.add(text);
    i = j;
  }
  return out;
}

/// [chars] put into printed lines: (text, box), top first.
List<NoteLine> printedLines(List<PrintedChar> chars) {
  final lines = <({StringBuffer text, InkBox box})>[];
  for (final c in chars) {
    if (c.box.width <= 0 || c.box.height <= 0) {
      if (lines.isNotEmpty && c.char.trim().isEmpty) lines.last.text.write(' ');
      continue;
    }
    final last = lines.isEmpty ? null : lines.last;
    if (last != null && last.box.verticalOverlap(c.box) >= 0.5) {
      last.text.write(c.char);
      lines[lines.length - 1] = (text: last.text, box: last.box.union(c.box));
    } else {
      lines.add((text: StringBuffer(c.char), box: c.box));
    }
  }
  return [
    for (final l in lines)
      if (l.text.toString().trim().isNotEmpty)
        (
          text: l.text.toString().replaceAll(RegExp(r'\s+'), ' ').trim(),
          box: l.box,
        ),
  ]..sort((a, b) => b.box.top.compareTo(a.box.top));
}

/// Each of [notes] with the printed line it's next to: the nearest one at
/// about the same height (within two of its lines), or null.
List<Note> notesNextToPrint(List<NoteLine> notes, List<NoteLine> printed) {
  return [
    for (final n in notes)
      if (n.text.trim().isNotEmpty)
        (note: n.text.trim(), nextTo: _nearest(n.box, printed)),
  ];
}

String? _nearest(InkBox note, List<NoteLine> printed) {
  NoteLine? best;
  var bestGap = double.infinity;
  for (final p in printed) {
    final gap = (p.box.centerY - note.centerY).abs();
    if (gap < bestGap) {
      bestGap = gap;
      best = p;
    }
  }
  if (best == null) return null;
  final limit = 2 * math.max(best.box.height, note.height / 2);
  return bestGap <= limit ? best.text : null;
}

/// The summary as plain text, to copy or save.
String highlightsText(String title, List<PageHighlights> pages) {
  final out = StringBuffer('$title: highlights and notes\n');
  final shown = [
    for (final p in pages)
      if (!p.isEmpty) p,
  ];
  if (shown.isEmpty) {
    out.write('\nNothing highlighted or noted yet.\n');
    return out.toString();
  }
  for (final p in shown) {
    out.write('\nPage ${p.page}\n');
    for (final h in p.highlights) {
      out.write('  “$h”\n');
    }
    for (final n in p.notes) {
      out.write('  Note: ${n.note}');
      if (n.nextTo != null) out.write('  (next to: “${n.nextTo}”)');
      out.write('\n');
    }
  }
  return out.toString();
}
