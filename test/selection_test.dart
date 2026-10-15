import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/page_coordinates.dart';
import 'package:writing_recogniser/core/pen_tools.dart';
import 'package:writing_recogniser/core/selection.dart';
import 'package:writing_recogniser/viewer/pdf_viewer_screen.dart'
    show SelectionBar;
import 'package:writing_recogniser/core/ink_classifier.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/stroke_grouping.dart';
import 'package:writing_recogniser/viewer/page_ink_layer.dart';

import 'typed_text_test.dart' show letter;

void main() {
  late DocumentInk ink;
  late PageStroke a, b, c;

  setUp(() {
    a = letter(100, 700, 0);
    b = letter(107, 700, 200, color: 0xFFD32F2F);
    c = letter(300, 500, 9000);
    ink = DocumentInk();
    for (final s in [a, b, c]) {
      ink.add(1, s);
    }
  });

  test('moving and resizing keeps the strokes (and their ids)', () {
    expect(ink.moveScale(1, {a.id, b.id}, dx: 10, dy: -5), isTrue);
    final moved = ink.strokesOn(1);
    expect(moved[0].id, a.id);
    expect(moved[0].points.first.x, 110);
    expect(moved[0].points.first.y, 695);
    expect(moved[2].points.first.x, 300, reason: 'not selected');
    // Twice the size around (100, 700): widths double too.
    ink.moveScale(1, {c.id}, scale: 2, originX: 300, originY: 500);
    final big = ink.strokesOn(1)[2];
    expect(big.points[1].x, 306);
    expect(big.points[1].y, 520);
    expect(big.width, c.width * 2);
  });

  test('recolour, delete and paste copies', () {
    expect(ink.recolour(1, {a.id}, 0xFF1565C0), isTrue);
    expect(ink.strokesOn(1).first.colorArgb, 0xFF1565C0);
    final gone = ink.remove(1, {b.id});
    expect(gone.single.id, b.id);
    expect(ink.strokesOn(1), hasLength(2));
    ink.addAll(2, gone);
    expect(ink.strokesOn(2).single.colorArgb, 0xFFD32F2F);
  });

  test('"Read as one word" is saved and makes one word', () {
    // Two strokes far enough apart to be read as two words.
    final far = letter(140, 700, 400);
    ink.add(1, far);
    expect(groupStrokes(ink.strokesOn(1)).first.words, hasLength(2));
    expect(ink.markOneWord(1, {a.id, b.id, far.id}), isTrue);
    final back = DocumentInk.fromJson(ink.toJson());
    final words = groupStrokes(back.strokesOn(1)).first.words;
    expect(words, hasLength(1));
    expect(words.single.strokes, hasLength(3));
    expect(words.single.box.right, 146);
  });

  test('undo takes a whole drag back in one step', () {
    final c2 = DocumentInkController(ink);
    c2.beginGesture(1);
    for (var i = 0; i < 5; i++) {
      c2.moveScale(1, {a.id}, dx: 2);
    }
    c2.endGesture();
    expect(c2.ink.strokesOn(1).first.points.first.x, 110);
    c2.undo();
    expect(c2.ink.strokesOn(1).first.points.first.x, 100);
  });

  group('a second look at writing vs drawing', () {
    PageStroke line(double x1, double y1, double x2, double y2, int t) =>
        PageStroke(
          points: [PageInkPoint(x1, y1, t), PageInkPoint(x2, y2, t + 50)],
        );

    test('letters taken for a drawing that touch writing are writing', () {
      // "the": the engine called the letters a drawing but the crossbar
      // of the t writing.
      final letters = [letter(100, 700, 0), letter(106, 700, 200)];
      final crossbar = line(98, 707, 106, 707, 400);
      final strokes = [...letters, crossbar];
      final kinds = reconcileKinds(strokes, [
        InkKind.drawing,
        InkKind.drawing,
        InkKind.writing,
      ]);
      expect(kinds, everyElement(InkKind.writing));
    });

    test('a circle round writing stays a drawing', () {
      final letters = [
        for (var i = 0; i < 6; i++) letter(100 + i * 8.0, 700, i),
      ];
      final circle = PageStroke(
        points: [
          for (var k = 0; k <= 32; k++)
            PageInkPoint(
              124 + 35 * math.cos(k * math.pi / 16),
              705 + 18 * math.sin(k * math.pi / 16),
              1000 + k,
            ),
        ],
      );
      final kinds = reconcileKinds(
        [...letters, circle],
        [for (var i = 0; i < 6; i++) InkKind.writing, InkKind.drawing],
      );
      expect(kinds.last, InkKind.drawing);
    });

    test('strokes the user said are a word are writing', () {
      final s = letter(100, 700, 0).copyWith(manualWord: 'x');
      expect(reconcileKinds([s], [InkKind.drawing]), [InkKind.writing]);
    });
  });

  test('pasted copies: new ids, moved, plain ink, own "one word" mark', () {
    final marked = a.copyWith(manualWord: 'w');
    final copies = pastedCopies([marked, b], 50000);
    expect(copies.map((x) => x.id).toSet().intersection({a.id, b.id}), isEmpty);
    expect(copies.first.points.first.x, a.points.first.x + 12);
    expect(copies.first.points.first.y, a.points.first.y - 12);
    expect(copies.first.manualWord, isNot('w'));
    expect(copies.last.colorArgb, b.colorArgb);
  });

  group('the Select tool on the page', () {
    late DocumentInkController ctl;
    late ValueNotifier<InkSelection?> sel;
    var cleared = 0;

    Future<void> pump(WidgetTester tester) async {
      ctl = DocumentInkController(ink);
      sel = ValueNotifier(InkSelection(1, {a.id, b.id}));
      cleared = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 612,
              height: 792,
              child: PageInkLayer(
                pageNumber: 1,
                geometry: PageGeometry(width: 612, height: 792),
                viewWidth: 612,
                controller: ctl,
                tools: ValueNotifier(const PenToolsState(mode: PenMode.lasso)),
                selection: sel,
                onClearSelection: () {
                  cleared++;
                  sel.value = null;
                },
              ),
            ),
          ),
        ),
      );
    }

    Future<void> drag(WidgetTester tester, Offset from, Offset to) async {
      final pen = await tester.createGesture(kind: PointerDeviceKind.stylus);
      await pen.down(from);
      for (var k = 1; k <= 4; k++) {
        await pen.moveTo(Offset.lerp(from, to, k / 4)!);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await pen.up();
      await tester.pump();
    }

    testWidgets('dragging inside moves the strokes, in one undo step', (
      tester,
    ) async {
      await pump(tester);
      // a is at PDF (100..106, 700..710): screen y 82..92 at 1 px/pt.
      await drag(tester, const Offset(105, 87), const Offset(145, 67));
      final moved = ctl.ink.strokesOn(1);
      expect(moved[0].points.first.x, closeTo(140, 0.01));
      expect(moved[0].points.first.y, closeTo(720, 0.01), reason: 'up');
      expect(moved[2].points.first.x, 300, reason: 'not selected');
      ctl.undo();
      expect(ctl.ink.strokesOn(1)[0].points.first.x, 100);
      expect(cleared, 0);
    });

    testWidgets('dragging the corner dot resizes', (tester) async {
      await pump(tester);
      final rect = selectionRect(
        ctl.ink.strokesOn(1),
        sel.value!.ids,
        PageGeometry(width: 612, height: 792),
        612,
      )!;
      final handle = selectionHandles(rect).resize;
      await drag(tester, handle, handle + (rect.bottomRight - rect.topLeft));
      final s = ctl.ink.strokesOn(1);
      final width = s[1].points.last.x - s[0].points.first.x;
      expect(width, greaterThan(19), reason: 'about twice 13 pt');
      expect(s[0].width, greaterThan(a.width));
    });

    testWidgets('dragging the bottom-left dot turns it, in one undo step', (
      tester,
    ) async {
      await pump(tester);
      final geometry = PageGeometry(width: 612, height: 792);
      final rect = selectionRect(
        ctl.ink.strokesOn(1),
        sel.value!.ids,
        geometry,
        612,
      )!;
      final c = rect.center;
      // A quarter turn clockwise on screen: (x, y) -> (-y, x) about c.
      final handle = selectionHandles(rect).rotate;
      final v = handle - c;
      await drag(tester, handle, c + Offset(-v.dy, v.dx));
      final mid = geometry.toPdf(ViewPoint(c.dx, c.dy), 612);
      final turned = ctl.ink.strokesOn(1);
      final want = levelPoint(a.points.first, math.pi / 2, mid.x, mid.y);
      expect(turned[0].points.first.x, closeTo(want.x, 0.01));
      expect(turned[0].points.first.y, closeTo(want.y, 0.01));
      expect(turned[0].id, a.id, reason: 'same strokes, same words');
      expect(turned[2].points.first.x, 300, reason: 'not selected');
      ctl.undo();
      expect(ctl.ink.strokesOn(1)[0].points.first.x, 100);
    });

    testWidgets('touching the turn handle without turning changes nothing', (
      tester,
    ) async {
      await pump(tester);
      final rect = selectionRect(
        ctl.ink.strokesOn(1),
        sel.value!.ids,
        PageGeometry(width: 612, height: 792),
        612,
      )!;
      final h = selectionHandles(rect).rotate;
      await drag(tester, h, h + const Offset(1, 1));
      expect(ctl.canUndo, isFalse);
      expect(ctl.ink.strokesOn(1)[0].points.first.x, 100);
    });

    testWidgets('a tiny selection can still be dragged from its middle', (
      tester,
    ) async {
      await pump(tester);
      // Just a: 6 x 10 pt, so its box is small.
      sel.value = InkSelection(1, {a.id});
      await tester.pump();
      final rect = selectionRect(
        ctl.ink.strokesOn(1),
        {a.id},
        PageGeometry(width: 612, height: 792),
        612,
      )!;
      expect(rect.shortestSide, lessThan(3 * 14));
      await drag(tester, rect.center, rect.center + const Offset(30, 0));
      expect(ctl.ink.strokesOn(1)[0].points.first.x, closeTo(130, 0.01));
      expect(ctl.ink.strokesOn(1)[0].width, a.width, reason: 'not resized');
    });

    test('turns snap to none or a quarter turn when close', () {
      expect(snapTurn(0.05), 0);
      expect(snapTurn(math.pi / 2 + 0.03), math.pi / 2);
      expect(snapTurn(0.5), 0.5);
    });

    testWidgets('a loop elsewhere drops the selection', (tester) async {
      await pump(tester);
      await drag(tester, const Offset(400, 400), const Offset(450, 450));
      expect(cleared, 1);
      expect(ctl.ink.strokesOn(1)[0].points.first.x, 100, reason: 'unmoved');
    });
  });

  testWidgets('the selection bar\'s buttons say what they do', (tester) async {
    tester.view.physicalSize = const Size(1600, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final done = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionBar(
            count: 2,
            onOneWord: () => done.add('word'),
            onConvert: () => done.add('convert'),
            onColour: () => done.add('colour'),
            onCopy: () => done.add('copy'),
            onDelete: () => done.add('delete'),
            onNotWriting: () => done.add('not'),
            onClose: () => done.add('close'),
            onCut: () => done.add('cut'),
            onDuplicate: () => done.add('duplicate'),
            onThickness: () => done.add('thickness'),
            onStraighten: () => done.add('straighten'),
            onCopyText: () => done.add('text'),
            onShare: () => done.add('share'),
          ),
        ),
      ),
    );
    for (final label in ['One word', 'Convert', 'Copy', 'Delete']) {
      await tester.tap(find.text(label));
    }
    // The rest are under the three dots.
    for (final label in [
      'Copy text',
      'Colour',
      'Thickness',
      'Straighten',
      'Duplicate',
      'Cut',
      'Share',
      'Not writing',
    ]) {
      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byIcon(Icons.close));
    expect(done, [
      'word',
      'convert',
      'copy',
      'delete',
      'text',
      'colour',
      'thickness',
      'straighten',
      'duplicate',
      'cut',
      'share',
      'not',
      'close',
    ]);
    expect(find.byTooltip('Read these strokes as one word'), findsOneWidget);
  });

  test('Thickness: widths scale, within each tool\'s limits', () {
    (double, double) limits(InkTool t) => t == InkTool.pen
        ? (PenStyle.minPenWidth, PenStyle.maxPenWidth)
        : (PenStyle.minHighlighterWidth, PenStyle.maxHighlighterWidth);
    expect(ink.scaleWidth(1, {a.id, b.id}, 2, limits), isTrue);
    expect(ink.strokesOn(1).map((s) => s.width), [2.4, 2.4, 1.2]);
    ink.scaleWidth(1, {a.id}, 100, limits);
    expect(ink.strokesOn(1).first.width, PenStyle.maxPenWidth);
    expect(ink.scaleWidth(1, {'nope'}, 2, limits), isFalse);
  });

  test('Straighten: a slanted line comes out level, keeping its ids', () {
    final angle = 20 * math.pi / 180;
    final slanted = [
      for (var i = 0; i < 8; i++)
        PageStroke(
          points: [
            for (final p in letter(100.0 + i * 7, 700, i * 200).points)
              levelPoint(p, -angle, 100, 700),
          ],
        ),
    ];
    final level = straightened(slanted);
    expect(level.map((s) => s.id), slanted.map((s) => s.id));
    final bottoms = [for (final s in level) InkBox.of(s).bottom];
    expect(bottoms.reduce(math.max) - bottoms.reduce(math.min), lessThan(0.5));
    // A small tilt (6 degrees, too little to read as slanted) too.
    final tilt = 6 * math.pi / 180;
    final tilted = [
      for (var i = 0; i < 8; i++)
        PageStroke(
          points: [
            for (final p in letter(100.0 + i * 7, 700, i * 200).points)
              levelPoint(p, -tilt, 100, 700),
          ],
        ),
    ];
    final fixed = straightened(tilted);
    expect(fixed, hasLength(8));
    final feet = [for (final s in fixed) InkBox.of(s).bottom];
    expect(feet.reduce(math.max) - feet.reduce(math.min), lessThan(0.5));
    // Level writing is left as it is, even with tall letters and tails
    // ("d o g" and "small"), and so is ink that isn't writing.
    PageStroke at(double x, double bottom, double h, int t) => PageStroke(
      points: [
        PageInkPoint(x, bottom, t),
        PageInkPoint(x + 3, bottom + h, t + 40),
        PageInkPoint(x + 6, bottom, t + 80),
      ],
    );
    expect(
      straightened([
        at(100, 700, 15, 0),
        at(107, 700, 10, 200),
        at(114, 695, 15, 400),
      ]),
      isEmpty,
    );
    expect(
      straightened([
        for (final (i, h) in [10.0, 10.0, 10.0, 15.0, 15.0, 10.0].indexed)
          at(100 + i * 7.0, 700, h, i * 200),
      ]),
      isEmpty,
    );
    expect(
      straightened([for (final s in slanted) s.copyWith(notWriting: true)]),
      isEmpty,
    );
    expect(
      straightened([
        for (var i = 0; i < 4; i++) letter(100.0 + i * 7, 700, i * 200),
      ]),
      isEmpty,
    );
  });

  test('Copy as text: the words mostly inside, line by line', () {
    final text = selectionText(
      [
        (line: 0, strokeIds: ['a', 'b'], text: 'the'),
        (line: 0, strokeIds: ['c'], text: 'cat'),
        (line: 1, strokeIds: ['d', 'e', 'f'], text: 'sat'),
        (line: 1, strokeIds: ['g'], text: 'down'),
      ],
      {'a', 'b', 'c', 'd', 'e'},
    );
    expect(text, 'the cat\nsat');
    expect(selectionText(const [], {'a'}), '');
  });

  testWidgets('Share: a picture of just the selected ink, on white', (
    tester,
  ) async {
    final png = await tester.runAsync(
      () => inkImage([a, b], PageGeometry(width: 612, height: 792)),
    );
    expect(png, isNotNull);
    // A PNG file, about (13 pt + margins) x 4 px wide.
    expect(png!.sublist(1, 4), 'PNG'.codeUnits);
    final w = (png[16] << 24) | (png[17] << 16) | (png[18] << 8) | png[19];
    expect(w, inInclusiveRange(60, 120));
    expect(
      await tester.runAsync(
        () => inkImage(const [], PageGeometry(width: 612, height: 792)),
      ),
      isNull,
    );
  });
}
