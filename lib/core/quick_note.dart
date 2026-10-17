/// Quick note (owner, 2026-10-17: a home screen button): one tap opens a
/// new page at the end of the "Quick notes" notebook. Pure Dart.
library;

import 'page_layout.dart';

const quickNotesTitle = 'Quick notes';

/// Where a quick note goes: a new page at the end of [notebook] (a new
/// notebook when null), on the same paper and size as its last page. If
/// that page is still empty ([lastPageEmpty]) it's used instead, so
/// tapping twice doesn't leave empty pages behind.
({PageLayout layout, int page}) addQuickNote(
  PageLayout? notebook, {
  bool lastPageEmpty = false,
  Paper paper = Paper.lined,
  double width = 595,
  double height = 842,
}) {
  if (notebook == null) {
    return (
      layout: PageLayout.newNotebook(
        paper: paper,
        width: width,
        height: height,
        title: quickNotesTitle,
      ),
      page: 1,
    );
  }
  final n = notebook.length;
  if (lastPageEmpty) return (layout: notebook, page: n);
  final last = notebook.at(n);
  final (layout, _) = notebook.insert(
    n + 1,
    paper: last.paper ?? paper,
    width: last.isBlank && last.width > 0 ? last.width : width,
    height: last.isBlank && last.height > 0 ? last.height : height,
    lineGap: last.lineGap,
  );
  return (layout: layout, page: n + 1);
}
