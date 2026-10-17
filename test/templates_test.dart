import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/page_layout.dart';
import 'package:writing_recogniser/core/page_templates.dart';
import 'package:writing_recogniser/core/paper.dart';
import 'package:writing_recogniser/viewer/paper_painter.dart';

PageStroke stroke(double x, double y, {InkTool tool = InkTool.pen}) =>
    PageStroke(
      tool: tool,
      width: 2,
      points: [PageInkPoint(x, y, 1000), PageInkPoint(x + 10, y, 1100)],
    );

void main() {
  test('the new papers draw inside the page', () {
    for (final p in [Paper.cornell, Paper.todo, Paper.weekly]) {
      final marks = paperMarks(p, 595, 842);
      expect(marks, isNotEmpty, reason: p.name);
      for (final (x1, y1, x2, y2) in marks) {
        for (final v in [x1, x2]) {
          expect(v, inInclusiveRange(0, 595));
        }
        for (final v in [y1, y2]) {
          expect(v, inInclusiveRange(0, 842));
        }
      }
      expect(paperName(p), isNotEmpty);
    }
  });

  test('a template keeps its ink, never read as writing, stretched to fit', () {
    final t = PageTemplate.fromPage(
      name: ' Lab report ',
      paper: Paper.lined,
      width: 100,
      height: 200,
      strokes: [stroke(10, 20)],
    );
    expect(t.name, 'Lab report');
    expect(t.strokes.single.notWriting, isTrue);
    final copy = t.strokesFor(200, 400, now: 5000);
    expect(copy.single.points.first.x, 20);
    expect(copy.single.points.first.y, 40);
    expect(copy.single.points.first.t, 5000);
    expect(copy.single.points.last.t, 5100);
    expect(copy.single.width, 4);
  });

  test('kept and read back; the same name replaces', () {
    final lib = TemplateLibrary()
      ..add(
        PageTemplate.fromPage(
          name: 'Week',
          paper: Paper.weekly,
          width: 595,
          height: 842,
          strokes: [stroke(1, 2)],
        ),
      )
      ..add(
        const PageTemplate(
          name: 'week',
          paper: Paper.todo,
          width: 595,
          height: 842,
        ),
      );
    expect(lib.templates.single.paper, Paper.todo);
    final back = TemplateLibrary()..load(lib.toJson());
    expect(back.templates.single.name, 'week');
    back.load('nonsense');
    expect(back.templates, isEmpty);
    expect(PageTemplate.fromJson({'name': 'x', 'paper': 'nope'}), isNull);
  });

  testWidgets('the chooser offers your templates, and one can be removed', (
    tester,
  ) async {
    PaperChoice? chosen;
    final removed = <String>[];
    const t = PageTemplate(
      name: 'Lab report',
      paper: Paper.squared,
      width: 595,
      height: 842,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => chosen = await showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              builder: (_) => PaperChooser(
                title: 'Add a blank page',
                start: Paper.plain,
                templates: const [
                  t,
                  PageTemplate(
                    name: 'Old',
                    paper: Paper.plain,
                    width: 1,
                    height: 1,
                  ),
                ],
                onRemoveTemplate: (x) => removed.add(x.name),
              ),
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('Your templates'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove the template "Old"'));
    await tester.pump();
    expect(removed, ['Old']);
    expect(find.text('Old'), findsNothing);
    await tester.tap(find.text('Lab report'));
    await tester.pump();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(chosen!.template!.name, 'Lab report');
    expect(chosen!.paper, Paper.squared);
  });
}
