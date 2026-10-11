import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/stored_copy.dart';

StoredCopy copy(String id, {int minutesAgo = 0, bool pinned = false}) =>
    StoredCopy(
      id: id,
      size: 1,
      lastUsed: DateTime(
        2026,
        10,
        10,
        12,
      ).subtract(Duration(minutes: minutesAgo)),
      pinned: pinned,
    );

void main() {
  test('reads the map sent by Android', () {
    final c = StoredCopy.fromMap({
      'id': '419430400_1760000000000_Textbook.pdf',
      'size': 419430400,
      'lastUsed': DateTime(2026, 1, 1, 12, 0).millisecondsSinceEpoch,
      'pinned': true,
    });
    expect(c.size, 419430400);
    expect(c.pinned, isTrue);
    expect(c.lastUsed, DateTime(2026, 1, 1, 12, 0));
  });

  group('displayName strips the storage prefix', () {
    test('normal name', () {
      expect(
        copy('5242880_1760000000000_Lecture 3.pdf').displayName,
        'Lecture 3.pdf',
      );
    });
    test('unknown size and date', () {
      expect(copy('-1_0_notes.pdf').displayName, 'notes.pdf');
    });
    test('underscores in the original name are kept', () {
      expect(copy('10_20_week_1_slides.pdf').displayName, 'week_1_slides.pdf');
    });
    test('unexpected file name is shown as is', () {
      expect(copy('odd.pdf').displayName, 'odd.pdf');
    });
  });

  test('sorts pinned first, then most recently used', () {
    final sorted = sortForDisplay([
      copy('old', minutesAgo: 30),
      copy('pinned-old', minutesAgo: 60, pinned: true),
      copy('new', minutesAgo: 1),
      copy('pinned-new', minutesAgo: 5, pinned: true),
    ]);
    expect(sorted.map((c) => c.id), ['pinned-new', 'pinned-old', 'new', 'old']);
  });

  test('formatDateTime', () {
    expect(formatDateTime(DateTime(2026, 1, 2, 14, 5)), '2 Jan 2026, 14:05');
    expect(formatDateTime(DateTime(2027, 1, 2, 9, 30)), '2 Jan 2027, 09:30');
  });
}
