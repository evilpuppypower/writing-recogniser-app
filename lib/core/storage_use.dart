/// What the app keeps on the tablet, and how much space each part takes
/// (owner, 2026-10-16: "the app may grow, but give a storage overview").
/// Pure Dart.
library;

/// One part of what's kept.
class StoragePart {
  const StoragePart(this.name, this.bytes, this.about);

  final String name;
  final int bytes;

  /// What it is, in plain words.
  final String about;
}

/// Everything, biggest first, with the total.
class StorageUse {
  StorageUse(Iterable<StoragePart> parts)
    : parts = [
        for (final p in parts)
          if (p.bytes > 0) p,
      ]..sort((a, b) => b.bytes.compareTo(a.bytes));

  final List<StoragePart> parts;

  int get total => parts.fold(0, (n, p) => n + p.bytes);

  /// [part]'s share of the total (0..1).
  double share(StoragePart part) => total == 0 ? 0 : part.bytes / total;
}

/// The database's own tables, by what they hold for the user, and the
/// SQL that measures each (the bytes of its text). What's left of the
/// database file is counted as "other".
const storageTables = <String, ({String about, List<String> sums})>{
  'Your writing': (
    about: 'Ink on every page, and the words read from it.',
    sums: [
      'SELECT SUM(LENGTH(strokes)) FROM page_ink',
      'SELECT SUM(LENGTH(words)) FROM page_text',
    ],
  ),
  'What the app has learned': (
    about:
        'Your corrections (with their ink) and handwriting samples, used '
        'to read your writing better.',
    sums: [
      'SELECT SUM(LENGTH(strokes) + LENGTH(recognized) + LENGTH(corrected)) '
          'FROM corrections',
      'SELECT SUM(LENGTH(strokes) + LENGTH(text)) FROM samples',
    ],
  ),
  'Search index': (
    about:
        'The printed text of your PDFs, read once so searching is instant. '
        'It\'s read again if cleared.',
    sums: ['SELECT SUM(LENGTH(text)) FROM printed_text'],
  ),
  'Diagnostic log': (
    about:
        'Timings and events kept on the tablet to find problems '
        '(Settings → Save diagnostic report).',
    sums: ['SELECT SUM(LENGTH(data) + LENGTH(type)) FROM events'],
  ),
};
