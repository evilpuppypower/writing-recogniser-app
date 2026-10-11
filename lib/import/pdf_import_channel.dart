import 'dart:async';

import 'package:flutter/services.dart';

import '../core/stored_copy.dart';

/// A PDF the user picked with the system file picker.
class PickedPdf {
  const PickedPdf({
    required this.uri,
    required this.name,
    required this.size,
    required this.modified,
    required this.cacheId,
    this.cachedPath,
  });

  factory PickedPdf.fromMap(Map<Object?, Object?> m) => PickedPdf(
    uri: m['uri']! as String,
    name: m['name']! as String,
    size: (m['size']! as num).toInt(),
    modified: (m['modified'] as num?)?.toInt() ?? 0,
    cacheId: m['cacheId'] as String? ?? '',
    cachedPath: m['cachedPath'] as String?,
  );

  /// content:// URI of the original file. It is only ever read.
  final String uri;
  final String name;

  /// Size in bytes, or -1 if the file provider didn't say.
  final int size;

  /// Last-modified time in ms since epoch, or 0 if unknown.
  final int modified;

  /// Identifies this file's stored copy and first-page picture.
  final String cacheId;

  /// Path of an existing copy from an earlier import, if there is one.
  final String? cachedPath;
}

/// Thrown when the user cancels an import.
class ImportCancelled implements Exception {
  const ImportCancelled();
}

/// Talks to the Android side (`PdfImporter.kt`): opens the system PDF picker
/// and copies the chosen file into app storage with progress updates.
class PdfImportChannel {
  static const _methods = MethodChannel('writing_recogniser/pdf_import');
  static const _progress = EventChannel(
    'writing_recogniser/pdf_import/progress',
  );

  /// Opens the system file picker. Returns null if the user backs out.
  static Future<PickedPdf?> pick() async {
    final result = await _methods.invokeMapMethod<Object?, Object?>('pick');
    return result == null ? null : PickedPdf.fromMap(result);
  }

  /// Looks up a file picked earlier (from the Recent list). Returns null if
  /// it was moved or deleted, or the app no longer has access to it.
  static Future<PickedPdf?> inspect(String uri) async {
    try {
      final m = await _methods.invokeMapMethod<Object?, Object?>('inspect', {
        'uri': uri,
      });
      return m == null ? null : PickedPdf.fromMap(m);
    } on PlatformException {
      return null;
    }
  }

  /// Gives back the app's kept access to a file that left the Recent list.
  static Future<void> releaseAccess(String uri) =>
      _methods.invokeMethod<void>('releaseAccess', {'uri': uri});

  /// Copies [pdf] into app storage and returns the copy's path. Older copies
  /// are deleted so that at most [keep] are stored, including this one.
  /// [onProgress] receives (bytesCopied, totalBytes); totalBytes is -1 if
  /// unknown. Throws [ImportCancelled] if [cancel] is called.
  static Future<String> copy(
    PickedPdf pdf, {
    required int keep,
    required void Function(int copied, int total) onProgress,
  }) async {
    final sub = _progress.receiveBroadcastStream().listen((event) {
      final m = event as Map<Object?, Object?>;
      onProgress((m['copied']! as num).toInt(), (m['total']! as num).toInt());
    });
    try {
      final path = await _methods.invokeMethod<String>('copy', {
        'uri': pdf.uri,
        'name': pdf.name,
        'size': pdf.size,
        'modified': pdf.modified,
        'keep': keep,
      });
      return path!;
    } on PlatformException catch (e) {
      if (e.code == 'cancelled') throw const ImportCancelled();
      rethrow;
    } finally {
      await sub.cancel();
    }
  }

  static Future<void> cancel() => _methods.invokeMethod<void>('cancel');

  /// How many PDF copies are stored and how many bytes they use.
  static Future<({int count, int bytes})> cacheInfo() async {
    final m = (await _methods.invokeMapMethod<String, Object?>('cacheInfo'))!;
    return (
      count: (m['count']! as num).toInt(),
      bytes: (m['bytes']! as num).toInt(),
    );
  }

  /// Deletes all but the [keep] most recently used copies.
  static Future<void> trimCache(int keep) =>
      _methods.invokeMethod<void>('trimCache', {'keep': keep});

  /// Deletes every stored copy, pinned ones too. Original files are not
  /// affected.
  static Future<void> clearCache() => _methods.invokeMethod<void>('clearCache');

  /// All stored copies, pinned and unpinned.
  static Future<List<StoredCopy>> listCopies() async {
    final list = await _methods.invokeListMethod<Object?>('listCopies');
    return [
      for (final m in list ?? const [])
        StoredCopy.fromMap(m! as Map<Object?, Object?>),
    ];
  }

  static Future<void> deleteCopy(StoredCopy copy) => _methods
      .invokeMethod<void>('deleteCopy', {'id': copy.id, 'pinned': copy.pinned});

  /// Pins or unpins [copy], then trims unpinned copies to [keep].
  static Future<void> setPinned(StoredCopy copy, bool pinned, int keep) =>
      _methods.invokeMethod<void>('setPinned', {
        'id': copy.id,
        'pinned': pinned,
        'keep': keep,
      });
}
