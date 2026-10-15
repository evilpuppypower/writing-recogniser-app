/// Searching recognised handwriting (owner's choice: search, 2026-10-15).
/// Pure Dart: works on the words read on each page, whichever engine read
/// them.
library;

import 'stroke_grouping.dart' show InkBox;

/// A word read on a page: its line (top first), where it is, and its text.
typedef SearchWord = ({int page, int line, InkBox box, String text});

/// Where the search text was found in the handwriting: the page, the box
/// round the words it spans, and those words.
typedef HandwritingHit = ({int page, InkBox box, String text});

/// Every place [query] appears in [words], top of each page first. Ignores
/// case and extra spaces; the query can run across words (and lines, as
/// read).
List<HandwritingHit> searchHandwriting(
  Iterable<SearchWord> words,
  String query,
) {
  final q = _norm(query);
  if (q.isEmpty) return const [];
  final byPage = <int, List<SearchWord>>{};
  for (final w in words) {
    if (_norm(w.text).isNotEmpty) byPage.putIfAbsent(w.page, () => []).add(w);
  }
  final hits = <HandwritingHit>[];
  for (final page in byPage.keys.toList()..sort()) {
    final ws = byPage[page]!
      ..sort(
        (a, b) => a.line != b.line
            ? a.line.compareTo(b.line)
            : a.box.left.compareTo(b.box.left),
      );
    // The page's text, and where each word sits in it.
    final text = StringBuffer();
    final spans = <(int, int)>[];
    for (final w in ws) {
      if (text.isNotEmpty) text.write(' ');
      final start = text.length;
      text.write(_norm(w.text));
      spans.add((start, text.length));
    }
    final all = text.toString();
    for (var at = all.indexOf(q); at >= 0; at = all.indexOf(q, at + 1)) {
      final end = at + q.length;
      final inside = [
        for (var k = 0; k < ws.length; k++)
          if (spans[k].$1 < end && spans[k].$2 > at) ws[k],
      ];
      if (inside.isEmpty) continue;
      hits.add((
        page: page,
        box: inside.map((w) => w.box).reduce((a, b) => a.union(b)),
        text: inside.map((w) => w.text.trim()).join(' '),
      ));
    }
  }
  return hits;
}

String _norm(String s) =>
    s.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
