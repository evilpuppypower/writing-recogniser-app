import 'dart:typed_data';

import 'package:pdfium_dart/pdfium_dart.dart' as pdfium;
import 'package:pdfrx/pdfrx.dart';

import '../core/ink_export_plan.dart';
import '../core/page_ink.dart';
import '../core/pressure_response.dart';
import 'pdf_ink_writer.dart';

/// Makes a new PDF with [ink] drawn onto the pages of the PDF at
/// [sourcePath] (task 1.4a), with [text] (page number -> recognised words)
/// as invisible, searchable text over the handwriting (task 1.4b). With
/// [onlyPages], the new PDF has just those pages (task 1.4c). With
/// [laidOut], pages are first put in the order the app shows them (see
/// writeInkIntoPdf), and [paper] (page as shown -> its paper's lines) is
/// drawn under the ink. Runs on
/// pdfrx's PDFium worker, so it never uses PDFium at the same time as the
/// viewer (PDFium isn't thread-safe).
Future<Uint8List> exportPdfWithInk({
  required String sourcePath,
  required DocumentInk ink,
  PressureResponse pressure = const PressureResponse(),
  Map<int, List<ExportWord>> text = const {},
  Set<int>? onlyPages,
  bool darkPages = false,
  List<int?>? pageOrder,
  List<(int, double, double)>? laidOut,
  Map<int, List<ExportLine>> paper = const {},
  List<String>? trace,
}) async {
  // Paper first, so the ink is drawn over it.
  final pages = <int, List<List<Object>>>{
    for (final page in {...paper.keys, ...ink.pagesWithInk})
      page: [
        for (final l in paper[page] ?? const <ExportLine>[]) l.toMessage(),
        for (final l in exportLines(ink.strokesOn(page), pressure: pressure))
          l.toMessage(),
      ],
  };
  final words = <int, List<List<Object?>>>{
    for (final e in text.entries)
      e.key: [for (final w in e.value) w.toMessage()],
  };
  // The worker sends back the bytes, or what went wrong, with its steps
  // for the diagnostic log.
  final result = await PdfrxEntryFunctions.instance.compute(
    _exportOnWorker,
    <Object?>[
      sourcePath,
      pages,
      Pdfrx.pdfiumModulePath,
      words,
      onlyPages?.toList(),
      darkPages,
      pageOrder,
      laidOut == null
          ? null
          : [
              for (final (n, w, h) in laidOut) [n, w, h],
            ],
    ],
  );
  trace?.addAll((result[2] as List).cast<String>());
  if (result[0] == 'failed') {
    throw PdfExportException(
      result[1]! as String,
      trace: (result[2] as List).cast<String>(),
    );
  }
  return result[1]! as Uint8List;
}

/// Runs inside the PDFium worker isolate (where PDFium is set up). Returns
/// ['ok', bytes, steps] or ['failed', message, steps].
List<Object?> _exportOnWorker(List<Object?> m) {
  final lib = pdfium.getPdfium(modulePath: m[2] as String?);
  final pages = {
    for (final e in (m[1]! as Map).entries)
      e.key as int: [
        for (final l in e.value as List)
          ExportLine.fromMessage((l as List).cast<Object?>()),
      ],
  };
  final text = {
    for (final e in (m[3]! as Map).entries)
      e.key as int: [
        for (final w in e.value as List)
          ExportWord.fromMessage((w as List).cast<Object?>()),
      ],
  };
  final only = m[4] as List?;
  final steps = <String>[];
  try {
    final bytes = writeInkIntoPdf(
      lib,
      m[0]! as String,
      pages,
      text: text,
      onlyPages: only == null ? null : {for (final n in only) n as int},
      darkPages: m[5]! as bool,
      pageOrder: (m[6] as List?)?.cast<int?>(),
      laidOut: (m[7] as List?) == null
          ? null
          : [
              for (final e in m[7]! as List)
                (
                  (e as List)[0] as int,
                  (e[1] as num).toDouble(),
                  (e[2] as num).toDouble(),
                ),
            ],
      trace: steps,
    );
    return ['ok', bytes, steps];
  } on PdfExportException catch (e) {
    return ['failed', e.message, steps];
  } catch (e) {
    steps.add('unexpected ${e.runtimeType}');
    return ['failed', "Couldn't export the PDF (${e.runtimeType}).", steps];
  }
}

/// "Lecture 3.pdf" -> "Lecture 3 (with ink).pdf".
String exportFileName(String title) {
  final base = title.toLowerCase().endsWith('.pdf')
      ? title.substring(0, title.length - 4)
      : title;
  return '$base (with ink).pdf';
}
