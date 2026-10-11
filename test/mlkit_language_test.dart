import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/recognition/mlkit_recognizer.dart';

void main() {
  test("the device's English variant is tried first", () {
    expect(MlKitRecognizer.englishTagsFor(const Locale('en', '001')), [
      'en-001',
      'en-GB',
      'en-US',
      'en',
    ]);
    expect(MlKitRecognizer.englishTagsFor(const Locale('en', 'US')), [
      'en-US',
      'en-GB',
      'en',
    ]);
  });

  test('other languages and plain English fall back to common variants', () {
    for (final l in [const Locale('fr', 'FR'), const Locale('en')]) {
      expect(MlKitRecognizer.englishTagsFor(l), ['en-GB', 'en-US', 'en']);
    }
  });
}
