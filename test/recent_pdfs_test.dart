import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/recent_pdfs.dart';

RecentPdf pdf(String name, {String? uri, String? id, int day = 1}) => RecentPdf(
  uri: uri ?? 'content://docs/$name',
  name: name,
  cacheId: id ?? '1_1_$name',
  lastOpened: DateTime(2026, 10, day),
);

void main() {
  test('saves and loads', () {
    final r = pdf('Lecture 3.pdf', day: 10);
    final back = RecentPdf.fromJson(r.toJson());
    expect(back.uri, r.uri);
    expect(back.name, r.name);
    expect(back.cacheId, r.cacheId);
    expect(back.lastOpened, r.lastOpened);
  });

  test('newly opened goes to the front', () {
    final list = recordOpened([pdf('a'), pdf('b')], pdf('c'));
    expect(list.map((r) => r.name), ['c', 'a', 'b']);
  });

  test('reopening moves it to the front without duplicating', () {
    final list = recordOpened([pdf('a'), pdf('b'), pdf('c')], pdf('b', day: 9));
    expect(list.map((r) => r.name), ['b', 'a', 'c']);
    expect(list.first.lastOpened.day, 9);
  });

  test('a changed file at the same location replaces its old entry', () {
    final old = pdf('notes.pdf', id: '100_1_notes.pdf');
    final edited = pdf('notes.pdf', id: '120_2_notes.pdf');
    expect(recordOpened([old], edited).map((r) => r.cacheId), [
      '120_2_notes.pdf',
    ]);
  });

  test('remembers every PDF, with no limit', () {
    var list = <RecentPdf>[];
    for (var i = 0; i < 500; i++) {
      list = recordOpened(list, pdf('f$i'));
    }
    expect(list, hasLength(500));
    expect(list.first.name, 'f499');
    expect(list.last.name, 'f0');
  });

  test('remove', () {
    final list = removeRecent([pdf('a'), pdf('b')], pdf('a'));
    expect(list.map((r) => r.name), ['b']);
  });
}
