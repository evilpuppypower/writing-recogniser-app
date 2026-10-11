/// A copy of an imported PDF kept in app storage so it reopens instantly.
/// Pure Dart so it can be unit-tested and reused on Windows.
library;

class StoredCopy {
  const StoredCopy({
    required this.id,
    required this.size,
    required this.lastUsed,
    required this.pinned,
    this.path = '',
  });

  factory StoredCopy.fromMap(Map<Object?, Object?> m) => StoredCopy(
    id: m['id']! as String,
    size: (m['size']! as num).toInt(),
    lastUsed: DateTime.fromMillisecondsSinceEpoch(
      (m['lastUsed']! as num).toInt(),
    ),
    pinned: m['pinned']! as bool,
    path: m['path'] as String? ?? '',
  );

  /// File name in app storage: `<size>_<modified>_<original name>`.
  final String id;

  /// Where the copy is stored on the tablet.
  final String path;
  final int size;

  /// When the copy was last imported or opened.
  final DateTime lastUsed;

  /// Pinned copies are never removed automatically and don't count toward
  /// the "keep the last N PDFs" limit.
  final bool pinned;

  /// The original file name, without the size/date prefix used for storage.
  String get displayName {
    final match = RegExp(r'^-?\d+_-?\d+_(.+)$').firstMatch(id);
    return match?.group(1) ?? id;
  }
}

/// Sorts copies for display: pinned first, then most recently used first.
List<StoredCopy> sortForDisplay(Iterable<StoredCopy> copies) =>
    copies.toList()..sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.lastUsed.compareTo(a.lastUsed);
    });

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "1 Jan 2026, 12:00" in the tablet's local time.
String formatDateTime(DateTime t) {
  final l = t.toLocal();
  final hh = l.hour.toString().padLeft(2, '0');
  final mm = l.minute.toString().padLeft(2, '0');
  return '${l.day} ${_months[l.month - 1]} ${l.year}, $hh:$mm';
}
