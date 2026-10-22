/// Going through the words read from the user's PDFs to say they're right
/// or fix them ("Review my writing", owner 2026-10-22): which words still
/// need a look, and each answer applied to a page's saved words. No
/// screen code, so it can be tested on its own.
library;

import 'dart:convert';

import '../viewer/ink_text_controller.dart';

/// One word to look at: where it is and what was read (its ink is read
/// only when it's shown, see [loadWord]: all of it at once could be too
/// much for a big library).
class ReviewItem {
  const ReviewItem(
    this.documentId,
    this.page,
    this.key,
    this.text, {
    this.unsure = false,
  });

  final String documentId;
  final int page;

  /// The word's key (see wordKey) and its reading when listed.
  final String key;
  final String text;
  final bool unsure;
}

/// The words in [texts] (document -> page -> saved words, as
/// InkTextController.pageJson saves them) the user hasn't fixed or said
/// are right: the unsure ones (shown with a "?") first, then the rest in
/// page order. Words with no ink kept, and [skipDocument] (the PDF open
/// now, which saves its own words), are left out.
List<ReviewItem> wordsToReview(
  Map<String, Map<int, String>> texts, {
  String? skipDocument,
}) {
  final unsure = <ReviewItem>[], rest = <ReviewItem>[];
  final docs = texts.keys.toList()..sort();
  for (final doc in docs) {
    if (doc == skipDocument) continue;
    final pages = texts[doc]!.keys.toList()..sort();
    for (final page in pages) {
      for (final w in _words(texts[doc]![page]!)) {
        if (w['corrected'] == true || w['checked'] == true) continue;
        final ink = w['ink'];
        if (ink is! List || ink.isEmpty) continue;
        final item = ReviewItem(
          doc,
          page,
          '${w['key'] ?? ''}',
          '${w['text'] ?? ''}',
          unsure: w['unsure'] == true,
        );
        (item.unsure ? unsure : rest).add(item);
      }
    }
  }
  return [...unsure, ...rest];
}

/// A page's saved words as they are (not turned into words, so their ink
/// isn't read), in reading order.
List<Map<Object?, Object?>> _words(String json) {
  try {
    final j = jsonDecode(json);
    if (j is! Map) return const [];
    final words = [
      for (final w in j['words'] as List? ?? const [])
        if (w is Map && w['box'] is List && (w['box'] as List).length == 4) w,
    ];
    num left(Map w) => (w['box'] as List).first as num;
    num line(Map w) => (w['line'] as num?) ?? 0;
    words.sort(
      (a, b) => line(a) != line(b)
          ? line(a).compareTo(line(b))
          : left(a).compareTo(left(b)),
    );
    return words;
  } catch (_) {
    return const []; // unreadable: left alone
  }
}

/// Word [key] of [pageJson] in full (with its ink), or null if it's gone.
RecognizedWord? loadWord(String pageJson, String key) {
  try {
    final j = jsonDecode(pageJson);
    if (j is! Map) return null;
    for (final w in j['words'] as List? ?? const []) {
      if (w is Map && w['key'] == key) {
        return RecognizedWord.fromJson(w.cast<String, Object?>());
      }
    }
  } catch (_) {}
  return null;
}

/// [pageJson] with the word [key] answered: right as read (when [text] is
/// null or the same), or really [text]. Null when the word isn't there any
/// more, or no longer reads [shown] (the page was read again since).
String? answerWord(String pageJson, String key, {String? text, String? shown}) {
  final j = jsonDecode(pageJson);
  if (j is! Map) return null;
  final words = [
    for (final w in j['words'] as List? ?? const [])
      RecognizedWord.fromJson((w as Map).cast<String, Object?>()),
  ];
  final i = words.indexWhere((w) => w.key == key);
  // Gone, or read differently since it was shown ([shown]).
  if (i < 0 || (shown != null && words[i].text != shown)) return null;
  final w = words[i];
  final t = text?.trim();
  words[i] = t == null || t.isEmpty || t == w.text
      ? w.copyWith(unsure: false, checked: true)
      : w.copyWith(
          text: t,
          alternatives: [
            w.engineReading,
            ...w.alternatives.where((a) => a != t && a != w.engineReading),
          ],
          corrected: true,
          autoReplaced: false,
          unsure: false,
        );
  return jsonEncode({
    ...j,
    'words': [for (final w in words) w.toJson()],
  });
}
