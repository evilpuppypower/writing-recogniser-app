import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/page_layout.dart';
import 'package:writing_recogniser/core/quick_note.dart';

void main() {
  test('the first quick note makes the notebook', () {
    final q = addQuickNote(null, paper: Paper.dotted);
    expect(q.page, 1);
    expect(q.layout.notebook, isTrue);
    expect(q.layout.title, quickNotesTitle);
    expect(q.layout.at(1).paper, Paper.dotted);
  });

  test('then a new page at the end, like the last one', () {
    final first = addQuickNote(
      null,
      paper: Paper.squared,
      width: 420,
      height: 595,
    );
    final second = addQuickNote(first.layout);
    expect(second.page, 2);
    expect(second.layout.length, 2);
    expect(second.layout.at(2).paper, Paper.squared);
    expect(second.layout.at(2).width, 420);
    expect(second.layout.keyAt(2), isNot(second.layout.keyAt(1)));
  });

  test('an empty last page is used again', () {
    final first = addQuickNote(null);
    final again = addQuickNote(first.layout, lastPageEmpty: true);
    expect(again.page, 1);
    expect(again.layout.length, 1);
  });
}
