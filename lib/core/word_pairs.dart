/// Examples for a learned word-finding model (owner's choice: option 2,
/// 2026-10-14). For each pair of neighbouring strokes on a line, a few
/// numbers describing them, and whether the user said they're one word
/// ("One word" in the selection bar). The laptop training learns from
/// these; the app computes the same numbers with this code, so the two
/// can't disagree. Pure Dart.
library;

import 'dart:math' as math;

import 'page_ink.dart';
import 'stroke_grouping.dart';

/// The numbers for a pair, in this order (see [pairFeatures]).
const wordPairFeatures = [
  'gap', // sideways gap, in letter heights (-3..10)
  'overlap', // share of the shorter one's height they share (0..1)
  'secondsApart', // ln(1 + seconds between them)
  'touching', // 1 if they touch or overlap sideways
  'sizeRatio', // ln(taller / shorter height)
  'smallMark', // 1 if either is dot-sized
  'rulesJoin', // 1 if today's rules put them in one word
];

/// One pair of neighbouring strokes, and the user's answer.
class WordPair {
  const WordPair(this.features, {required this.sameWord});

  final List<double> features;
  final bool sameWord;

  Map<String, Object?> toJson() => {
    'features': [for (final f in features) (f * 1000).round() / 1000],
    'sameWord': sameWord,
  };
}

/// The numbers for strokes [a] then [b] (left to right) on a line whose
/// letters are [letter] high; [rulesJoin]: whether today's rules joined
/// them.
List<double> pairFeatures(
  PageStroke a,
  PageStroke b,
  double letter, {
  required bool rulesJoin,
}) {
  final ba = InkBox.of(a), bb = InkBox.of(b);
  final h = math.max(letter, 1e-6);
  final gap = (ba.horizontalGap(bb) / h).clamp(-3.0, 10.0);
  final apartMs = math.max((b.points.first.t - a.points.last.t).abs(), 0);
  final hi = math.max(math.max(ba.height, bb.height), 0.5);
  final lo = math.max(math.min(ba.height, bb.height), 0.5);
  bool small(InkBox x) => math.max(x.width, x.height) < h * 0.4;
  return [
    gap,
    ba.verticalOverlap(bb),
    math.log(1 + apartMs / 1000),
    gap <= 0 ? 1 : 0,
    math.log(hi / lo),
    small(ba) || small(bb) ? 1 : 0,
    rulesJoin ? 1 : 0,
  ];
}

/// The labelled pairs on one page: neighbours on a line where at least one
/// stroke carries a "One word" mark. Strokes with the same mark are one
/// word; a marked stroke next to a stroke without that mark is a word
/// boundary (the user drew the loop round the word, not round it).
List<WordPair> wordPairs(List<PageStroke> strokes) {
  if (!strokes.any((s) => s.manualWord != null)) return const [];
  // Today's rules, without the user's marks, to compare with.
  final plain = [for (final s in strokes) s.copyWith(manualWord: null)];
  final lines = groupStrokes(plain);
  final out = <WordPair>[];
  for (final line in lines) {
    final wordOf = <int, int>{};
    for (var w = 0; w < line.words.length; w++) {
      for (final i in line.words[w].strokes) {
        wordOf[i] = w;
      }
    }
    final order = wordOf.keys.toList()
      ..sort(
        (x, y) =>
            InkBox.of(strokes[x]).left.compareTo(InkBox.of(strokes[y]).left),
      );
    for (var k = 0; k + 1 < order.length; k++) {
      final a = strokes[order[k]], b = strokes[order[k + 1]];
      if (a.manualWord == null && b.manualWord == null) continue;
      out.add(
        WordPair(
          pairFeatures(
            a,
            b,
            line.letterHeight,
            rulesJoin: wordOf[order[k]] == wordOf[order[k + 1]],
          ),
          sameWord: a.manualWord != null && a.manualWord == b.manualWord,
        ),
      );
    }
  }
  return out;
}
