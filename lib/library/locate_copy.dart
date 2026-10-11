import '../core/stored_copy.dart';

/// Where stored copy [id] is now: [path] if the file is still there,
/// otherwise wherever the library lists it (keeping a PDF permanently moves
/// its file). Null if it can't be found.
Future<String?> locateStoredCopy({
  required String id,
  required String path,
  required Future<bool> Function(String path) fileExists,
  required Future<List<StoredCopy>> Function() listCopies,
}) async {
  if (await fileExists(path)) return path;
  for (final c in await listCopies()) {
    if (c.id == id && c.path.isNotEmpty) return c.path;
  }
  return null;
}
