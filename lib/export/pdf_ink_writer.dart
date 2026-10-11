import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart' as pdfium;

import '../core/ink_export_plan.dart';

class PdfExportException implements Exception {
  const PdfExportException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Draws [pages] (1-based page number -> lines in PDF page coordinates) onto
/// the PDF at [sourcePath] and returns the new PDF's bytes. The source file is
/// never changed (CLAUDE.md rule 6): PDFium works on a copy in memory and
/// writes a new file.
///
/// PDFium must already be initialised, and nothing else may use it at the
/// same time (it isn't thread-safe). In the app this runs on pdfrx's own
/// PDFium worker; tests call it directly.
Uint8List writeInkIntoPdf(
  pdfium.PDFium lib,
  String sourcePath,
  Map<int, List<ExportLine>> pages,
) {
  final path = sourcePath.toNativeUtf8();
  final doc = lib.FPDF_LoadDocument(path.cast(), nullptr);
  malloc.free(path);
  if (doc == nullptr) {
    throw PdfExportException(
      "Couldn't open the PDF to export (PDFium error "
      '${lib.FPDF_GetLastError()}).',
    );
  }
  try {
    final pageCount = lib.FPDF_GetPageCount(doc);
    final box = calloc<pdfium.FS_RECTF>();
    final blend = 'Multiply'.toNativeUtf8();
    try {
      for (final entry in pages.entries) {
        final n = entry.key;
        if (n < 1 || n > pageCount || entry.value.isEmpty) continue;
        final page = lib.FPDF_LoadPage(doc, n - 1);
        if (page == nullptr) continue;
        // Saved ink is relative to the visible page's bottom-left corner;
        // some PDFs don't put that corner at (0, 0).
        var dx = 0.0, dy = 0.0;
        if (lib.FPDF_GetPageBoundingBox(page, box) != 0) {
          dx = box.ref.left;
          dy = box.ref.bottom;
        }
        for (final line in entry.value) {
          final p = line.points;
          if (p.length < 4) continue;
          final obj = lib.FPDFPageObj_CreateNewPath(p[0] + dx, p[1] + dy);
          for (var i = 2; i + 1 < p.length; i += 2) {
            lib.FPDFPath_LineTo(obj, p[i] + dx, p[i + 1] + dy);
          }
          final c = line.colorArgb;
          lib.FPDFPageObj_SetStrokeColor(
            obj,
            (c >> 16) & 0xFF,
            (c >> 8) & 0xFF,
            c & 0xFF,
            line.alpha,
          );
          lib.FPDFPageObj_SetStrokeWidth(obj, line.width);
          // Highlighter: flat ends like on screen; pen: round ends and joins.
          lib.FPDFPageObj_SetLineCap(obj, line.highlighter ? 0 : 1);
          lib.FPDFPageObj_SetLineJoin(obj, 1);
          if (line.highlighter) lib.FPDFPageObj_SetBlendMode(obj, blend.cast());
          lib.FPDFPath_SetDrawMode(obj, 0, 1); // no fill, stroke
          lib.FPDFPage_InsertObject(page, obj);
        }
        lib.FPDFPage_GenerateContent(page);
        lib.FPDF_ClosePage(page);
      }
    } finally {
      calloc.free(box);
      malloc.free(blend);
    }
    return _save(lib, doc);
  } finally {
    lib.FPDF_CloseDocument(doc);
  }
}

/// Bytes written by PDFium while saving (one save at a time per isolate).
BytesBuilder? _saving;

int _writeBlock(
  Pointer<pdfium.FPDF_FILEWRITE> self,
  Pointer<Void> data,
  int size,
) {
  _saving!.add(data.cast<Uint8>().asTypedList(size));
  return 1;
}

Uint8List _save(pdfium.PDFium lib, pdfium.FPDF_DOCUMENT doc) {
  final callback =
      NativeCallable<
        Int Function(
          Pointer<pdfium.FPDF_FILEWRITE>,
          Pointer<Void>,
          UnsignedLong,
        )
      >.isolateLocal(_writeBlock, exceptionalReturn: 0);
  final writer = calloc<pdfium.FPDF_FILEWRITE>();
  _saving = BytesBuilder(copy: true);
  try {
    writer.ref.version = 1;
    writer.ref.WriteBlock = callback.nativeFunction;
    if (lib.FPDF_SaveAsCopy(doc, writer, 0) == 0) {
      throw const PdfExportException("PDFium couldn't save the exported PDF.");
    }
    return _saving!.takeBytes();
  } finally {
    _saving = null;
    calloc.free(writer);
    callback.close();
  }
}
