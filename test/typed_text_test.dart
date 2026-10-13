import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/ink_export_plan.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/stroke_grouping.dart';
import 'package:writing_recogniser/core/typed_text.dart';
import 'package:writing_recogniser/viewer/ink_text_controller.dart';
import 'package:writing_recogniser/viewer/page_ink_layer.dart';

/// A letter-sized stroke at (x, y), started at time [t].
PageStroke letter(double x, double y, int t, {int color = 0xFF1A1A1A}) =>
    PageStroke(
      colorArgb: color,
      points: [
        PageInkPoint(x, y, t),
        PageInkPoint(x + 3, y + 10, t + 40),
        PageInkPoint(x + 6, y, t + 80),
      ],
    );

void main() {
  group('converting words (task 2.3b)', () {
    late DocumentInk ink;
    late List<PageStroke> cat, dog;

    setUp(() {
      cat = [letter(100, 700, 0), letter(107, 700, 200), letter(114, 700, 400)];
      dog = [letter(140, 700, 1000, color: 0xFFD32F2F), letter(147, 700, 1200)];
      ink = DocumentInk();
      for (final s in [...cat, ...dog, letter(300, 500, 9000)]) {
        ink.add(1, s);
      }
    });

    Set<String> ids(List<PageStroke> s) => {for (final x in s) x.id};

    test('keeps the ink, groups the strokes, and puts the text on one', () {
      expect(ink.convert(1, {ids(cat): 'cat', ids(dog): 'dog'}), isTrue);
      final strokes = ink.strokesOn(1);
      expect(strokes, hasLength(6), reason: 'nothing removed');
      expect(strokes.where((s) => s.typedText != null), hasLength(2));
      final words = typedWords(strokes);
      expect(words.map((w) => w.text), ['cat', 'dog']);
      expect(words.first.strokeIds, ids(cat));
      expect(words.last.colorArgb, 0xFFD32F2F, reason: "the ink's colour");
      expect(words.first.box.left, 100);
      expect(words.first.box.right, 120);
      expect(
        ink.convert(1, {ids(cat): 'cat'}),
        isFalse,
        reason: 'already converted',
      );
    });

    test('is saved with the ink', () {
      ink.convert(1, {ids(cat): 'cat'});
      final back = DocumentInk.fromJson(ink.toJson());
      expect(typedWords(back.strokesOn(1)).single.text, 'cat');
    });

    test('editing changes the text; empty text is refused', () {
      ink.convert(1, {ids(cat): 'cat'});
      final group = typedWords(ink.strokesOn(1)).single.group;
      expect(ink.setTypedText(1, group, '  cart '), isTrue);
      expect(typedWords(ink.strokesOn(1)).single.text, 'cart');
      expect(ink.setTypedText(1, group, '  '), isFalse);
    });

    test('rubbing out part of a word keeps it converted, text shown once', () {
      ink.convert(1, {ids(cat): 'cat'});
      // Cut through the middle of the first letter.
      ink.eraseArea(1, 103, 705, 1);
      final words = typedWords(ink.strokesOn(1));
      expect(words.single.text, 'cat');
      expect(ink.strokesOn(1).where((s) => s.typedText != null), hasLength(1));
    });

    test('converting again keeps an edited word as it is', () {
      ink.convert(1, {ids(cat): 'cat'});
      final group = typedWords(ink.strokesOn(1)).single.group;
      ink.setTypedText(1, group, 'cart');
      expect(ink.convert(1, {ids(cat): 'cat'}), isFalse);
      expect(typedWords(ink.strokesOn(1)).single.text, 'cart');
    });

    test('the eraser can be told to leave hidden ink alone', () {
      ink.convert(1, {ids(cat): 'cat'});
      bool hidden(PageStroke s) => s.typedGroup != null;
      expect(ink.eraseAt(1, 103, 705, 5, protect: hidden), isEmpty);
      expect(ink.eraseArea(1, 103, 705, 5, protect: hidden), isFalse);
      expect(ink.eraseAt(1, 103, 705, 5), isNotEmpty);
    });

    test('undo takes the conversion back in one step', () {
      final c = DocumentInkController(ink);
      c.convert(1, {ids(cat): 'cat', ids(dog): 'dog'});
      final group = typedWords(c.ink.strokesOn(1)).first.group;
      c.setTypedText(1, group, 'cart');
      c.undo();
      expect(typedWords(c.ink.strokesOn(1)).first.text, 'cat');
      c.undo();
      expect(typedWords(c.ink.strokesOn(1)), isEmpty);
      c.redo();
      expect(typedWords(c.ink.strokesOn(1)), hasLength(2));
    });
  });

  group('one box per line (owner\'s choice F1)', () {
    test('words converted on one line show as one line of text', () {
      final ink = DocumentInk();
      final a = [letter(100, 700, 0), letter(107, 700, 200)];
      final b = [letter(140, 700, 1000), letter(147, 700, 1200)];
      // Same height but far across the page: its own line.
      final far = [letter(480, 700, 3000), letter(487, 700, 3200)];
      final below = [letter(100, 660, 5000), letter(107, 660, 5200)];
      for (final s in [...a, ...b, ...far, ...below]) {
        ink.add(1, s);
      }
      Set<String> ids(List<PageStroke> s) => {for (final x in s) x.id};
      // Converted at different times: still one line on screen.
      ink.convert(1, {ids(b): 'cat'});
      ink.convert(1, {ids(a): 'the', ids(far): 'note', ids(below): 'dog'});
      final lines = typedLines(ink.strokesOn(1));
      expect(lines.map((l) => l.text), ['the cat', 'note', 'dog']);
      final first = lines.first;
      expect(first.box.left, 100);
      expect(first.box.right, 153);
      expect(first.fontSize, fitFontSize('the cat', first.box));
      // Exported the same way.
      expect(
        typedForExport(
          ink.strokesOn(1),
          ExportHandwriting.typed,
        ).map((w) => w.text),
        ['the cat', 'note', 'dog'],
      );
    });

    test('converting keeps each line together, words in order', () {
      RecognizedWord w(String text, String key, int line, double left) =>
          RecognizedWord(
            text: text,
            alternatives: const [],
            box: InkBox(left, 0, left + 10, 10),
            line: line,
            key: key,
          );
      final map = typedTextByLine([
        w('cat', 'c1,c2', 0, 140),
        w('the', 't1', 0, 100),
        w('dog', 'd1', 1, 100),
        w(' ', 'x1', 1, 200), // nothing read: left out
      ]);
      expect(map.values, ['the cat', 'dog']);
      expect(map.keys.first, {'c1', 'c2', 't1'});
    });
  });

  group('fitting the text to the handwriting', () {
    test('as tall as the handwriting allows', () {
      expect(fitFontSize('hi', const InkBox(0, 0, 100, 20)), 16);
    });

    test('narrower when the text is long', () {
      final size = fitFontSize(
        'internationalisation',
        const InkBox(0, 0, 60, 20),
      );
      expect(size, closeTo(60 / (20 * averageCharWidth), 1e-9));
    });

    test('never tiny', () {
      expect(fitFontSize('word', const InkBox(0, 0, 4, 1)), minTypedFontSize);
    });
  });

  group('exporting converted handwriting (task 2.3d)', () {
    late DocumentInk ink;
    setUp(() {
      final cat = [letter(100, 700, 0), letter(107, 700, 200)];
      ink = DocumentInk();
      for (final s in [...cat, letter(300, 500, 9000)]) {
        ink.add(1, s);
      }
      ink.convert(1, {
        {for (final s in cat) s.id}: 'cat',
      });
    });

    test('typed text only: the converted ink is left out, the rest stays', () {
      final out = inkForExport(ink, ExportHandwriting.typed);
      expect(out.strokesOn(1), hasLength(1));
      expect(
        inkForExport(ink, ExportHandwriting.both).strokesOn(1),
        hasLength(3),
      );
      expect(
        inkForExport(ink, ExportHandwriting.ink).strokesOn(1),
        hasLength(3),
      );
    });

    test('typed text goes over the ink, or under it for both', () {
      final strokes = ink.strokesOn(1);
      expect(typedForExport(strokes, ExportHandwriting.ink), isEmpty);
      final over = typedForExport(strokes, ExportHandwriting.typed).single;
      expect(over.text, 'cat');
      expect(over.visible, isTrue);
      expect((over.bottom, over.top), (700, 710));
      expect(over.under, isFalse);
      final under = typedForExport(strokes, ExportHandwriting.both).single;
      expect(under.under, isTrue);
      // Placed by the writer: baseline below the handwriting.
      final m = typedPlacement(under, 0, 8);
      expect(m.f, lessThan(700));
      expect(typedPlacement(over, 0, 8).f, greaterThan(700));
    });

    test('upright on pages turned sideways', () {
      const w = ExportWord('cat', 100, 500, 120, 600, colorArgb: 0);
      // Turned a quarter clockwise: the text runs up the page.
      final m = typedPlacement(w, 1, 10);
      expect((m.a, m.b, m.c, m.d), (0.0, 10.0, -10.0, 0.0));
      expect(m.f, 500, reason: 'starts at the on-screen left');
      expect(m.e, inInclusiveRange(100, 120), reason: 'within the width');
      expect(typedSizeOnPage(w, 1), 16, reason: 'fits 20 pt across');
      expect(typedSizeOnPage(w, 0), lessThan(16));
    });
  });
}
