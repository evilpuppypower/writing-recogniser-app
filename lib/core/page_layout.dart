/// The pages of a document in the order they're shown (owner's choice:
/// blank pages like any notes app). The PDF is never changed (CLAUDE.md
/// rule 6): its pages are shown in this order, with pages of our own (to
/// write on) between them. Pure Dart.
///
/// Each page has a lasting [LaidOutPage.key]: the PDF's own pages keep
/// their page number as their key, so ink, text and bookmarks saved before
/// pages could be added stay where they were; pages of our own get keys
/// from [firstOwnKey] up. Everything saved for a page is saved under its
/// key, and only this list changes when pages are added, moved or removed.
library;

import 'dart:convert';

/// Paper for a page of our own.
enum Paper {
  plain,
  lined,
  squared,
  dotted,

  /// Lined, the lines as far apart as the user's own writing needs.
  linedToFit,
}

class LaidOutPage {
  /// One of the PDF's own pages: its page number is its key.
  const LaidOutPage.pdf(int n)
    : key = n,
      sourcePage = n,
      paper = null,
      width = 0,
      height = 0,
      lineGap = null;

  /// A copy of the PDF's page [sourcePage] (shown under its own ink).
  const LaidOutPage.copyOf(this.key, int this.sourcePage)
    : paper = null,
      width = 0,
      height = 0,
      lineGap = null;

  /// A page of our own, to write on.
  const LaidOutPage.blank(
    this.key, {
    required Paper this.paper,
    required this.width,
    required this.height,
    this.lineGap,
  }) : sourcePage = null;

  /// Saved ink, text and bookmarks are kept under this.
  final int key;

  /// The PDF page shown, or null for a page of our own.
  final int? sourcePage;

  /// The paper of a page of our own.
  final Paper? paper;

  /// Size in points, for a page of our own.
  final double width, height;

  /// Space between lines in points, for [Paper.linedToFit].
  final double? lineGap;

  bool get isBlank => sourcePage == null;

  Map<String, Object?> toJson() => {
    'k': key,
    if (sourcePage != null) 's': sourcePage,
    if (paper != null) 'p': paper!.name,
    if (isBlank) 'w': width,
    if (isBlank) 'h': height,
    if (lineGap != null) 'g': lineGap,
  };

  static LaidOutPage fromJson(Map<String, Object?> j) {
    final key = j['k']! as int;
    final s = j['s'] as int?;
    if (s != null) {
      return s == key ? LaidOutPage.pdf(s) : LaidOutPage.copyOf(key, s);
    }
    final p = j['p'] as String?;
    return LaidOutPage.blank(
      key,
      paper: Paper.values.firstWhere(
        (v) => v.name == p,
        orElse: () => Paper.plain,
      ),
      width: (j['w']! as num).toDouble(),
      height: (j['h']! as num).toDouble(),
      lineGap: (j['g'] as num?)?.toDouble(),
    );
  }
}

class PageLayout {
  PageLayout(List<LaidOutPage> pages, {required this.pdfPageCount})
    : pages = List.unmodifiable(pages);

  /// The PDF's pages in their own order, nothing added.
  PageLayout.of(this.pdfPageCount)
    : pages = List.unmodifiable([
        for (var n = 1; n <= pdfPageCount; n++) LaidOutPage.pdf(n),
      ]);

  /// Keys of pages of our own start here, well past any PDF's page count.
  static const firstOwnKey = 1000001;

  /// Shown first to last (position 1 is the first).
  final List<LaidOutPage> pages;

  /// Pages in the PDF itself (its own pages hidden from [pages] still
  /// count).
  final int pdfPageCount;

  int get length => pages.length;

  /// The PDF's own pages, in their own order, nothing added or hidden: the
  /// PDF can be shown as it is.
  bool get isPlain {
    if (pages.length != pdfPageCount) return false;
    for (var i = 0; i < pages.length; i++) {
      if (pages[i].key != i + 1 || pages[i].sourcePage != i + 1) return false;
    }
    return true;
  }

  /// The page at [position] (1-based).
  LaidOutPage at(int position) => pages[position - 1];

  int keyAt(int position) => pages[position - 1].key;

  /// Where the page with [key] is shown (1-based), or null if it isn't.
  int? positionOf(int key) {
    for (var i = 0; i < pages.length; i++) {
      if (pages[i].key == key) return i + 1;
    }
    return null;
  }

  /// The PDF's own pages not shown (removed by the user; they can be put
  /// back), in their own order. Copies don't count.
  List<int> get hiddenPdfPages {
    final shown = {for (final p in pages) p.key};
    return [
      for (var n = 1; n <= pdfPageCount; n++)
        if (!shown.contains(n)) n,
    ];
  }

