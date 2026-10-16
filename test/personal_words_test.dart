import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/feedback/correction.dart';
import 'package:writing_recogniser/core/feedback/feedback_layer.dart';
import 'package:writing_recogniser/core/feedback/personal_words.dart';
import 'package:writing_recogniser/core/feedback/vocabulary.dart';

import 'dart:convert';

import 'package:writing_recogniser/core/recognition/recognizer.dart';

List<Candidate> read(List<String> texts) => [
  for (final t in texts) Candidate(t),
];

FeedbackResult apply(PersonalWords p, List<String> texts, {String prev = ''}) =>
    p.apply(read(texts), FeedbackContext(previousWord: prev));

void main() {
  test('a word the user writes often wins over one they never write', () {
    final p = PersonalWords();
    for (var i = 0; i < 3; i++) {
      p.used('gneiss');
    }
    final r = apply(p, ['guess', 'gneiss', 'genies']);
    expect(r.text, 'gneiss');
    expect(r.autoReplaced, isTrue, reason: 'underlined, one tap to undo');
    expect(
      [for (final c in r.candidates) c.text],
      ['gneiss', 'guess', 'genies'],
    );
  });

  test('the engine is trusted when its reading is a word the user writes', () {
    final p = PersonalWords();
    for (var i = 0; i < 5; i++) {
      p.used('form');
    }
    p.used('from');
    final r = apply(p, ['from', 'form']);
    expect(r.text, 'from');
    expect(r.autoReplaced, isFalse);
  });

  test(
    'not until the word has been written 3 times, and only near the top',
    () {
      final p = PersonalWords();
      p
        ..used('gneiss')
        ..used('gneiss');
      expect(apply(p, ['guess', 'gneiss']).text, 'guess');
      p.used('gneiss');
      expect(apply(p, ['guess', 'gneiss']).text, 'gneiss');
      // The engine's 4th reading is too unlikely to swap to.
      expect(apply(p, ['guess', 'gees', 'genes', 'gneiss']).text, 'guess');
    },
  );

  test('the word before decides between two of the user\'s words', () {
    final p = PersonalWords();
    for (var i = 0; i < 4; i++) {
      p.used('basalt');
    }
    for (var i = 0; i < 3; i++) {
      p.used('basal', previousWord: 'the');
    }
    expect(apply(p, ['basel', 'basalt', 'basal']).text, 'basalt');
    expect(apply(p, ['basel', 'basalt', 'basal'], prev: 'the').text, 'basal');
  });

  test('a swap the user undid is never made again', () {
    final p = PersonalWords();
    for (var i = 0; i < 3; i++) {
      p.used('gneiss');
    }
    expect(apply(p, ['guess', 'gneiss']).text, 'gneiss');
    p.undone('guess', 'gneiss');
    final r = apply(p, ['guess', 'gneiss']);
    expect(r.text, 'guess');
    expect(r.autoReplaced, isFalse);
  });

  test('corrections still come first, and count as words the user writes', () {
    final p = PersonalWords();
    p.learn(
      CorrectionRecord(
        recognized: 'clog',
        corrected: 'dog',
        previousWord: '',
        strokes: const [],
        at: DateTime(2026),
      ),
    );
    // The earlier correction swaps it (as before).
    expect(apply(p, ['clog', 'dig']).text, 'dog');
    expect(p.usesOf('dog'), 1);
  });

  test('the vocabulary leaves out words the user didn\'t write or keep', () {
    final page = jsonEncode({
      'words': [
        {'text': 'basalt', 'prev': 'the'},
        {'text': 'fox', 'corrected': true}, // counted with its correction
        {'text': 'gneiss', 'auto': true}, // the app's choice
        {'text': 'w3', 'unsure': true}, // maybe misread, never confirmed
        {'text': ' '},
      ],
    });
    expect(vocabularyFromPages([page, 'not json']), [
      (word: 'basalt', previous: 'the'),
    ]);
  });

  test('nothing to work with: unchanged', () {
    final p = PersonalWords();
    expect(apply(p, []).candidates, isEmpty);
    expect(apply(p, ['word']).text, 'word');
  });
}
