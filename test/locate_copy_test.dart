import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/stored_copy.dart';
import 'package:writing_recogniser/library/locate_copy.dart';

void main() {
  StoredCopy copy(String id, String path) => StoredCopy(
    id: id,
    size: 1,
    lastUsed: DateTime(2026),
    pinned: true,
    path: path,
  );

  test('keeps the path while the file is still there', () async {
    var listed = false;
    final found = await locateStoredCopy(
      id: 'a',
      path: '/imports/a.pdf',
      fileExists: (p) async => true,
      listCopies: () async {
        listed = true;
        return [];
      },
    );
    expect(found, '/imports/a.pdf');
    expect(listed, isFalse);
  });

  test('finds the copy after it was moved (kept permanently)', () async {
    final found = await locateStoredCopy(
      id: 'a',
      path: '/imports/a.pdf',
      fileExists: (p) async => p == '/imports/pinned/a.pdf',
      listCopies: () async => [
        copy('b', '/imports/b.pdf'),
        copy('a', '/imports/pinned/a.pdf'),
      ],
    );
    expect(found, '/imports/pinned/a.pdf');
  });

  test('null when the copy is gone', () async {
    final found = await locateStoredCopy(
      id: 'a',
      path: '/imports/a.pdf',
      fileExists: (p) async => false,
      listCopies: () async => [copy('b', '/imports/b.pdf')],
    );
    expect(found, isNull);
  });
}
