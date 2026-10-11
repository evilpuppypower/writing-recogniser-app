import 'dart:typed_data';

import 'package:pdfium_dart/pdfium_dart.dart' as pdfium;
import 'package:pdfrx/pdfrx.dart';

import '../core/ink_export_plan.dart';
import '../core/page_ink.dart';
import '../core/pressure_response.dart';
import 'pdf_ink_writer.dart';

/// Makes a new PDF with [ink] drawn onto the pages of the PDF at
/// [sourcePath] (task 1.4a). Runs on pdfrx's PDFium worker, so it never
/// uses PDFium at the same time as the viewer (PDFium isn't thread-safe).
Future<Uint8List> exportPdfWithInk({
  required String sourcePath,
  required DocumentInk ink,
  PressureResponse pressure = const PressureResponse(),
}) {
  final pages = <int, List<List<Object>>>{
    for (final page in ink.pagesWithInk)
      page: [
        for (final l in exportLines(ink.strokesOn(page), pressure: pressure))
          l.toMessage(),
      ],
  };
  return PdfrxEntryFunctions.instance.compute(_exportOnWorker, <Object?>[
    sourcePath,
    pages,
    Pdfrx.pdfiumModulePath,
  ]);
}

/// Runs inside the PDFium worker isolate (where PDFium is set up).
Uint8List _exportOnWorker(List<Object?> m) {
  final lib = pdfium.getPdfium(modulePath: m[2] as String?);
  final pages = {
    for (final e in (m[1]! as Map).entries)
      e.key as int: [
        for (final l in e.value as List)
          ExportLine.fromMessage((l as List).cast<Object?>()),
      ],
  };
  return writeInkIntoPdf(lib, m[0]! as String, pages);
}

/// "Lecture 3.pdf" -> "Lecture 3 (with ink).pdf".
String exportFileName(String title) {
  final base = title.toLowerCase().endsWith('.pdf')
      ? title.substring(0, title.length - 4)
      : title;
  return '$base (with ink).pdf';
}
