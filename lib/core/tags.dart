/// Tags for PDFs and notebooks (owner: several per document, colour-coded,
/// suggested from names and contents; notebooks and PDFs share them). Pure
/// Dart.
library;

/// The colours a tag can have (soft enough for dark and light themes).
const tagColours = [
  0xFF1E88E5, // blue
  0xFF43A047, // green
  0xFFF4511E, // orange
  0xFF8E24AA, // purple
  0xFFE53935, // red
  0xFF00897B, // teal
  0xFFFDD835, // yellow
  0xFF6D4C41, // brown
];

class Tag {
  const Tag(this.name, this.colourArgb);

  final String name;
  final int colourArgb;

  @override
  bool operator ==(Object other) =>
      other is Tag && other.name == name && other.colourArgb == colourArgb;

  @override
  int get hashCode => Object.hash(name, colourArgb);
}

/// A tag's name as kept: trimmed, single spaces, at most 30 characters.
String tidyTagName(String name) {
  final t = name.trim().replaceAll(RegExp(r'\s+'), ' ');
  return t.length > 30 ? t.substring(0, 30).trim() : t;
}

abstract class TagStore {
  /// Every tag, by name.
  Future<List<Tag>> tags();

  /// Each document's tag names (documents with none left out).
  Future<Map<String, Set<String>>> documentTags();

  /// Adds or changes a tag.
  Future<void> saveTag(Tag tag);

  /// Deletes a tag, from every document too.
  Future<void> deleteTag(String name);

  /// [documentId]'s tags become [names].
  Future<void> setDocumentTags(String documentId, Set<String> names);
}

class MemoryTagStore implements TagStore {
  final _tags = <String, Tag>{};
  final _docs = <String, Set<String>>{};

  @override
  Future<List<Tag>> tags() async =>
      _tags.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  @override
  Future<Map<String, Set<String>>> documentTags() async => {
    for (final e in _docs.entries)
      if (e.value.isNotEmpty) e.key: {...e.value},
  };

  @override
  Future<void> saveTag(Tag tag) async => _tags[tag.name] = tag;

  @override
  Future<void> deleteTag(String name) async {
    _tags.remove(name);
    for (final d in _docs.values) {
      d.remove(name);
    }
  }

  @override
  Future<void> setDocumentTags(String documentId, Set<String> names) async =>
      _docs[documentId] = {...names};
}

/// Words that say nothing about a document.
const _boring = {
  'the',
  'and',
  'for',
  'with',
  'from',
  'that',
  'this',
  'pdf',
  'copy',
  'final',
  'draft',
  'new',
  'notebook',
  'notes',
  'note',
  'page',
  'pages',
  'part',
  'week',
  'version',
  'scan',
  'scanned',
  'document',
  'file',
  'oct',
  'jan',
  'feb',
  'mar',
  'apr',
  'may',
  'jun',
  'jul',
  'aug',
  'sep',
  'nov',
  'dec',
  'are',
  'was',
  'were',
  'you',
  'your',
  'our',
  'its',
  'not',
  'but',
  'have',
  'has',
  'had',
  'will',
  'can',
  'all',
  'any',
  'one',
  'two',
  'out',
};

Iterable<String> _words(String text) sync* {
  for (final m in RegExp(r"[A-Za-z][A-Za-z'\-]{2,}").allMatches(text)) {
    final w = m.group(0)!.replaceAll(RegExp(r"['\-]+$"), '');
    if (w.length >= 3 && !_boring.contains(w.toLowerCase())) yield w;
  }
}

/// Up to [max] tags to suggest for a document named [name], whose written
/// and printed text is [contents] (empty when the user turned that off),
/// given the [known] tags and the document's own [current] ones. Known
/// tags whose name appears come first; then words from the name; then
/// words that come up often in the contents.
List<String> suggestTags({
  required String name,
  String contents = '',
  required Iterable<String> known,
  Set<String> current = const {},
  int max = 6,
}) {
  final have = {for (final c in current) c.toLowerCase()};
  final out = <String>[];
  void add(String s) {
    final t = tidyTagName(s);
    if (t.isEmpty || have.contains(t.toLowerCase())) return;
    if (out.any((o) => o.toLowerCase() == t.toLowerCase())) return;
    out.add(t);
  }

  final nameWords = {for (final w in _words(name)) w.toLowerCase()};
  final contentCounts = <String, int>{};
  final shown = <String, String>{};
  for (final w in _words(contents)) {
    final k = w.toLowerCase();
    contentCounts[k] = (contentCounts[k] ?? 0) + 1;
    // Kept as first written, capitalised where it was.
    final s = shown[k];
    if (s == null ||
        (s[0] != s[0].toUpperCase() && w[0] == w[0].toUpperCase())) {
      shown[k] = w;
    }
  }
  // Known tags the name or contents mention.
  for (final t in known) {
    final k = t.toLowerCase();
    final parts = {for (final w in _words(t)) w.toLowerCase()};
    final inName =
        nameWords.contains(k) ||
        (parts.isNotEmpty && parts.every(nameWords.contains));
    final inText = (contentCounts[k] ?? 0) >= 2;
    if (inName || inText) add(t);
  }
  // Words from the name.
  for (final w in _words(name)) {
    if (RegExp(r'^\d').hasMatch(w)) continue;
    add(w[0].toUpperCase() + w.substring(1));
  }
  // Words the contents use a lot (at least 4 times).
  final often = contentCounts.entries.where((e) => e.value >= 4).toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  for (final e in often) {
    final w = shown[e.key]!;
    add(w[0].toUpperCase() + w.substring(1));
  }
  return out.take(max).toList();
}

/// The words read from a document's handwriting (its saved text, one JSON
/// per page as InkTextController saves it), as one text.
String handwritingText(Iterable<String> pages) {
  final out = StringBuffer();
  for (final json in pages) {
    final m = RegExp(r'"text"\s*:\s*"((?:[^"\\]|\\.)*)"').allMatches(json);
    for (final x in m) {
      out
        ..write(x.group(1))
        ..write(' ');
    }
  }
  return out.toString();
}
