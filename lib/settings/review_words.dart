/// Going through the words read from the user's PDFs to say they're right
/// or fix them ("Review my writing", owner 2026-10-22): which words still
/// need a look, and each answer applied to a page's saved words. No
/// screen code, so it can be tested on its own.
library;

import 'dart:convert';

import '../viewer/ink_text_controller.dart';

/// One word to look at: where it is and what was read.
class ReviewItem {
  const ReviewItem(this.documentId, this.page, this.word);

  final String documentId;
  final int page;
  final RecognizedWord word;
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
        if (w.corrected || w.checked || w.ink.isEmpty) continue;
        (w.unsure ? unsure : rest).add(ReviewItem(doc, page, w));
      }
    }
  }
  return [...unsure, ...rest];
}

List<RecognizedWord> _words(String json) {
  try {
    final j = jsonDecode(json);
    if (j is! Map) return const [];
    final words = [
      for (final w in j['words'] as List? ?? const [])
        RecognizedWord.fromJson((w as Map).cast<String, Object?>()),
    ];
    words.sort(
      (a, b) => a.line != b.line
          ? a.line.compareTo(b.line)
          : a.box.left.compareTo(b.box.left),
    );
    return words;
  } catch (_) {
    return const []; // unreadable: left alone
  }
}

/// [pageJson] with the word [key] answered: right as read (when [text] is
/// null or the same), or really [text]. Null when the word isn't there any
/// more (the page was read again since).
String? answerWord(String pageJson, String key, {String? text}) {
  final j = jsonDecode(pageJson);
  if (j is! Map) return null;
  final words = [
    for (final w in j['words'] as List? ?? const [])
      RecognizedWord.fromJson((w as Map).cast<String, Object?>()),
  ];
  final i = words.indexWhere((w) => w.key == key);
  if (i < 0) return null;
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
