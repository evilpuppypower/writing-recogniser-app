import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/viewer/page_text_labels.dart';

void main() {
  test('labels grow with the handwriting when zooming in, without limit', () {
    // A 20 pt word at 1, 2 and 4 pixels per point.
    expect(labelFontSize(20, 1), 9);
    expect(labelFontSize(20, 2), 18);
    expect(labelFontSize(20, 4), 36);
    expect(labelFontSize(20, 8), 72);
  });

  test('but never too small to read', () {
    expect(labelFontSize(5, 1), minLabelFontSize);
    expect(labelFontSize(0, 3), minLabelFontSize);
  });
}
