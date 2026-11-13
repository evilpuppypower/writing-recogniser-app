import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/feedback/regional_spelling.dart';
import 'package:writing_recogniser/recognition/mlkit_recognizer.dart';

void main() {
  test('the English chosen in Settings is tried first', () {
    expect(MlKitRecognizer.englishTagsFor(EnglishSpelling.british), [
      'en-GB',
      'en-US',
      'en',
    ]);
    expect(MlKitRecognizer.englishTagsFor(EnglishSpelling.american), [
      'en-US',
      'en-GB',
      'en',
    ]);
  });
}
