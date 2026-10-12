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

const trainingDataFormat = 'writing-recogniser-training-data';
const trainingDataVersion = 1;
const trainingDataEntry = 'training-data.json';

/// "training-data-20260131.zip" (the date only).
String trainingDataFileName(DateTime now) {
  final d = now.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return 'training-data-${d.year}${two(d.month)}${two(d.day)}.zip';
}

/// The zip file's bytes.
List<int> encodeTrainingData({
  required List<CorrectionRecord> corrections,
  required List<LabeledSample> samples,
  required DateTime exportedAt,
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
    },
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
  };
  // Not indented: with every ink point on its own line the file would be
  // several times bigger.
  final json = utf8.encode(jsonEncode(doc));
  return ZipEncoder().encodeBytes(
    Archive()..add(ArchiveFile.bytes(trainingDataEntry, json)),
  );
}
