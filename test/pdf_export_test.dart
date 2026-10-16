import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfium_dart/pdfium_dart.dart' as pdfium;
import 'package:writing_recogniser/core/blank_pdf.dart' as app;
import 'package:writing_recogniser/core/ink_export_plan.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/page_ranges.dart';
import 'package:writing_recogniser/core/pressure_response.dart';
import 'package:writing_recogniser/export/pdf_exporter.dart';
import 'package:writing_recogniser/export/pdf_ink_writer.dart';

PageStroke pen(List<(double, double, double)> pts, {bool arrow = false}) =>
    PageStroke(
      points: [for (final (x, y, p) in pts) PageInkPoint(x, y, 0, p)],
      colorArgb: 0xFF1565C0,
      width: 2,
      arrow: arrow,
    );

/// A blank PDF with [pages] US Letter pages, made with PDFium itself.
/// [quarterTurns]: how far each page is shown turned clockwise.
String blankPdf(
  pdfium.PDFium lib,
  Directory dir,
  int pages, {
  int quarterTurns = 0,
  double width = 612,
  double height = 792,
}) {
  final doc = lib.FPDF_CreateNewDocument();
  for (var i = 0; i < pages; i++) {
    final page = lib.FPDFPage_New(doc, i, width, height);
    if (quarterTurns != 0) lib.FPDFPage_SetRotation(page, quarterTurns);
    lib.FPDF_ClosePage(page);
  }
  final file = File('${dir.path}/blank.pdf');
  // Save through the same writer path by exporting no ink.
  final tmp = File('${dir.path}/tmp.pdf');
  tmp.writeAsBytesSync(_saveNew(lib, doc));
  lib.FPDF_CloseDocument(doc);
  tmp.renameSync(file.path);
  return file.path;
}

List<int> _saveNew(pdfium.PDFium lib, pdfium.FPDF_DOCUMENT doc) {
  final out = <int>[];
  int write(Pointer<pdfium.FPDF_FILEWRITE> s, Pointer<Void> d, int n) {
    out.addAll(d.cast<Uint8>().asTypedList(n));
    return 1;
  }

  final cb =
      NativeCallable<
        Int Function(
          Pointer<pdfium.FPDF_FILEWRITE>,
          Pointer<Void>,
          UnsignedLong,
        )
      >.isolateLocal(write, exceptionalReturn: 0);
  final w = calloc<pdfium.FPDF_FILEWRITE>();
  w.ref.version = 1;
  w.ref.WriteBlock = cb.nativeFunction;
  lib.FPDF_SaveAsCopy(doc, w, 0);
  calloc.free(w);
  cb.close();
  return out;
}

/// The desktop PDFium library that pdfium_dart's build step downloads for
/// tests (the app itself uses the Android one).
String? _findPdfium() {
  for (final root in ['.dart_tool', 'build']) {
    final dir = Directory(root);
    if (!dir.existsSync()) continue;
    for (final f in dir.listSync(recursive: true, followLinks: false)) {
      if (f is File && f.path.endsWith('libpdfium.so')) return f.path;
    }
  }
  return null;
}

