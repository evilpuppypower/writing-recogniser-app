/// Reading a list of pages the user typed, like "1-3, 7" (task 1.4b:
/// make only some pages' handwriting searchable). Pure Dart.
library;

/// The pages in [text] ("1-3, 7", "2", "4-"), each between 1 and
/// [pageCount]. Throws a [FormatException] with a message to show if the
/// text can't be read.
Set<int> parsePageRanges(String text, int pageCount) {
  final pages = <int>{};
  final parts = text.split(RegExp(r'[,;\s]+')).where((p) => p.isNotEmpty);
  if (parts.isEmpty) {
    throw const FormatException('Type the pages, e.g. 1-3, 7.');
  }
  int page(String s) {
    final n = int.tryParse(s.trim());
    if (n == null) throw FormatException('"$s" isn\'t a page number.');
    if (n < 1 || n > pageCount) {
      throw FormatException('Page $n isn\'t in this PDF (1-$pageCount).');
    }
    return n;
  }

  for (final part in parts) {
    final dash = part.split(RegExp(r'[-–]'));
    if (dash.length == 1) {
      pages.add(page(part));
    } else if (dash.length == 2) {
      final from = page(dash[0]);
      final to = dash[1].trim().isEmpty ? pageCount : page(dash[1]);
      if (to < from) throw FormatException('"$part" runs backwards.');
      pages.addAll([for (var p = from; p <= to; p++) p]);
    } else {
      throw FormatException('"$part" isn\'t a page range.');
    }
  }
  return pages;
}
