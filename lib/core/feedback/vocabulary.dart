/// The user's vocabulary from their saved pages (see PersonalWords). Pure
/// Dart, so it can run away from the screen's thread: on a tablet full of
/// writing it reads a lot.
library;

import 'dart:convert';

/// A word the user wrote, and the word before it.
typedef UsedWord = ({String word, String previous});

/// The words the user wrote and kept, from saved page text ([pages], as
/// InkTextController.pageJson makes it). Left out: words the user
/// corrected (their corrections already count), words swapped
/// automatically (the app's choice, not the user's), and words the app
/// wasn't sure of and the user never confirmed (they may be misread).
/// Only each word's text is read, not its ink.
List<UsedWord> vocabularyFromPages(List<String> pages) {
  final out = <UsedWord>[];
  for (final json in pages) {
    try {
      final saved = jsonDecode(json) as Map;
      for (final w in saved['words'] as List) {
        if (w is! Map) continue;
        final text = w['text'];
        if (text is! String || text.trim().isEmpty) continue;
        if (w['corrected'] == true || w['auto'] == true) continue;
        if (w['unsure'] == true) continue;
        final prev = w['prev'];
        out.add((word: text, previous: prev is String ? prev : ''));
      }
    } catch (_) {
      // A page that can't be read just doesn't count.
    }
  }
  return out;
}
