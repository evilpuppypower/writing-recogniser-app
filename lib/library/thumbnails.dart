import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../core/page_coordinates.dart';
import '../core/page_ink.dart';

/// Small pictures of each PDF's first page for the home page, kept in app
/// storage so they still show after the stored copy is removed.
class Thumbnails {
  const Thumbnails();

  static const width = 240;

  Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/thumbnails').create(recursive: true);
  }

  Future<File> _file(String cacheId) async {
    final safe = cacheId.replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_');
    return File('${(await _dir()).path}/$safe.png');
  }

  /// The saved picture for [cacheId], or null if there isn't one yet.
  Future<File?> find(String cacheId) async {
    final f = await _file(cacheId);
    return await f.exists() ? f : null;
  }

  /// Draws the first page of the PDF at [pdfPath] and saves it, unless a
  /// picture for [cacheId] already exists. With [ink] (the first page's
  /// strokes), it is always redrawn with the ink on top. Failures are
  /// ignored: the home page then just shows a plain PDF icon.
  Future<void> ensure(
    String cacheId,
    String pdfPath, {
    List<PageStroke>? ink,
  }) async {
    try {
      final file = await _file(cacheId);
      if (ink == null && await file.exists()) return;
      await pdfrxFlutterInitialize();
      final doc = await PdfDocument.openFile(pdfPath);
      try {
        final page = doc.pages.first;
        final height = (width * page.height / page.width).round();
        final image = await page.render(
          fullWidth: width.toDouble(),
          fullHeight: height.toDouble(),
          width: width,
          height: height,
          backgroundColor: 0xFFFFFFFF,
        );
        if (image == null) return;
        var picture = await image.createImage();
        image.dispose();
        if (ink != null && ink.isNotEmpty) {
          final turns = page.rotation.index;
          final geometry = PageGeometry(
            width: turns.isOdd ? page.height : page.width,
            height: turns.isOdd ? page.width : page.height,
            quarterTurns: turns,
          );
          final withInk = _drawInk(picture, geometry, ink);
          picture.dispose();
          picture = await withInk;
        }
        final png = await picture.toByteData(format: ui.ImageByteFormat.png);
        picture.dispose();
        if (png != null) {
          await file.writeAsBytes(png.buffer.asUint8List(), flush: true);
          // The home page shows the file; drop the old picture from memory.
          await FileImage(file).evict();
        }
      } finally {
        await doc.dispose();
      }
    } catch (_) {
      // No picture; not worth interrupting the user over.
    }
  }

  /// [page] with [ink] drawn on top (pen width without pressure; small
  /// enough not to matter in a thumbnail).
  static Future<ui.Image> _drawInk(
    ui.Image page,
    PageGeometry geometry,
    List<PageStroke> ink,
  ) {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImage(page, ui.Offset.zero, ui.Paint());
    final w = page.width.toDouble();
    final scale = w / geometry.displayWidth;
    ui.Offset at(PageInkPoint p) {
      final v = geometry.toView(PdfPagePoint(p.x, p.y), w);
      return ui.Offset(v.x, v.y);
    }

    for (final s in ink) {
      if (s.points.isEmpty || s.isTextBox) continue;
      final highlighter = s.tool == InkTool.highlighter;
      final paint = ui.Paint()
        ..color = ui.Color(s.colorArgb).withValues(alpha: highlighter ? 0.4 : 1)
        ..strokeWidth = (s.width * scale).clamp(0.6, 40.0)
        ..strokeCap = highlighter ? ui.StrokeCap.butt : ui.StrokeCap.round
        ..strokeJoin = ui.StrokeJoin.round
        ..style = ui.PaintingStyle.stroke
        ..blendMode = highlighter ? ui.BlendMode.multiply : ui.BlendMode.srcOver
        ..isAntiAlias = true;
      final path = ui.Path()
        ..moveTo(at(s.points.first).dx, at(s.points.first).dy);
      for (final p in s.points.skip(1)) {
        path.lineTo(at(p).dx, at(p).dy);
      }
      if (s.points.length == 1) {
        path.lineTo(at(s.points.first).dx + 0.1, at(s.points.first).dy);
      }
      canvas.drawPath(path, paint);
    }
    return recorder.endRecording().toImage(page.width, page.height);
  }

  Future<void> delete(String cacheId) async {
    final f = await _file(cacheId);
    if (await f.exists()) await f.delete();
  }
}
