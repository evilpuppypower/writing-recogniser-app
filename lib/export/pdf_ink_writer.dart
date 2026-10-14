import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart' as pdfium;

import '../core/ink_export_plan.dart';
import '../core/typed_text.dart' show typedPlacement, typedSizeOnPage;

class PdfExportException implements Exception {
  const PdfExportException(this.message, {this.trace = const []});
  final String message;

  /// What happened, step by step, for the diagnostic log (no names, text
  /// or ink: only sizes, counts and PDFium's answers).
  final List<String> trace;

  @override
  String toString() => message;
}

/// Draws [pages] (1-based page number -> lines in PDF page coordinates) onto
/// the PDF at [sourcePath], adds [text] (recognised words, page number ->
/// words) as invisible text over the handwriting so the PDF can be searched
/// (task 1.4b), and returns the new PDF's bytes. With [onlyPages] (1-based
/// page numbers), the new PDF has just those pages, in their original
/// order (task 1.4c); page numbers that aren't in the PDF are ignored.
/// The source file is
/// never changed (CLAUDE.md rule 6): PDFium works on a copy in memory and
/// writes a new file.
///
/// PDFium must already be initialised, and nothing else may use it at the
/// same time (it isn't thread-safe). In the app this runs on pdfrx's own
/// PDFium worker; tests call it directly.
Uint8List writeInkIntoPdf(
  pdfium.PDFium lib,
  String sourcePath,
  Map<int, List<ExportLine>> pages, {
  Map<int, List<ExportWord>> text = const {},
  Set<int>? onlyPages,
  List<String>? trace,
}) {
  final steps = trace ?? <String>[];
  final watch = Stopwatch()..start();
  void step(String s) => steps.add('${watch.elapsedMilliseconds} ms: $s');
  try {
    step(
      'source file ${(File(sourcePath).lengthSync() / 1e6).toStringAsFixed(1)} MB',
    );
  } catch (e) {
    step('source file unreadable (${e.runtimeType})');
  }
  final path = sourcePath.toNativeUtf8();
  final doc = lib.FPDF_LoadDocument(path.cast(), nullptr);
  malloc.free(path);
  if (doc == nullptr) {
    final error = lib.FPDF_GetLastError();
    step('open failed, PDFium error $error');
    throw PdfExportException(
      "Couldn't open the PDF to export (PDFium error $error).",
      trace: steps,
    );
  }
  try {
    final pageCount = lib.FPDF_GetPageCount(doc);
    final version = calloc<Int>();
    final hasVersion = lib.FPDF_GetFileVersion(doc, version) != 0;
    step(
      'opened: $pageCount pages, PDF version '
      '${hasVersion ? version.value : '?'}, security '
      '${lib.FPDF_GetSecurityHandlerRevision(doc)}, permissions '
      '0x${lib.FPDF_GetDocPermissions(doc).toRadixString(16)}',
    );
    calloc.free(version);
    final box = calloc<pdfium.FS_RECTF>();
    final blend = 'Multiply'.toNativeUtf8();
    final font = 'Helvetica'.toNativeUtf8();
    final bounds = calloc<Float>(4);
    try {
      final numbers = {...pages.keys, ...text.keys}.toList()..sort();
      for (final n in numbers) {
        final lines = pages[n] ?? const <ExportLine>[];
        final words = text[n] ?? const <ExportWord>[];
        if (n < 1 ||
            n > pageCount ||
            (onlyPages != null && !onlyPages.contains(n)) ||
            (lines.isEmpty && words.isEmpty)) {
          continue;
        }
        final page = lib.FPDF_LoadPage(doc, n - 1);
        if (page == nullptr) continue;
        // Saved ink is relative to the visible page's bottom-left corner;
        // some PDFs don't put that corner at (0, 0).
        var dx = 0.0, dy = 0.0;
        if (lib.FPDF_GetPageBoundingBox(page, box) != 0) {
          dx = box.ref.left;
          dy = box.ref.bottom;
        }
        for (final line in lines) {
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
        for (final w in words) {
          _addWord(lib, doc, page, font, bounds, w, dx, dy);
        }
        final generated = lib.FPDFPage_GenerateContent(page) != 0;
        lib.FPDF_ClosePage(page);
        step(
          'page $n: ${lines.length} lines, ${words.length} words'
          '${generated ? '' : ', content NOT generated'}',
        );
      }
    } finally {
      calloc.free(box);
      calloc.free(bounds);
      malloc.free(blend);
      malloc.free(font);
    }
    if (onlyPages != null) {
      if (!onlyPages.any((n) => n >= 1 && n <= pageCount)) {
        step('none of the chosen pages exist');
        throw PdfExportException(
          'None of the chosen pages are in this PDF.',
          trace: steps,
        );
      }
      // From the end, so the earlier pages keep their positions.
      for (var n = pageCount; n >= 1; n--) {
        if (!onlyPages.contains(n)) lib.FPDFPage_Delete(doc, n - 1);
      }
      step('kept ${lib.FPDF_GetPageCount(doc)} of $pageCount pages');
    }
    return _save(lib, doc, step, steps);
  } finally {
    lib.FPDF_CloseDocument(doc);
  }
}

/// Adds [w] to [page]: invisible text stretched over the word's box, so
/// searching finds it and selecting it highlights the handwriting; or, for
/// typed text (task 2.3d, [ExportWord.visible]), visible text in its
/// colour and size, starting at the box's left edge and centred in it.
void _addWord(
  pdfium.PDFium lib,
  pdfium.FPDF_DOCUMENT doc,
  pdfium.FPDF_PAGE page,
  Pointer<Utf8> font,
  Pointer<Float> bounds,
  ExportWord w,
  double dx,
  double dy,
) {
  final text = w.text.trim();
  final width = w.right - w.left, height = w.top - w.bottom;
  if (text.isEmpty || width <= 0 || height <= 0) return;
  final obj = lib.FPDFPageObj_NewTextObj(doc, font.cast(), 1);
  if (obj == nullptr) return;
  // A trailing space keeps words apart when the text is copied.
  final units = '$text '.codeUnits;
  final wide = calloc<UnsignedShort>(units.length + 1);
  for (var i = 0; i < units.length; i++) {
    wide[i] = units[i];
  }
  wide[units.length] = 0;
  final ok = lib.FPDFText_SetText(obj, wide.cast()) != 0;
  calloc.free(wide);
  if (!ok) {
    lib.FPDFPageObj_Destroy(obj);
    return;
  }
  final color = w.colorArgb;
  if (color != null) {
    lib.FPDFTextObj_SetTextRenderMode(
      obj,
      pdfium.FPDF_TEXT_RENDERMODE.FPDF_TEXTRENDERMODE_FILL,
    );
    lib.FPDFPageObj_SetFillColor(
      obj,
      (color >> 16) & 0xFF,
      (color >> 8) & 0xFF,
      color & 0xFF,
      (color >> 24) & 0xFF,
    );
    // Upright as the page is shown, even on pages turned sideways.
    final turns = lib.FPDFPage_GetRotation(page);
    final size = typedSizeOnPage(w, turns);
    final m = typedPlacement(w, turns, size);
    lib.FPDFPageObj_Transform(obj, m.a, m.b, m.c, m.d, m.e + dx, m.f + dy);
    lib.FPDFPage_InsertObject(page, obj);
    return;
  }
  lib.FPDFTextObj_SetTextRenderMode(
    obj,
    pdfium.FPDF_TEXT_RENDERMODE.FPDF_TEXTRENDERMODE_INVISIBLE,
  );
  // Measure the text at size 1, then stretch it over the word's box.
  var textWidth = 0.5 * units.length;
  if (lib.FPDFPageObj_GetBounds(
        obj,
        bounds,
        bounds + 1,
        bounds + 2,
        bounds + 3,
      ) !=
      0) {
    final measured = bounds[2] - bounds[0];
    if (measured > 0) textWidth = measured;
  }
  lib.FPDFPageObj_Transform(
    obj,
    width / textWidth,
    0,
    0,
    height * 0.9,
    w.left + dx,
    w.bottom + dy + height * 0.15,
  );
  lib.FPDFPage_InsertObject(page, obj);
}

/// Bytes written by PDFium while saving (one save at a time per isolate).
BytesBuilder? _saving;

/// What went wrong taking the bytes PDFium wrote, if anything (PDFium
/// itself only learns that the write failed).
Object? _writeError;

int _writeBlock(
  Pointer<pdfium.FPDF_FILEWRITE> self,
  Pointer<Void> data,
  int size,
) {
  try {
    _saving!.add(data.cast<Uint8>().asTypedList(size));
    return 1;
  } catch (e) {
    _writeError = e;
    return 0;
  }
}

/// Saves [doc]. If PDFium's usual save fails, tries again as a fresh,
/// non-incremental file (some PDFs only save that way); if that fails too,
/// says why as far as it can be told (owner's test: "couldn't save" came
/// back with no reason).
Uint8List _save(
  pdfium.PDFium lib,
  pdfium.FPDF_DOCUMENT doc,
  void Function(String) step,
  List<String> steps,
) {
  final callback =
      NativeCallable<
        Int Function(
          Pointer<pdfium.FPDF_FILEWRITE>,
          Pointer<Void>,
          UnsignedLong,
        )
      >.isolateLocal(_writeBlock, exceptionalReturn: 0);
  final writer = calloc<pdfium.FPDF_FILEWRITE>();
  try {
    writer.ref.version = 1;
    writer.ref.WriteBlock = callback.nativeFunction;
    Object? writeError;
    for (final flags in const [0, pdfium.FPDF_NO_INCREMENTAL]) {
      _saving = BytesBuilder(copy: true);
      _writeError = null;
      final ok = lib.FPDF_SaveAsCopy(doc, writer, flags) != 0;
      final written = _saving!.length;
      if (ok && _writeError == null) {
        step('saved (flags $flags): ${(written / 1e6).toStringAsFixed(1)} MB');
        return _saving!.takeBytes();
      }
      step(
        'save (flags $flags) failed after '
        '${(written / 1e6).toStringAsFixed(1)} MB'
        '${_writeError == null ? '' : ', write error ${_writeError.runtimeType}'}'
        ', memory in use ${(ProcessInfo.currentRss / 1e6).round()} MB',
      );
      writeError ??= _writeError;
      _saving = null; // let a failed attempt's bytes go before retrying
    }
    throw PdfExportException(
      // (PDFium's last-error number is about opening files, not saving, so
      // it's left out.)
      saveFailureMessage(
        writeError: writeError,
        pages: lib.FPDF_GetPageCount(doc),
      ),
      trace: steps,
    );
  } finally {
    _saving = null;
    _writeError = null;
    calloc.free(writer);
    callback.close();
  }
}

/// The message for a PDF that couldn't be saved, with what is known about
/// why (nothing about the document's content).
String saveFailureMessage({Object? writeError, int pages = 0}) {
  final why = switch (writeError) {
    OutOfMemoryError() =>
      'the tablet ran out of memory for the new PDF. Try exporting fewer '
          'pages at a time.',
    null => 'PDFium gave no reason.',
    _ => 'writing it failed (${writeError.runtimeType}).',
  };
  return "PDFium couldn't save the exported PDF ($pages pages): $why";
}
