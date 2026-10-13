import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/feedback/correction.dart';
import 'package:writing_recogniser/core/ink.dart';
import 'package:writing_recogniser/core/labeled_sample.dart';
import 'package:writing_recogniser/core/recognition/recognizer.dart';
import 'package:writing_recogniser/core/stroke_grouping.dart' show InkBox;
import 'package:writing_recogniser/core/training_data.dart';
import 'package:writing_recogniser/viewer/ink_text_controller.dart';

const ink = [
  InkStroke([InkPoint(0, 0, 1000, 0.4), InkPoint(5, 9, 1040, 0.6)]),
];

Map<String, dynamic> decode(List<int> zip) {
  final entry = ZipDecoder().decodeBytes(zip).findFile(trainingDataEntry)!;
  return jsonDecode(utf8.decode(entry.content)) as Map<String, dynamic>;
}

void main() {
  test('corrections and samples, with ink, in one self-describing file', () {
    final doc = decode(
      encodeTrainingData(
        corrections: [
          CorrectionRecord(
            recognized: 'mad',
            corrected: 'moved',
            previousWord: 'meeting',
            strokes: ink,
            count: 2,
            at: DateTime.utc(2026, 1, 5, 9),
            documentId: '1234_9_Private name.pdf',
          ),
          CorrectionRecord(
            recognized: 'dag',
            corrected: 'dog',
            previousWord: '',
            strokes: ink,
            at: DateTime.utc(2026, 1, 6, 9),
            documentId: '5678_2_Other.pdf',
          ),
        ],
        samples: [
          LabeledSample(
            text: 'The quick brown fox.',
            strokes: ink,
            createdAt: DateTime.utc(2026, 1, 4, 8),
          ),
        ],
        exportedAt: DateTime.utc(2026, 1, 7),
      ),
    );
    expect(doc['format'], trainingDataFormat);
    expect(doc['about'], isA<Map<String, dynamic>>());
    final c = (doc['corrections'] as List).cast<Map<String, dynamic>>();
    expect(c.first['corrected'], 'moved');
    expect(c.first['count'], 2);
    expect(c.first['strokes'], [
      [
        [0, 0, 1000, 0.4],
        [5, 9, 1040, 0.6],
      ],
    ]);
    expect([for (final x in c) x['document']], [1, 2]);
    expect((doc['samples'] as List).single['text'], 'The quick brown fox.');
  });

  test('nothing else about the user: UTC times, PDFs numbered not named', () {
    final local = DateTime(2026, 1, 5, 9, 30); // the tablet's local time
    final text = utf8.decode(
      ZipDecoder()
          .decodeBytes(
            encodeTrainingData(
              corrections: [
                CorrectionRecord(
                  recognized: 'a',
                  corrected: 'b',
                  previousWord: '',
                  strokes: ink,
                  at: local,
                  documentId: '1234_9_Private name.pdf',
                ),
              ],
              samples: const [],
              exportedAt: local,
            ),
          )
          .findFile(trainingDataEntry)!
          .content,
    );
    expect(text, isNot(contains('Private name')));
    expect(text, contains(local.toUtc().toIso8601String()));
    expect(
      trainingDataFileName(DateTime.utc(2026, 1, 31, 23)),
      'training-data-20260131.zip',
    );
  });

  test('version 2: every word read on PDF pages, and samples as words', () {
    RecognizedWord w(
      String text, {
      String? engine,
      bool corrected = false,
      List<String>? readings,
    }) => RecognizedWord(
      text: text,
      alternatives: ['alt'],
      box: const InkBox(0, 0, 10, 10),
      line: 0,
      key: 'k$text',
      engineText: engine,
      corrected: corrected,
      previousWord: 'the',
      ink: ink,
      engineReadings: readings,
    );
    // Saved as the app saves a page (checked against the controller).
    final c = InkTextController(engine: _NoEngine());
    c.restore(
      3,
      jsonEncode({
        'seen': ['a'],
        'words': [
          w(
            'car',
            engine: 'cat',
            corrected: true,
            readings: ['cat', 'car'],
          ).toJson(),
          w('cat').toJson(),
          w('dog', engine: 'dag', corrected: true).toJson(),
        ],
      }),
    );
    final page = c.pageJson(3)!;
    c.dispose();
    final doc = decode(
      encodeTrainingData(
        corrections: [
          CorrectionRecord(
            recognized: 'dag',
            corrected: 'dog',
            previousWord: 'the',
            strokes: ink,
            at: DateTime.utc(2026, 1, 6),
            documentId: '5678_2_Other.pdf',
          ),
        ],
        samples: [
          LabeledSample(
            text: 'hi',
            strokes: ink,
            createdAt: DateTime.utc(2026, 1, 4),
          ),
        ],
        pageTexts: [
          (document: '5678_2_Other.pdf', json: page),
          (document: '9_Private name.pdf', json: 'not json'),
        ],
        exportedAt: DateTime.utc(2026, 1, 7),
      ),
    );
    expect(doc['version'], 2);
    final words = (doc['words'] as List).cast<Map<String, dynamic>>();
    expect(words.map((x) => x['text']), ['car', 'cat', 'dog']);
    // The engine's own list: the corrected word is in it.
    expect(words.first['candidates'], ['cat', 'car']);
    expect(words.first['candidatesComplete'], isTrue);
    expect(words[1]['corrected'], isFalse);
    expect(words[1]['candidates'], ['cat', 'alt']);
    expect(words.last['engine'], 'dag');
    expect(words.last['corrected'], isTrue);
    expect(words.last['candidates'], ['dag', 'alt']);
    expect(words.last['candidatesComplete'], isFalse, reason: 'older word');
    expect(words.last['previousWord'], 'the');
    expect(words.last['strokes'], hasLength(1));
    // The same PDF number as its corrections, and no names.
    expect(words.first['document'], 1);
    expect(jsonEncode(doc), isNot(contains('Private')));
    expect(jsonEncode(doc), isNot(contains('Other')));
    // One stroke, one word: the sample becomes one word.
    expect((doc['sampleWords'] as List).single['text'], 'hi');
  });
}

class _NoEngine implements Recognizer {
  @override
  String get name => 'None';
  @override
  bool get onDevice => true;
  @override
  Future<RecognizerStatus> status() async =>
      const RecognizerStatus(RecognizerState.ready);
  @override
  Future<void> prepare({void Function(double? progress)? onProgress}) async {}
  @override
  Future<List<Candidate>> recognize(
    List<InkStroke> strokes,
    RecognitionContext context,
  ) async => const [];
}
