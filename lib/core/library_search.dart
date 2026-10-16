/// Searching everything from the home screen (owner, 2026-10-16): every
/// document's name, tags, handwriting (as read, as typed, shorthand
/// written out) and printed text. Pure Dart: the text comes from the
/// stores, whichever engine read it.
library;

import 'dart:convert';

import 'page_ink.dart';
import 'page_layout.dart';
import 'typed_text.dart';

/// Where on a page the text was found.
enum FoundIn { handwriting, printed }

/// One page's text of one kind. [page] is where the page is shown (1-based,
/// in the document's own page order).
typedef PageText = ({int page, FoundIn kind, String text});

/// A document to search.
class SearchableDocument {
  const SearchableDocument({
    required this.id,
    required this.name,
    this.tags = const [],
    this.pages = const [],
  });

  final String id;
  final String name;
  final List<String> tags;
  final List<PageText> pages;
}

/// Where the search text is on one page, with some text around the first
/// place ([before], [match], [after], to show it in bold).
class PageMatch {
  const PageMatch({
    required this.page,
    required this.kind,
    required this.count,
    required this.before,
    required this.match,
    required this.after,
  });

  final int page;
  final FoundIn kind;

  /// How many times on this page (of this kind).
  final int count;
  final String before, match, after;
}

/// A document the search text is in.
class DocumentMatch {
  const DocumentMatch({
    required this.id,
    required this.name,
    required this.inName,
    required this.tags,
    required this.pages,
  });

  final String id;
  final String name;

  /// The name has it.
  final bool inName;

  /// Its tags that have it.
  final List<String> tags;

  /// Pages that have it, first page first.
  final List<PageMatch> pages;

  int get count => pages.fold(0, (n, p) => n + p.count);
}

/// The documents [query] is found in: those whose name or tags have it
/// first, then those with the most matches. Ignores case and extra spaces.
List<DocumentMatch> searchLibrary(
  Iterable<SearchableDocument> documents,
  String query, {
  int around = 40,
}) {
  final q = _tidy(query).toLowerCase();
  if (q.isEmpty) return const [];
  final out = <DocumentMatch>[];
  for (final d in documents) {
    final inName = _tidy(d.name).toLowerCase().contains(q);
    final tags = [
      for (final t in d.tags)
        if (_tidy(t).toLowerCase().contains(q)) t,
    ];
    final pages = <PageMatch>[];
    for (final p in d.pages) {
      final m = _find(p, q, around);
      if (m != null) pages.add(m);
    }
    if (!inName && tags.isEmpty && pages.isEmpty) continue;
    pages.sort(
      (a, b) => a.page != b.page
          ? a.page.compareTo(b.page)
          : a.kind.index.compareTo(b.kind.index),
    );
    out.add(
      DocumentMatch(
        id: d.id,
        name: d.name,
        inName: inName,
        tags: tags,
        pages: pages,
      ),
    );
  }
  int rank(DocumentMatch m) => (m.inName || m.tags.isNotEmpty) ? 0 : 1;
  out.sort((a, b) {
    final r = rank(a).compareTo(rank(b));
    if (r != 0) return r;
    final c = b.count.compareTo(a.count);
    if (c != 0) return c;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return out;
}

PageMatch? _find(PageText p, String q, int around) {
  final text = _tidy(p.text);
  final lower = text.toLowerCase();
  // Lower case can change a text's length (rarely): then it's shown in
  // lower case, so the places line up.
  final shown = lower.length == text.length ? text : lower;
  final first = lower.indexOf(q);
  if (first < 0) return null;
  var count = 0;
  for (var at = first; at >= 0; at = lower.indexOf(q, at + q.length)) {
    count++;
  }
  final end = first + q.length;
  final from = (first - around).clamp(0, first);
  final to = (end + around).clamp(end, shown.length);
  return PageMatch(
    page: p.page,
    kind: p.kind,
    count: count,
    before: '${from > 0 ? '…' : ''}${shown.substring(from, first)}',
    match: shown.substring(first, end),
    after: '${shown.substring(end, to)}${to < shown.length ? '…' : ''}',
  );
}

String _tidy(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// A page's handwriting as text: the words read (as saved by the viewer,
/// [wordsJson]), except those converted to typed text, which count by their
/// typed text (as edited), and text boxes. [expand] writes shorthand out,
/// so either form is found.
String pageHandwriting({
  String? wordsJson,
  List<PageStroke> strokes = const [],
  String Function(String)? expand,
}) {
  final parts = <String>[];
  void add(String t) {
    final s = t.trim();
    if (s.isEmpty) return;
    parts.add(s);
    final full = expand?.call(s);
    if (full != null && full != s) parts.add(full);
  }

  final converted = convertedStrokeIds(strokes);
  if (wordsJson != null) {
    try {
      final j = jsonDecode(wordsJson);
      final words = j is Map ? j['words'] : null;
      if (words is List) {
        for (final w in words) {
          if (w is! Map || w['text'] is! String) continue;
          final key = w['key'];
          if (key is String && key.split(',').any(converted.contains)) {
            continue;
          }
          add(w['text'] as String);
        }
      }
    } catch (_) {
      // Unreadable: the page's typed text still counts.
    }
  }
  for (final t in typedLines(strokes)) {
    add(t.text);
  }
  for (final s in strokes) {
    if (s.isTextBox) add(s.typedText ?? '');
  }
  return parts.join(' ');
}

/// [byKey] (saved under each page's lasting key) by where each page is
/// shown, for a document with pages of its own ([layout]); pages not shown
/// are left out. Without a layout, keys are page numbers.
Map<int, T> byPosition<T>(Map<int, T> byKey, PageLayout? layout) {
  if (layout == null) return byKey;
  return {for (final e in byKey.entries) ?layout.positionOf(e.key): e.value};
}

/// [bySource] (a PDF's printed text, by its own page numbers) by where
/// each page is shown; a page shown twice (copied) counts at each place.
Map<int, String> printedByPosition(
  Map<int, String> bySource,
  PageLayout? layout,
) {
  if (layout == null) return bySource;
  return {
    for (var i = 1; i <= layout.length; i++)
      if (layout.at(i).sourcePage case final s?) i: ?bySource[s],
  };
}
