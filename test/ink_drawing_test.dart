import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/page_coordinates.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/viewer/page_ink_layer.dart';

/// Whether the pixel at [at] in [image] is dark (ink).
Future<bool> darkAt(ui.Image image, Offset at) async {
  final bytes = (await image.toByteData())!;
  final i = (at.dy.round() * image.width + at.dx.round()) * 4;
  final r = bytes.getUint8(i), a = bytes.getUint8(i + 3);
  return a > 128 && r < 100;
}

void main() {
  testWidgets('ink drawn once is still right after zooming', (tester) async {
    final ink = DocumentInkController();
    // A thick horizontal line across PDF y 692 (view y 100 at 1 px/pt).
    ink.add(
      1,
      const PageStroke(
        width: 4,
        points: [PageInkPoint(100, 692, 0), PageInkPoint(300, 692, 100)],
      ),
    );
    final key = GlobalKey();
    Future<ui.Image> render(double viewWidth) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: viewWidth,
                height: viewWidth * 792 / 612,
                child: PageInkLayer(
                  pageNumber: 1,
                  geometry: PageGeometry(width: 612, height: 792),
                  viewWidth: viewWidth,
                  controller: ink,
                ),
              ),
            ),
          ),
        ),
      );
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      return (await tester.runAsync(() => boundary.toImage()))!;
    }

    final normal = await render(612);
    expect(
      await tester.runAsync(() => darkAt(normal, const Offset(200, 100))),
      isTrue,
    );
    expect(
      await tester.runAsync(() => darkAt(normal, const Offset(200, 120))),
      isFalse,
    );
    // Zoomed in to twice the size: the same drawing, scaled.
    final zoomed = await render(1224);
    expect(
      await tester.runAsync(() => darkAt(zoomed, const Offset(400, 200))),
      isTrue,
    );
    expect(
      await tester.runAsync(() => darkAt(zoomed, const Offset(400, 100))),
      isFalse,
    );
    // A new stroke shows straight away.
    ink.add(
      1,
      const PageStroke(
        width: 4,
        points: [PageInkPoint(100, 592, 200), PageInkPoint(300, 592, 300)],
      ),
    );
    await tester.pump();
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final after = (await tester.runAsync(() => boundary.toImage()))!;
    expect(
      await tester.runAsync(() => darkAt(after, const Offset(400, 400))),
      isTrue,
    );
  });
}
