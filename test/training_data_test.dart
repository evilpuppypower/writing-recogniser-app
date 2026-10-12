import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/feedback/correction.dart';
import 'package:writing_recogniser/core/ink.dart';
import 'package:writing_recogniser/core/labeled_sample.dart';
import 'package:writing_recogniser/core/training_data.dart';

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
}
