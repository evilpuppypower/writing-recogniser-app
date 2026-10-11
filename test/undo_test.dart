import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/page_coordinates.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/pen_tools.dart';
import 'package:writing_recogniser/viewer/page_ink_layer.dart';
import 'package:writing_recogniser/viewer/pen_tools_controller.dart';

PageStroke dot(double x) => PageStroke(points: [PageInkPoint(x, 0, 0)]);

void main() {
  group('undo history', () {
    test('undo and redo strokes in order, across pages', () {
      final c = DocumentInkController();
      final changed = <int>[];
      c.onChanged = changed.add;
      c.add(1, dot(1));
      c.add(2, dot(2));
      c.add(1, dot(3));
      expect(c.canRedo, isFalse);

      c.undo();
      expect(c.ink.strokesOn(1), hasLength(1));
      c.undo();
      expect(c.ink.strokesOn(2), isEmpty);
      expect(c.canRedo, isTrue);

      c.redo();
      expect(c.ink.strokesOn(2), hasLength(1));
      expect(changed.last, 2); // saving (1.3) learns which page changed
    });

    test('a new stroke clears redo', () {
      final c = DocumentInkController()
        ..add(1, dot(1))
        ..undo()
        ..add(1, dot(2));
      expect(c.canRedo, isFalse);
      expect(c.ink.strokesOn(1).single.points.single.x, 2);
    });

    test('one eraser gesture is one undo step', () {
      final c = DocumentInkController()
        ..add(1, dot(0))
        ..add(1, dot(10))
        ..add(1, dot(20));
      c.beginGesture(1);
      c.eraseAt(1, 0, 0, 1);
      c.eraseAt(1, 10, 0, 1);
      c.endGesture();
      expect(c.ink.strokesOn(1), hasLength(1));
      c.undo();
      expect(c.ink.strokesOn(1), hasLength(3));
    });

    test('a gesture that changed nothing adds no step', () {
      final c = DocumentInkController()..add(1, dot(0));
      c.beginGesture(1);
      c.eraseAt(1, 500, 500, 1);
      c.endGesture();
      c.undo();
      expect(c.ink.strokesOn(1), isEmpty); // undid the stroke, not the miss
      expect(c.canUndo, isFalse);
    });

    test('history is limited', () {
      final c = DocumentInkController();
      for (var i = 0; i < DocumentInkController.maxHistory + 5; i++) {
        c.add(1, dot(i.toDouble()));
      }
      var steps = 0;
      while (c.canUndo) {
        c.undo();
        steps++;
      }
      expect(steps, DocumentInkController.maxHistory);
    });
  });

  testWidgets('erasing with the pen is undone in one step', (tester) async {
    final ink = DocumentInkController();
    final tools = PenToolsController();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 306,
            height: 396,
            child: PageInkLayer(
              pageNumber: 1,
              geometry: PageGeometry(width: 612, height: 792),
              viewWidth: 306,
              controller: ink,
              tools: tools,
            ),
          ),
        ),
      ),
    );
    final at = tester.getTopLeft(find.byType(PageInkLayer));
    Future<void> line(double y) async {
      final g = await tester.createGesture(kind: PointerDeviceKind.stylus);
      await g.down(at + Offset(50, y));
      await g.moveBy(const Offset(100, 0));
      await g.up();
      await tester.pump();
    }

    await line(100);
    await line(140);
    tools.value = tools.value.copyWith(mode: PenMode.eraser);
    final g = await tester.createGesture(kind: PointerDeviceKind.stylus);
    await g.down(at + const Offset(100, 90));
    await g.moveBy(const Offset(0, 60)); // through both lines
    await g.up();
    await tester.pump();
    expect(ink.ink.strokesOn(1), isEmpty);
    ink.undo();
    expect(ink.ink.strokesOn(1), hasLength(2));
  });
}
