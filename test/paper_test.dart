import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/page_layout.dart';
import 'package:writing_recogniser/core/paper.dart';
import 'package:writing_recogniser/viewer/paper_painter.dart';

void main() {
  group('paper', () {
    test('plain has nothing, lined has ruled lines 8 mm apart', () {
      expect(paperMarks(Paper.plain, 595, 842), isEmpty);
      final lines = paperMarks(Paper.lined, 595, 842);
      // A4 is 297 mm: lines from 12 mm down to the foot.
      expect(lines.length, inInclusiveRange(34, 36));
      expect(lines.first.$2 - lines[1].$2, closeTo(ruledGap, 1e-9));
      for (final (x1, y1, x2, y2) in lines) {
        expect((x1, x2), (0.0, 595.0));
        expect(y1, y2);
        expect(y1, inExclusiveRange(0, 842));
      }
    });

    test('lined to fit uses the gap given', () {
      final lines = paperMarks(Paper.linedToFit, 595, 842, lineGap: 40);
      expect(lines.first.$2 - lines[1].$2, closeTo(40, 1e-9));
    });

    test('a line gap that makes no sense falls back to ruled lines', () {
      for (final bad in [0.0, -5.0, double.nan, double.infinity]) {
        final lines = paperMarks(Paper.linedToFit, 595, 842, lineGap: bad);
        expect(lines.first.$2 - lines[1].$2, closeTo(ruledGap, 1e-9));
      }
    });

    test('squared and dotted on a 5 mm grid', () {
      final squared = paperMarks(Paper.squared, 100, 100);
      expect(squared.where((m) => m.$1 == m.$3), isNotEmpty); // upright
      expect(squared.where((m) => m.$2 == m.$4), isNotEmpty); // across
      final dots = paperMarks(Paper.dotted, 100, 100);
      expect(dots.every((m) => m.$1 == m.$3 && m.$2 == m.$4), isTrue);
      // 100 pt is about 7 grid steps each way.
      expect(dots.length, 49);
    });

    test('the line gap that suits the writing, within reason', () {
      expect(lineGapFor(10), closeTo(22, 1e-9));
      expect(lineGapFor(1), closeTo(4 / 25.4 * 72, 1e-9));
      expect(lineGapFor(100), closeTo(16 / 25.4 * 72, 1e-9));
      expect(typicalLineLetter([5, 6]), isNull, reason: 'too little');
      expect(typicalLineLetter([9, 5, 6, 7]), 7);
    });

    test('exported as lines, dots as points', () {
      expect(
        paperExportLines(
          const LaidOutPage.blank(1, paper: Paper.plain, width: 1, height: 1),
        ),
        isEmpty,
      );
      final dots = paperExportLines(
        const LaidOutPage.blank(1, paper: Paper.dotted, width: 50, height: 50),
      );
      expect(dots, isNotEmpty);
      expect(dots.first.points[2] - dots.first.points[0], closeTo(0.02, 1e-9));
      expect(dots.first.colorArgb, paperArgb);
      expect(paperExportLines(const LaidOutPage.pdf(1)), isEmpty);
    });

    test('a blank page\'s paper can change; the PDF\'s pages can\'t', () {
      final (l, k) = PageLayout.of(1)
          .insert(2, paper: Paper.plain, width: 10, height: 20);
      final changed = l.withPaper(2, Paper.linedToFit, lineGap: 30);
      expect(changed.at(2).paper, Paper.linedToFit);
      expect(changed.at(2).lineGap, 30);
      expect(changed.at(2).key, k);
      expect(changed.at(2).width, 10);
      expect(identical(changed.withPaper(1, Paper.lined), changed), isTrue);
    });
  });

  testWidgets('choosing the paper and where the page goes', (tester) async {
    ({Paper paper, bool atEnd})? chosen;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                chosen = await showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => const PaperChooser(
                    title: 'Add a blank page',
                    start: Paper.plain,
                    afterPage: 3,
                  ),
                );
              },
              child: const Text('Add'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('Lined to fit your writing'), findsOneWidget);
    await tester.tap(find.text('Squared'));
    await tester.pump();
    await tester.tap(find.text('Add after page 3'));
    await tester.pumpAndSettle();
    expect(chosen?.paper, Paper.squared);
    expect(chosen?.atEnd, isFalse);
    expect(tester.takeException(), isNull);
  });
}
