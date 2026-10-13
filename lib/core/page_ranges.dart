/// Reading a list of pages the user typed, like "1-3, 7" (task 1.4b:
/// make only some pages' handwriting searchable). Pure Dart.
library;

/// The pages in [text] ("1-3, 7", "2", "4-", "-3", "1 to 3"), each between 1 and
/// [pageCount]. Any kind of dash works (keyboards offer several), with or
/// without spaces around it. Throws a [FormatException] with a message to
/// show if the text can't be read.
Set<int> parsePageRanges(String text, int pageCount) {
  final pages = <int>{};
  final tidy = text
      .replaceAll(RegExp('[\u2010-\u2015\u2212\uFE58\uFE63\uFF0D]'), '-')
      .replaceAll(RegExp(r'(?<=\d)\s*to\s*(?=\d|$)', caseSensitive: false), '-')
      .replaceAll(RegExp(r'\s*-\s*'), '-');
  final parts = tidy.split(RegExp(r'[,;\s]+')).where((p) => p.isNotEmpty);
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
    final dash = part.split('-');
    if (dash.length == 1) {
      pages.add(page(part));
    } else if (dash.length == 2) {
      if (dash[0].trim().isEmpty && dash[1].trim().isEmpty) {
        throw FormatException('"$part" isn\'t a page range.');
      }
      // "-3" means up to page 3.
      final from = dash[0].trim().isEmpty ? 1 : page(dash[0]);
      final to = dash[1].trim().isEmpty ? pageCount : page(dash[1]);
      if (to < from) throw FormatException('"$part" runs backwards.');
      pages.addAll([for (var p = from; p <= to; p++) p]);
    } else {
      throw FormatException('"$part" isn\'t a page range.');
    }
  }
  return pages;
}

/// [pages] written short, e.g. "1–3, 7" (for "Exports pages 1–3, 7").
String describePages(Set<int> pages) {
  final sorted = pages.toList()..sort();
  final runs = <String>[];
  for (var i = 0; i < sorted.length; i++) {
    final from = sorted[i];
    while (i + 1 < sorted.length && sorted[i + 1] == sorted[i] + 1) {
      i++;
    }
    final to = sorted[i];
    runs.add(
      to == from
          ? '$from'
          : to == from + 1
          ? '$from, $to'
          : '$from–$to',
    );
  }
  return runs.join(', ');
}