void main() {
  test('exported file name', () {
    expect(exportFileName('Lecture 3.pdf'), 'Lecture 3 (with ink).pdf');
    expect(exportFileName('Notes.PDF'), 'Notes (with ink).pdf');
    expect(exportFileName('Scan'), 'Scan (with ink).pdf');
  });

  group('export plan', () {
    test('a pen stroke is split where its pressure width changes', () {
      final lines = exportLines([
        pen([(0, 0, 0.5), (10, 0, 0.5), (20, 0, 0.5), (30, 0, 1), (40, 0, 1)]),
      ]);
      // 2 pt at normal pressure, 2.4 where it rises, 2.8 pressing hard.
      expect(lines.map((l) => l.width), [
        closeTo(2, 1e-9),
        closeTo(2.4, 1e-9),
        closeTo(2.8, 1e-9),
      ]);
      // Each run starts where the previous one ended: no gaps.
      for (var i = 1; i < lines.length; i++) {
        final a = lines[i - 1].points, b = lines[i].points;
        expect([a[a.length - 2], a.last], [b[0], b[1]]);
      }
    });

    test('pressure 0% gives one line at the set width', () {
      final lines = exportLines([
        pen([(0, 0, 0), (10, 0, 1), (20, 0, 0.2)]),
      ], pressure: PressureResponse.none);
      expect(lines.single.width, 2);
      expect(lines.single.points, hasLength(6));
    });

    test('highlighter: one see-through line; arrows add two lines', () {
      final lines = exportLines([
        const PageStroke(
          points: [PageInkPoint(0, 0, 0), PageInkPoint(50, 0, 0)],
          tool: InkTool.highlighter,
          width: 10,
          colorArgb: 0xFFFFEB3B,
        ),
        pen([(0, 0, 0.5), (60, 0, 0.5)], arrow: true),
      ], pressure: PressureResponse.none);
      expect(lines, hasLength(4));
      expect(lines.first.highlighter, isTrue);
      expect(lines.first.alpha, 102);
      expect(lines[1].alpha, 255);
    });

    test('lines survive the trip to the worker isolate', () {
      final l = exportLines([
        pen([(1, 2, 0.5), (3, 4, 0.5)]),
      ]).single;
      final back = ExportLine.fromMessage(l.toMessage());
      expect(back.points, l.points);
      expect(back.width, l.width);
      expect(back.colorArgb, l.colorArgb);
    });
  });

  group('writing ink into a real PDF (PDFium)', () {
    late pdfium.PDFium lib;
    late Directory dir;

    setUpAll(() {
      lib = pdfium.getPdfium(modulePath: _findPdfium());
      lib.FPDF_InitLibrary();
    });
    setUp(() => dir = Directory.systemTemp.createTempSync('export'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('adds one path per line on the right pages; source unchanged', () {
      final src = blankPdf(lib, dir, 3);
      final before = File(src).readAsBytesSync();
      final bytes = writeInkIntoPdf(lib, src, {
        2: exportLines([
          pen([(100, 100, 0.5), (200, 150, 0.5)], arrow: true),
        ], pressure: PressureResponse.none),
        9: exportLines([
          pen([(1, 1, 0.5), (2, 2, 0.5)]),
        ]), // no such page: ignored
      });
      expect(File(src).readAsBytesSync(), before, reason: 'never changed');

      final out = File('${dir.path}/out.pdf')..writeAsBytesSync(bytes);
      final path = out.path.toNativeUtf8();
      final doc = lib.FPDF_LoadDocument(path.cast(), nullptr);
      malloc.free(path);
      expect(doc, isNot(nullptr), reason: 'the export is a valid PDF');
      expect(lib.FPDF_GetPageCount(doc), 3);
      int objects(int i) {
        final page = lib.FPDF_LoadPage(doc, i);
        final n = lib.FPDFPage_CountObjects(page);
        lib.FPDF_ClosePage(page);
        return n;
      }

      expect([objects(0), objects(1), objects(2)], [0, 3, 0]);
      final page = lib.FPDF_LoadPage(doc, 1);
      expect(lib.FPDFPageObj_GetType(lib.FPDFPage_GetObject(page, 0)), 2);
      lib.FPDF_ClosePage(page);
      lib.FPDF_CloseDocument(doc);
    });

    test('only some pages: the new PDF has just those, ink on them', () {
      final src = blankPdf(lib, dir, 4);
      final bytes = writeInkIntoPdf(
        lib,
        src,
        {
          1: exportLines([
            pen([(10, 10, 0.5), (20, 20, 0.5)]),
          ]),
          3: exportLines([
            pen([(10, 10, 0.5), (20, 20, 0.5)]),
            pen([(30, 30, 0.5), (40, 40, 0.5)]),
          ], pressure: PressureResponse.none),
        },
        onlyPages: {3, 4, 99},
      );
      final out = File('${dir.path}/some.pdf')..writeAsBytesSync(bytes);
      final path = out.path.toNativeUtf8();
      final doc = lib.FPDF_LoadDocument(path.cast(), nullptr);
      malloc.free(path);
      expect(lib.FPDF_GetPageCount(doc), 2, reason: 'pages 3 and 4');
      int objects(int i) {
        final page = lib.FPDF_LoadPage(doc, i);
        final n = lib.FPDFPage_CountObjects(page);
        lib.FPDF_ClosePage(page);
        return n;
      }

      expect([objects(0), objects(1)], [2, 0], reason: "page 3's ink first");
      lib.FPDF_CloseDocument(doc);
      expect(
        () => writeInkIntoPdf(lib, src, const {}, onlyPages: {7}),
        throwsA(isA<PdfExportException>()),
        reason: 'none of the chosen pages exist',
      );
    });

    test('"1-3" of 5 pages, with ink and text on each: pages 1, 2, 3', () {
      final src = blankPdf(lib, dir, 5);
      final line = exportLines([
        pen([(10, 10, 0.5), (20, 20, 0.5)]),
      ]);
      final bytes = writeInkIntoPdf(
        lib,
        src,
        {
          for (final p in [1, 2, 3, 5]) p: line,
        },
        text: {
          for (final p in [1, 2, 3]) p: [ExportWord('p$p', 10, 10, 40, 20)],
        },
        onlyPages: parsePageRanges('1-3', 5),
      );
      final out = File('${dir.path}/first3.pdf')..writeAsBytesSync(bytes);
      final path = out.path.toNativeUtf8();
      final doc = lib.FPDF_LoadDocument(path.cast(), nullptr);
      malloc.free(path);
      expect(lib.FPDF_GetPageCount(doc), 3);
      // Each page kept its own text, in order.
      for (var i = 0; i < 3; i++) {
        final page = lib.FPDF_LoadPage(doc, i);
        final tp = lib.FPDFText_LoadPage(page);
        final n = lib.FPDFText_CountChars(tp);
        final buf = calloc<UnsignedShort>(n + 1);
        lib.FPDFText_GetText(tp, 0, n, buf);
        final got = String.fromCharCodes([for (var k = 0; k < n; k++) buf[k]]);
        calloc.free(buf);
        lib.FPDFText_ClosePage(tp);
        lib.FPDF_ClosePage(page);
        expect(got.trim(), 'p${i + 1}');
      }
      lib.FPDF_CloseDocument(doc);
    });

    test('recognised words become invisible, searchable text', () {
      final src = blankPdf(lib, dir, 2);
      final bytes = writeInkIntoPdf(
        lib,
        src,
        const {},
        text: const {
          2: [
            ExportWord('hello', 100, 600, 160, 620),
            ExportWord('world', 170, 600, 240, 620),
          ],
          7: [ExportWord('ignored', 1, 1, 2, 2)], // no such page
        },
      );
      final out = File('${dir.path}/text.pdf')..writeAsBytesSync(bytes);
      final path = out.path.toNativeUtf8();
      final doc = lib.FPDF_LoadDocument(path.cast(), nullptr);
      malloc.free(path);
      expect(doc, isNot(nullptr));

      // What a PDF reader's search sees on each page.
      String textOn(int i) {
        final page = lib.FPDF_LoadPage(doc, i);
        final tp = lib.FPDFText_LoadPage(page);
        final n = lib.FPDFText_CountChars(tp);
        final buf = calloc<UnsignedShort>(n + 1);
        lib.FPDFText_GetText(tp, 0, n, buf);
        final text = String.fromCharCodes([for (var k = 0; k < n; k++) buf[k]]);
        calloc.free(buf);
        lib.FPDFText_ClosePage(tp);
        lib.FPDF_ClosePage(page);
        return text;
      }

      expect(textOn(0).trim(), isEmpty);
      expect(textOn(1), contains('hello'));
      expect(textOn(1), contains('world'));

      // Each word lies over its handwriting: the letters of "hello" are
      // inside its box (100-160 across, 600-620 up), give or take a point.
      {
        final page = lib.FPDF_LoadPage(doc, 1);
        final tp = lib.FPDFText_LoadPage(page);
        final box = calloc<Double>(4);
        final text = textOn(1);
        final start = text.indexOf('hello');
        for (var k = start; k < start + 5; k++) {
          expect(
            lib.FPDFText_GetCharBox(tp, k, box, box + 1, box + 2, box + 3),
            isNot(0),
          );
          final (l, r, b, t) = (box[0], box[1], box[2], box[3]);
          expect(l, greaterThanOrEqualTo(99), reason: 'char $k left');
          expect(r, lessThanOrEqualTo(161), reason: 'char $k right');
          expect(b, greaterThanOrEqualTo(599), reason: 'char $k bottom');
          expect(t, lessThanOrEqualTo(621), reason: 'char $k top');
        }
        calloc.free(box);
        lib.FPDFText_ClosePage(tp);
        lib.FPDF_ClosePage(page);
      }

      // Invisible: the words are text objects drawn in render mode 3.
      final page = lib.FPDF_LoadPage(doc, 1);
      expect(lib.FPDFPage_CountObjects(page), 2);
      final obj = lib.FPDFPage_GetObject(page, 0);
      expect(lib.FPDFPageObj_GetType(obj), 1, reason: 'a text object');
      expect(
        lib.FPDFTextObj_GetTextRenderMode(obj),
        pdfium.FPDF_TEXT_RENDERMODE.FPDF_TEXTRENDERMODE_INVISIBLE,
      );
      lib.FPDF_ClosePage(page);
      lib.FPDF_CloseDocument(doc);
    });

    test('typed text is visible text in the ink colour (task 2.3d)', () {
      final src = blankPdf(lib, dir, 1);
      final bytes = writeInkIntoPdf(
        lib,
        src,
        const {},
        text: const {
          1: [
            ExportWord(
              'cat',
              100,
              600,
              140,
              620,
              colorArgb: 0xFFD32F2F,
              fontSize: 16,
            ),
          ],
        },
      );
      final out = File('${dir.path}/typed.pdf')..writeAsBytesSync(bytes);
      final path = out.path.toNativeUtf8();
      final doc = lib.FPDF_LoadDocument(path.cast(), nullptr);
      malloc.free(path);
      final page = lib.FPDF_LoadPage(doc, 0);
      final obj = lib.FPDFPage_GetObject(page, 0);
      expect(lib.FPDFPageObj_GetType(obj), 1, reason: 'a text object');
      expect(
        lib.FPDFTextObj_GetTextRenderMode(obj),
        pdfium.FPDF_TEXT_RENDERMODE.FPDF_TEXTRENDERMODE_FILL,
        reason: 'visible',
      );
      final rgba = calloc<UnsignedInt>(4);
      lib.FPDFPageObj_GetFillColor(obj, rgba, rgba + 1, rgba + 2, rgba + 3);
      expect([rgba[0], rgba[1], rgba[2], rgba[3]], [0xD3, 0x2F, 0x2F, 0xFF]);
      calloc.free(rgba);
      // Searchable too, and inside the handwriting's height.
      final tp = lib.FPDFText_LoadPage(page);
      final n = lib.FPDFText_CountChars(tp);
      final buf = calloc<UnsignedShort>(n + 1);
      lib.FPDFText_GetText(tp, 0, n, buf);
      expect(
        String.fromCharCodes([for (var k = 0; k < n; k++) buf[k]]),
        contains('cat'),
      );
      calloc.free(buf);
      final box = calloc<Double>(4);
      lib.FPDFText_GetCharBox(tp, 0, box, box + 1, box + 2, box + 3);
      expect(box[0], closeTo(100, 2), reason: 'starts at the left edge');
      expect(box[2], greaterThanOrEqualTo(599));
      expect(box[3], lessThanOrEqualTo(621));
      calloc.free(box);
      lib.FPDFText_ClosePage(tp);
      lib.FPDF_ClosePage(page);
      lib.FPDF_CloseDocument(doc);
    });

    test('"both": typed text sits just under the handwriting', () {
      final src = blankPdf(lib, dir, 1);
      final bytes = writeInkIntoPdf(
        lib,
        src,
        const {},
        text: const {
          1: [
            ExportWord(
              'cat',
              100,
              600,
              140,
              620,
              colorArgb: 0xFF000000,
              under: true,
            ),
          ],
        },
      );
      final out = File('${dir.path}/both.pdf')..writeAsBytesSync(bytes);
      final path = out.path.toNativeUtf8();
      final doc = lib.FPDF_LoadDocument(path.cast(), nullptr);
      malloc.free(path);
      final page = lib.FPDF_LoadPage(doc, 0);
      final tp = lib.FPDFText_LoadPage(page);
      final box = calloc<Double>(4);
      lib.FPDFText_GetCharBox(tp, 0, box, box + 1, box + 2, box + 3);
      expect(box[3], lessThanOrEqualTo(600.5), reason: 'top below the ink');
      expect(box[2], greaterThan(570), reason: 'but close under it');
      expect(box[0], closeTo(100, 2));
      calloc.free(box);
      lib.FPDFText_ClosePage(tp);
      lib.FPDF_ClosePage(page);
      lib.FPDF_CloseDocument(doc);
    });

    test('typed text on a page turned sideways reads upright', () {
      final src = blankPdf(lib, dir, 1, quarterTurns: 1);
      final bytes = writeInkIntoPdf(
        lib,
        src,
        const {},
        text: const {
          1: [ExportWord('cat', 100, 500, 120, 600, colorArgb: 0xFF000000)],
        },
      );
      final out = File('${dir.path}/turned.pdf')..writeAsBytesSync(bytes);
      final path = out.path.toNativeUtf8();
      final doc = lib.FPDF_LoadDocument(path.cast(), nullptr);
      malloc.free(path);
      final page = lib.FPDF_LoadPage(doc, 0);
      expect(lib.FPDFPage_GetRotation(page), 1);
      final tp = lib.FPDFText_LoadPage(page);
      final box = calloc<Double>(4);
      // "c", "a", "t" run up the page (screen right), inside the box.
      final ys = <double>[];
      for (var k = 0; k < 3; k++) {
        lib.FPDFText_GetCharBox(tp, k, box, box + 1, box + 2, box + 3);
        expect(box[0], greaterThanOrEqualTo(99), reason: 'char $k left');
        expect(box[1], lessThanOrEqualTo(121), reason: 'char $k right');
        ys.add(box[2]);
      }
      expect(ys[1], greaterThan(ys[0]));
      expect(ys[2], greaterThan(ys[1]));
      expect(ys.first, greaterThanOrEqualTo(499));
      calloc.free(box);
      lib.FPDFText_ClosePage(tp);
      lib.FPDF_ClosePage(page);
      lib.FPDF_CloseDocument(doc);
    });

    test('every export records its steps for the diagnostic log', () {
      final src = blankPdf(lib, dir, 3);
      final steps = <String>[];
      writeInkIntoPdf(
        lib,
        src,
        {
          2: exportLines([
            pen([(10, 10, 0.5), (20, 20, 0.5)]),
          ]),
        },
        onlyPages: {2, 3},
        trace: steps,
      );
      expect(steps.first, contains('source file'));
      expect(steps, contains(matches(r'opened: 3 pages, PDF version')));
      expect(steps, contains(matches(r'page 2: 1 lines, 0 words')));
      expect(steps, contains(matches(r'kept 2 of 3 pages')));
      expect(steps.last, matches(r'saved \(flags 0\)'));
      // A failure carries its steps too.
      try {
        writeInkIntoPdf(lib, src, const {}, onlyPages: {9});
        fail('should fail');
      } on PdfExportException catch (e) {
        expect(e.trace.last, contains('none of the chosen pages'));
      }
    });

    test('dark pages: every page dark, ink light, as on screen', () {
      // A page with printed content: a thick black line and a word of
      // text, saved into the page itself (a light export).
      final printed = writeInkIntoPdf(
        lib,
        blankPdf(lib, dir, 2),
        {
          1: exportLines([
            PageStroke(
              points: [
                for (var x = 100; x <= 500; x += 10)
                  PageInkPoint(x.toDouble(), 200, 0, 0.5),
              ],
              colorArgb: 0xFF000000,
              width: 30,
            ),
          ], pressure: PressureResponse.none),
        },
        text: {
          1: [const ExportWord('basalt', 100, 600, 200, 620)],
        },
      );
      final src = (File(
        '${dir.path}/printed.pdf',
      )..writeAsBytesSync(printed)).path;
      final bytes = writeInkIntoPdf(lib, src, {
        1: exportLines([
          PageStroke(
            points: [
              for (var x = 100; x <= 500; x += 10)
                PageInkPoint(x.toDouble(), 400, 0, 0.5),
            ],
            colorArgb: 0xFF000000,
            width: 20,
          ),
        ], pressure: PressureResponse.none),
      }, darkPages: true);
      final out = File('${dir.path}/dark.pdf')..writeAsBytesSync(bytes);
      final path = out.path.toNativeUtf8();
      final doc = lib.FPDF_LoadDocument(path.cast(), nullptr);
      malloc.free(path);
      // The colour PDFium draws at (x, y) on page [i] (PDF points, y up),
      // as 0xRRGGBB.
      int pixel(int i, int x, int y) {
        final page = lib.FPDF_LoadPage(doc, i);
        final bitmap = lib.FPDFBitmap_Create(612, 792, 0);
        lib.FPDFBitmap_FillRect(bitmap, 0, 0, 612, 792, 0xFFFFFFFF);
        lib.FPDF_RenderPageBitmap(bitmap, page, 0, 0, 612, 792, 0, 0);
        final stride = lib.FPDFBitmap_GetStride(bitmap);
        final buffer = lib.FPDFBitmap_GetBuffer(bitmap).cast<Uint8>();
        final at = (792 - y) * stride + x * 4; // BGRA, top row first
        final rgb = buffer[at + 2] << 16 | buffer[at + 1] << 8 | buffer[at];
        lib.FPDFBitmap_Destroy(bitmap);
        lib.FPDF_ClosePage(page);
        return rgb;
      }

      // Both pages dark grey (the page without ink too).
      expect(pixel(0, 50, 50), 0x202124);
      expect(pixel(1, 300, 300), 0x202124);
      // Black ink comes out white on it.
      expect(pixel(0, 300, 400), 0xFFFFFF);
      // And so does what was printed on the page: still there, reversed.
      expect(pixel(0, 300, 200), 0xFFFFFF);
      // Its text can still be found.
      final page = lib.FPDF_LoadPage(doc, 0);
      final text = lib.FPDFText_LoadPage(page);
      final n = lib.FPDFText_CountChars(text);
      final chars = String.fromCharCodes([
        for (var i = 0; i < n; i++) lib.FPDFText_GetUnicode(text, i),
      ]);
      expect(chars, contains('basalt'));
      lib.FPDFText_ClosePage(text);
      lib.FPDF_ClosePage(page);
      lib.FPDF_CloseDocument(doc);
    });

    test('pages arranged: reordered, left out, and blank ones added', () {
      final src = blankPdf(lib, dir, 3);
      final bytes = writeInkIntoPdf(
        lib,
        src,
        {
          2: exportLines([
            pen([(10, 10, 0.5), (20, 20, 0.5)]),
          ], pressure: PressureResponse.none),
        },
        pageOrder: [3, null, 2, 99],
      );
      final out = File('${dir.path}/arranged.pdf')..writeAsBytesSync(bytes);
      final path = out.path.toNativeUtf8();
      final doc = lib.FPDF_LoadDocument(path.cast(), nullptr);
      malloc.free(path);
      // Page 1 is left out and page 99 doesn't exist.
      expect(lib.FPDF_GetPageCount(doc), 3);
      int objects(int i) {
        final page = lib.FPDF_LoadPage(doc, i);
        final n = lib.FPDFPage_CountObjects(page);
        lib.FPDF_ClosePage(page);
        return n;
      }

      // Page 3 first, then a blank page, then page 2 with its ink.
      expect([objects(0), objects(1), objects(2)], [0, 0, 1]);
      final w = calloc<Double>(), h = calloc<Double>();
      lib.FPDF_GetPageSizeByIndex(doc, 1, w, h);
      expect((w.value, h.value), (612.0, 792.0), reason: 'the size before it');
      calloc
        ..free(w)
        ..free(h);
      lib.FPDF_CloseDocument(doc);
      // A blank page first: the size of the PDF's own pages (A4 here).
      final a4 = blankPdf(lib, dir, 1, width: 595, height: 842);
      final first = File('${dir.path}/a4.pdf')
        ..writeAsBytesSync(
          writeInkIntoPdf(lib, a4, const {}, pageOrder: [null, 1]),
        );
      final p2 = first.path.toNativeUtf8();
      final doc2 = lib.FPDF_LoadDocument(p2.cast(), nullptr);
      malloc.free(p2);
      final w2 = calloc<Double>(), h2 = calloc<Double>();
      lib.FPDF_GetPageSizeByIndex(doc2, 0, w2, h2);
      expect((w2.value, h2.value), (595.0, 842.0));
      calloc
        ..free(w2)
        ..free(h2);
      lib.FPDF_CloseDocument(doc2);
      expect(
        () => writeInkIntoPdf(lib, src, const {}, pageOrder: [null, 7]),
        throwsA(isA<PdfExportException>()),
        reason: 'none of the PDF\'s own pages',
      );
    });

    test('pages as shown: blank pages, copies and moved pages, with ink', () {
      // Owner: blank pages like any notes app. Shown: page 2, a blank A5
      // page, page 1, and a copy of page 1, each with its own ink.
      final src = blankPdf(lib, dir, 2);
      final line = exportLines([
        pen([(10, 10, 0.5), (20, 20, 0.5)]),
      ], pressure: PressureResponse.none);
      final bytes = writeInkIntoPdf(
        lib,
        src,
        {
          2: line,
          4: [...line, ...line],
        },
        laidOut: const [(2, 0, 0), (0, 420, 595), (1, 0, 0), (1, 0, 0)],
      );
      final out = File('${dir.path}/shown.pdf')..writeAsBytesSync(bytes);
      final path = out.path.toNativeUtf8();
      final doc = lib.FPDF_LoadDocument(path.cast(), nullptr);
      malloc.free(path);
      expect(lib.FPDF_GetPageCount(doc), 4);
      int objects(int i) {
        final page = lib.FPDF_LoadPage(doc, i);
        final n = lib.FPDFPage_CountObjects(page);
        lib.FPDF_ClosePage(page);
        return n;
      }

      // Ink on the blank page and on the copy, not on the original.
      expect([objects(0), objects(1), objects(2), objects(3)], [0, 1, 0, 2]);
      final w = calloc<Double>(), h = calloc<Double>();
      lib.FPDF_GetPageSizeByIndex(doc, 1, w, h);
      expect((w.value, h.value), (420.0, 595.0));
      calloc
        ..free(w)
        ..free(h);
      lib.FPDF_CloseDocument(doc);
      // And picked from as shown.
      final some = writeInkIntoPdf(
        lib,
        src,
        {2: line},
        laidOut: const [(2, 0, 0), (0, 420, 595), (1, 0, 0)],
        onlyPages: {2},
      );
      final f2 = File('${dir.path}/some.pdf')..writeAsBytesSync(some);
      final p2 = f2.path.toNativeUtf8();
      final d2 = lib.FPDF_LoadDocument(p2.cast(), nullptr);
      malloc.free(p2);
      expect(lib.FPDF_GetPageCount(d2), 1);
      final page = lib.FPDF_LoadPage(d2, 0);
      expect(lib.FPDFPage_CountObjects(page), 1);
      lib.FPDF_ClosePage(page);
      lib.FPDF_CloseDocument(d2);
    });

    test('the app\'s own blank pages open in PDFium at their sizes', () {
      final file = File('${dir.path}/own-blank.pdf')
        ..writeAsBytesSync(app.blankPdf([(595, 842), (300.5, 200)]));
      final path = file.path.toNativeUtf8();
      final doc = lib.FPDF_LoadDocument(path.cast(), nullptr);
      malloc.free(path);
      expect(doc, isNot(nullptr));
      expect(lib.FPDF_GetPageCount(doc), 2);
      final w = calloc<Double>(), h = calloc<Double>();
      lib.FPDF_GetPageSizeByIndex(doc, 1, w, h);
      expect((w.value, h.value), (300.5, 200.0));
      calloc
        ..free(w)
        ..free(h);
      lib.FPDF_CloseDocument(doc);
    });

    test('a file that is not a PDF gives a plain error', () {
      final bad = File('${dir.path}/bad.pdf')..writeAsStringSync('hello');
      expect(
        () => writeInkIntoPdf(lib, bad.path, const {}),
        throwsA(isA<PdfExportException>()),
      );
    });
  });

  test('a failed save says why, as far as it can be told', () {
    expect(
      saveFailureMessage(writeError: OutOfMemoryError(), pages: 400),
      allOf(contains('400 pages'), contains('ran out of memory')),
    );
    expect(saveFailureMessage(), contains('no reason'));
    expect(
      saveFailureMessage(writeError: StateError('x')),
      contains('StateError'),
    );
  });
}
