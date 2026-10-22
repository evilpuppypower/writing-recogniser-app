/// Training data export (task 4.1, preparatory: GATE B decides whether a
/// personal model is built). Gathers the user's corrections (with their
/// ink, CLAUDE.md rule 4) and handwriting samples into one file the user
/// saves on the tablet. Nothing is sent anywhere. Pure Dart.
///
/// The file holds handwriting, which identifies a person, so it carries
/// nothing else: times are UTC, and PDFs are numbered, not named.
library;

import 'dart:convert';

import 'package:archive/archive.dart';

import 'feedback/correction.dart';
import 'ink.dart';
import 'labeled_sample.dart';
import 'page_ink.dart';
import 'replay_cases.dart';
import 'word_pairs.dart';

const trainingDataFormat = 'writing-recogniser-training-data';
const trainingDataVersion = 3;
const trainingDataEntry = 'training-data.json';

/// "training-data-20260131.zip" (the date only).
String trainingDataFileName(DateTime now) {
  final d = now.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return 'training-data-${d.year}${two(d.month)}${two(d.day)}.zip';
}

/// A PDF page's saved recognition (the app's `page_text` rows: what each
/// word was read as, with its ink), for [encodeTrainingData].
typedef SavedPageText = ({String document, String json});

/// A PDF page's ink as saved (the app's `page_ink` rows: a JSON list of
/// strokes), for [encodeTrainingData].
typedef SavedPageInk = ({String document, String json});

/// The zip file's bytes. Version 2 (task 4.1b) adds every word read on PDF
/// pages ([pageTexts]: right or corrected, with the engine's other
/// readings) and the samples split into words, so a model can learn to
/// pick the right reading, not only from mistakes. Version 3 (task 4.5)
/// adds "wordPairs" from the pages' ink ([pageInk]), for learning which
/// strokes make one word.
List<int> encodeTrainingData({
  required List<CorrectionRecord> corrections,
  required List<LabeledSample> samples,
  required DateTime exportedAt,
  List<SavedPageText> pageTexts = const [],
  List<SavedPageInk> pageInk = const [],
}) {
  final documents = <String, int>{};
  int? documentNumber(String? id) =>
      id == null ? null : documents.putIfAbsent(id, () => documents.length + 1);
  List<List<List<num>>> strokes(List<InkStroke> s) => [
    for (final stroke in s) stroke.toJson(),
  ];
  final doc = {
    'format': trainingDataFormat,
    'version': trainingDataVersion,
    'exportedAt': exportedAt.toUtc().toIso8601String(),
    // So the file explains itself to whoever uses it later.
    'about': {
      'corrections':
          'Words the recognizer misread and what they really said, with '
          'the word\'s ink. "count" is how many times the same correction '
          'was made; "document" numbers the PDFs (1, 2, ...) without '
          'naming them.',
      'samples':
          'Sentences written on request in the handwriting test, with '
          'their ink.',
      'stroke': 'list of [x, y, t, pressure] points, pen-down to pen-up',
      'x, y (corrections)':
          'pixels, from the word\'s top-left corner, scaled so a typical '
          'letter is about 50 high (as sent to the recognizer)',
      'x, y (samples)': 'logical pixels from the top-left of the writing area',
      't': 'milliseconds since 1970-01-01 UTC',
      'pressure': '0..1 (0.5 if the pen did not report it)',
      'words':
          'Every word read on PDF pages, as last saved: "text" is what it '
          'shows now, "engine" what the recognizer read, "candidates" the '
          'recognizer\'s readings, best first (complete only when '
          '"candidatesComplete"; older words have a partial list). '
          '"corrected" means the user fixed it and "checked" that they '
          'said it was right (either way "text" is certain); '
          'otherwise the user left it as shown (usually right, but not '
          'checked; "autoReplaced" means the app swapped the engine\'s word '
          'for an earlier correction). Ink as for corrections.',
      'sampleWords':
          'The samples split into words the way PDF pages are, with the '
          'word written; samples whose ink split into a different number '
          'of words are left out. x, y as for samples.',
      'wordPairs':
          'Neighbouring strokes on a line next to a "One word" mark the '
          'user made: "features" are numbers describing the pair (named '
          'in "wordPairFeatures"), "sameWord" whether the user said they '
          'are one word. No ink.',
    },
    'wordPairFeatures': wordPairFeatures,
    'corrections': [
      for (final c in corrections)
        {
          'recognized': c.recognized,
          'corrected': c.corrected,
          'previousWord': c.previousWord,
          'count': c.count,
          'at': c.at.toUtc().toIso8601String(),
          'document': ?documentNumber(c.documentId),
          'strokes': strokes(c.strokes),
        },
    ],
    'samples': [
      for (final s in samples)
        {
          'text': s.text,
          'at': s.createdAt.toUtc().toIso8601String(),
          'canvasWidth': ?s.canvasWidth,
          'canvasHeight': ?s.canvasHeight,
          'strokes': strokes(s.strokes),
        },
    ],
    'words': [
      for (final p in pageTexts) ..._pageWords(p, documentNumber(p.document)),
    ],
    'sampleWords': [
      for (final c in wordsFromSamples(samples).cases)
        {
          'text': c.truth,
          'previousWord': c.previousWord,
          'strokes': strokes(c.strokes),
        },
    ],
    'wordPairs': [
      for (final p in pageInk)
        for (final pair in _pagePairs(p))
          {...pair.toJson(), 'document': ?documentNumber(p.document)},
    ],
  };
  // Not indented: with every ink point on its own line the file would be
  // several times bigger.
  final json = utf8.encode(jsonEncode(doc));
  return ZipEncoder().encodeBytes(
    Archive()..add(ArchiveFile.bytes(trainingDataEntry, json)),
  );
}

/// The words of one saved page, for the training file. A page whose saved
/// text can't be read is left out.
List<Map<String, Object?>> _pageWords(SavedPageText page, int? document) {
  try {
    final saved = (jsonDecode(page.json) as Map).cast<String, Object?>();
    return [
      for (final w in (saved['words'] as List? ?? const []).cast<Map>())
        if (w['text'] is String && w['ink'] is List)
          () {
            final text = w['text'] as String;
            final engine = w['engine'] as String? ?? text;
            final readings = w['readings'];
            return <String, Object?>{
              'text': text,
              'engine': engine,
              // The engine's own list, best first; words saved before it was
              // kept only have a partial one (corrections changed it).
              'candidates': readings is List
                  ? [for (final r in readings) '$r']
                  : {
                      engine,
                      for (final a in w['alt'] as List? ?? const []) '$a',
                    }.toList(),
              'candidatesComplete': readings is List,
              'corrected': w['corrected'] == true,
              'checked': w['checked'] == true,
              'autoReplaced': w['auto'] == true,
              'previousWord': w['prev'] as String? ?? '',
              'document': ?document,
              'strokes': w['ink'],
            };
          }(),
    ];
  } catch (_) {
    return const [];
  }
}

/// The labelled word pairs of one page's ink. A page whose ink can't be
/// read is left out.
List<WordPair> _pagePairs(SavedPageInk page) {
  try {
    return wordPairs([
      for (final s in jsonDecode(page.json) as List)
        PageStroke.fromJson((s as Map).cast<String, Object?>()),
    ]);
  } catch (_) {
    return const [];
  }
}
