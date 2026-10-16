import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/blank_pdf.dart';

/// Notebooks without a PDF (owner's choice): each is kept as a stored copy
/// of a one-page empty PDF made by the app, pinned so it's never trimmed.
/// Its pages are blank pages of our own (see PageLayout.newNotebook).

/// The empty page every notebook's file holds (A4).
List<int> notebookPdf() => blankPdf(const [(595, 842)]);

/// Where pinned stored copies are kept (the same folder the Android side
/// lists, see PdfImporter.kt).
Future<Directory> _pinnedDir() async {
  final dir = Directory(
    '${(await getTemporaryDirectory()).path}/imports/pinned',
  );
  await dir.create(recursive: true);
  return dir;
}

/// A new notebook's file, named [name]; its library id and path.
Future<({String id, String path})> createNotebookFile(String name) async {
  final bytes = notebookPdf();
  final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9 ._,-]'), '_');
  final id =
      '${bytes.length}_${DateTime.now().millisecondsSinceEpoch}_$safe.pdf';
  final file = File('${(await _pinnedDir()).path}/$id');
  await file.writeAsBytes(bytes, flush: true);
  return (id: id, path: file.path);
}

/// Puts back the files of the notebooks [ids] that aren't stored any more
/// (Android may clear the app's cache folder). The file is only an empty
/// page, and the writing is kept apart, so nothing is lost.
Future<void> restoreNotebookFiles(Iterable<String> ids) async {
  final dir = await _pinnedDir();
  for (final id in ids) {
    if (id.contains('/') || id.contains('..')) continue;
    final file = File('${dir.path}/$id');
    final plain = File('${dir.parent.path}/$id');
    if (await file.exists() || await plain.exists()) continue;
    await file.writeAsBytes(notebookPdf(), flush: true);
  }
}