  int get _nextKey {
    var next = firstOwnKey;
    for (final p in pages) {
      if (p.key >= next) next = p.key + 1;
    }
    return next;
  }

  /// A new page of our own put at [position] (1-based; the end is
  /// [length] + 1), and its key.
  (PageLayout, int) insert(
    int position, {
    required Paper paper,
    required double width,
    required double height,
    double? lineGap,
    int? key,
  }) {
    final k = key ?? _nextKey;
    final at = position.clamp(1, pages.length + 1);
    return (
      PageLayout([
        ...pages.sublist(0, at - 1),
        LaidOutPage.blank(
          k,
          paper: paper,
          width: width,
          height: height,
          lineGap: lineGap,
        ),
        ...pages.sublist(at - 1),
      ], pdfPageCount: pdfPageCount),
      k,
    );
  }

  /// A copy of the page at [position] put just after it, and the copy's
  /// key (its ink is copied by whoever keeps it).
  (PageLayout, int) duplicate(int position) {
    final p = at(position);
    final k = _nextKey;
    final copy = p.isBlank
        ? LaidOutPage.blank(
            k,
            paper: p.paper!,
            width: p.width,
            height: p.height,
            lineGap: p.lineGap,
          )
        : LaidOutPage.copyOf(k, p.sourcePage!);
    return (
      PageLayout([
        ...pages.sublist(0, position),
        copy,
        ...pages.sublist(position),
      ], pdfPageCount: pdfPageCount),
      k,
    );
  }

  /// Without the page at [position] (never the last page left).
  PageLayout remove(int position) {
    if (pages.length <= 1) return this;
    return PageLayout([
      ...pages.sublist(0, position - 1),
      ...pages.sublist(position),
    ], pdfPageCount: pdfPageCount);
  }

  /// The pages in [order] (positions, each once).
  PageLayout reorder(List<int> order) =>
      PageLayout([for (final p in order) at(p)], pdfPageCount: pdfPageCount);

  /// The PDF's page [n] shown again, where it was among its neighbours
  /// (after the nearest of the PDF's earlier pages still shown).
  PageLayout restore(int n) {
    if (positionOf(n) != null || n < 1 || n > pdfPageCount) return this;
    var at = 0;
    for (var i = 0; i < pages.length; i++) {
      final k = pages[i].key;
      if (k <= pdfPageCount && k < n) at = i + 1;
    }
    return PageLayout([
      ...pages.sublist(0, at),
      LaidOutPage.pdf(n),
      ...pages.sublist(at),
    ], pdfPageCount: pdfPageCount);
  }

  String toJson() => jsonEncode({
    'n': pdfPageCount,
    'pages': [for (final p in pages) p.toJson()],
  });

  /// [json] from [toJson], or null when it can't be read. With
  /// [pdfPageCount], also null when it was saved for a PDF with a
  /// different number of pages (the file changed).
  static PageLayout? fromJson(String? json, [int? pdfPageCount]) {
    if (json == null) return null;
    try {
      final j = jsonDecode(json) as Map<String, Object?>;
      final n = j['n']! as int;
      if (pdfPageCount != null && n != pdfPageCount) return null;
      return _parse(j, n);
    } catch (_) {
      return null;
    }
  }

  static PageLayout? _parse(Map<String, Object?> j, int pdfPageCount) {
    {
      final pages = [
        for (final p in j['pages']! as List)
          LaidOutPage.fromJson((p as Map).cast<String, Object?>()),
      ];
      final keys = <int>{};
      for (final p in pages) {
        if (!keys.add(p.key)) return null;
        if (p.key <= pdfPageCount && p.sourcePage != p.key) return null;
        final s = p.sourcePage;
        if (s != null && (s < 1 || s > pdfPageCount)) return null;
      }
      if (pages.isEmpty) return null;
      return PageLayout(pages, pdfPageCount: pdfPageCount);
    }
  }
}

/// Where each document's [PageLayout] is kept.
abstract class PageLayoutStore {
  /// [documentId]'s saved layout ([PageLayout.toJson]), or null.
  Future<String?> load(String documentId);

  /// Saves [layout]; a plain one ([PageLayout.isPlain]) is removed.
  Future<void> save(String documentId, PageLayout layout);
}

/// A [PageLayoutStore] in memory (tests, or when the database can't open).
class MemoryPageLayoutStore implements PageLayoutStore {
  final _layouts = <String, String>{};

  @override
  Future<String?> load(String documentId) async => _layouts[documentId];

  @override
  Future<void> save(String documentId, PageLayout layout) async {
    layout.isPlain
        ? _layouts.remove(documentId)
        : _layouts[documentId] = layout.toJson();
  }
}
