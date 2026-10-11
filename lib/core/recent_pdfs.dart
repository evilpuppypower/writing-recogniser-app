/// The list of PDFs the user has opened, shown on the home page.
/// Pure Dart so it can be unit-tested and reused on Windows.
library;

class RecentPdf {
  const RecentPdf({
    required this.uri,
    required this.name,
    required this.cacheId,
    required this.lastOpened,
  });

  factory RecentPdf.fromJson(Map<String, Object?> j) => RecentPdf(
    uri: j['uri']! as String,
    name: j['name']! as String,
    cacheId: j['cacheId']! as String,
    lastOpened: DateTime.fromMillisecondsSinceEpoch(
      (j['lastOpened']! as num).toInt(),
    ),
  );

  /// Where the original file is (an Android content:// URI). Used to import
  /// it again if its stored copy has been removed.
  final String uri;
  final String name;

  /// Identifies the stored copy (and first-page picture) for this file.
  final String cacheId;
  final DateTime lastOpened;

  Map<String, Object?> toJson() => {
    'uri': uri,
    'name': name,
    'cacheId': cacheId,
    'lastOpened': lastOpened.millisecondsSinceEpoch,
  };
}

/// Returns [list] with [opened] moved (or added) to the front. An older
/// entry for the same file (same location or same stored copy) is replaced.
/// There is no limit on how many PDFs are remembered.
List<RecentPdf> recordOpened(List<RecentPdf> list, RecentPdf opened) => [
  opened,
  ...list.where((r) => r.uri != opened.uri && r.cacheId != opened.cacheId),
];

/// Returns [list] without [removed].
List<RecentPdf> removeRecent(List<RecentPdf> list, RecentPdf removed) =>
    list.where((r) => r.cacheId != removed.cacheId).toList();
