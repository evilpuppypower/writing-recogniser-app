import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/bookmarks.dart';

import 'ink_store_test.dart' show MemoryInkStore;

import 'package:writing_recogniser/core/laid_out_stores.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/page_layout.dart';

PageStroke stroke(int t) =>
    PageStroke(points: [PageInkPoint(1, 1, t), PageInkPoint(5, 5, t + 10)]);

List<int> keys(PageLayout l) => [for (final p in l.pages) p.key];

void main() {
  group('page layout', () {
    test('a PDF as it is', () {
      final l = PageLayout.of(3);
      expect(l.isPlain, isTrue);
      expect(keys(l), [1, 2, 3]);
      expect(l.hiddenPdfPages, isEmpty);
    });

    test('blank pages are added with keys of their own', () {
      final (a, k1) = PageLayout.of(2)
          .insert(2, paper: Paper.plain, width: 595, height: 842);
      expect(k1, PageLayout.firstOwnKey);
      expect(keys(a), [1, k1, 2]);
      expect(a.isPlain, isFalse);
      expect(a.at(2).isBlank, isTrue);
      final (b, k2) = a.insert(4, paper: Paper.lined, width: 1, height: 1);
      expect(k2, k1 + 1);
      expect(keys(b), [1, k1, 2, k2]);
      expect(b.positionOf(2), 3);
    });

    test('copies, moves, removes and puts back', () {
      final (copied, k) = PageLayout.of(3).duplicate(2);
      expect(keys(copied), [1, 2, k, 3]);
      expect(copied.at(3).sourcePage, 2);
      expect(copied.at(3).isBlank, isFalse);
      final moved = copied.reorder([4, 3, 2, 1]);
      expect(keys(moved), [3, k, 2, 1]);
      final removed = moved.remove(3);
      expect(keys(removed), [3, k, 1]);
      expect(removed.hiddenPdfPages, [2]);
      // Back after the nearest earlier page of the PDF still shown.
      expect(keys(removed.restore(2)), [3, k, 1, 2]);
      // The last page is never taken out.
      final one = PageLayout.of(1);
      expect(identical(one.remove(1), one), isTrue);
    });

    test('a page taken out never gives its key to a new page', () {
      final (a, k1) = PageLayout.of(1)
          .insert(2, paper: Paper.plain, width: 1, height: 1);
      final removed = a.remove(2);
      final (b, k2) = removed.insert(
        2,
        paper: Paper.plain,
        width: 1,
        height: 1,
      );
      expect(k2, k1 + 1);
      // Kept when saved too.
      final back = PageLayout.fromJson(removed.toJson())!;
      expect(back.nextKey, k1 + 1);
      expect(keys(b), [1, k2]);
    });

    test('kept as JSON, and not trusted when it doesn\'t fit', () {
      final (l, k) = PageLayout.of(2).insert(
        1,
        paper: Paper.linedToFit,
        width: 300,
        height: 400,
        lineGap: 22.5,
      );
      final (l2, _) = l.duplicate(2);
      final back = PageLayout.fromJson(l2.toJson())!;
      expect(keys(back), keys(l2));
      expect(back.at(1).paper, Paper.linedToFit);
      expect(back.at(1).lineGap, 22.5);
      expect(back.at(1).width, 300);
      expect(back.at(3).sourcePage, 1);
      expect(back.positionOf(k), 1);
      expect(PageLayout.fromJson(l2.toJson(), 2), isNotNull);
      expect(
        PageLayout.fromJson(l2.toJson(), 5),
        isNull,
        reason: 'file changed',
      );
      expect(PageLayout.fromJson('not json'), isNull);
      expect(PageLayout.fromJson(null), isNull);
      expect(
        PageLayout.fromJson('{"n":2,"pages":[{"k":1,"s":1},{"k":1,"s":1}]}'),
        isNull,
        reason: 'a key twice',
      );
      expect(
        PageLayout.fromJson('{"n":2,"pages":[{"k":2,"s":1}]}'),
        isNull,
        reason: 'a PDF page under another page\'s number',
      );
    });
  });

  group('saved through the layout', () {
    test('ink and text are kept under each page\'s key', () async {
      final inner = MemoryInkStore();
      await inner.savePage('d', 1, [stroke(1)]);
      await inner.savePage('d', 2, [stroke(2)]);
      await inner.saveText('d', 2, '[2]');
      final (withBlank, k) = PageLayout.of(2)
          .insert(1, paper: Paper.plain, width: 1, height: 1);
      // Shown: blank, page 2 (page 1 taken out).
      var layout = withBlank.remove(2);
      final store = LaidOutInkStore(inner, () => layout);
      final shown = await store.load('d');
      expect(shown.strokesOn(1), isEmpty);
      expect(shown.strokesOn(2).single.points.first.t, 2);
      expect(await store.loadText('d'), {2: '[2]'});
      await store.savePage('d', 1, [stroke(9)]);
      expect((await inner.load('d')).strokesOn(k).single.points.first.t, 9);
      // Page 1's ink is kept while it's hidden.
      expect((await inner.load('d')).strokesOn(1), hasLength(1));
      // Put back first, before the blank page.
      layout = layout.restore(1);
      expect((await store.load('d')).strokesOn(1).single.points.first.t, 1);
      expect((await store.load('d')).strokesOn(2).single.points.first.t, 9);
    });

    test('bookmarks too', () async {
      final inner = MemoryBookmarkStore();
      await inner.set('d', 2, on: true);
      final (layout, _) = PageLayout.of(2)
          .insert(1, paper: Paper.plain, width: 1, height: 1);
      final store = LaidOutBookmarkStore(inner, () => layout);
      expect(await store.pages('d'), [3]);
      await store.set('d', 1, on: true);
      expect(await inner.pages('d'), [2, PageLayout.firstOwnKey]);
    });

    test('a plain layout is kept too (it remembers the next key)', () async {
      final store = MemoryPageLayoutStore();
      final (l, _) = PageLayout.of(2)
          .insert(1, paper: Paper.plain, width: 1, height: 1);
      await store.save('d', l);
      expect(await store.load('d'), isNotNull);
      await store.save('d', l.remove(1));
      final back = PageLayout.fromJson(await store.load('d'))!;
      expect(back.isPlain, isTrue);
      expect(back.nextKey, PageLayout.firstOwnKey + 1);
    });
  });
}
