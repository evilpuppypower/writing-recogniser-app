import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../core/page_coordinates.dart';
import '../core/page_ink.dart';
import 'page_ink_layer.dart' show PageInkPreview;

/// What was chosen on the pages screen (see [showPagesSheet]).
sealed class PagesAction {
  const PagesAction();
}

/// Go to [page].
class GoToPage extends PagesAction {
  const GoToPage(this.page);
  final int page;
}

/// Add a blank page after [page].
class AddPageAfter extends PagesAction {
  const AddPageAfter(this.page);
  final int page;
}

/// Put a copy of [page] just after it.
class DuplicatePage extends PagesAction {
  const DuplicatePage(this.page);
  final int page;
}

/// Take [page] out.
class RemovePage extends PagesAction {
  const RemovePage(this.page);
  final int page;
}

/// Choose another paper for the blank page [page].
class ChangePaper extends PagesAction {
  const ChangePaper(this.page);
  final int page;
}

/// Drag the pages into another order.
class ArrangeShownPages extends PagesAction {
  const ArrangeShownPages();
}

/// Show the PDF's pages that were taken out again.
class RestorePages extends PagesAction {
  const RestorePages();
}

/// Every page of the PDF, small, with its ink and bookmarks (owner's
/// choice: page tools). Tapping one goes there. With [canEdit], pages can
/// also be added, copied, taken out and rearranged (owner: blank pages
/// like any notes app); [removedCount] of the PDF's pages are taken out
/// now. Returns what was chosen, or null.
Future<PagesAction?> showPagesSheet(
  BuildContext context, {
  required PdfDocument document,
  required int currentPage,
  required List<PageStroke> Function(int page) inkOf,
  required PageGeometry Function(PdfPage page) geometryOf,
  List<int> bookmarks = const [],
  bool dark = false,
  bool canEdit = false,
  int removedCount = 0,
  bool Function(int page)? isBlank,
  Widget Function(int page, Widget child)? decorate,
}) => Navigator.of(context).push<PagesAction>(
  MaterialPageRoute(
    builder: (_) => _PagesScreen(
      document: document,
      currentPage: currentPage,
      inkOf: inkOf,
      geometryOf: geometryOf,
      bookmarks: bookmarks,
      dark: dark,
      canEdit: canEdit,
      removedCount: removedCount,
      isBlank: isBlank,
      decorate: decorate,
    ),
  ),
);

class _PagesScreen extends StatefulWidget {
  const _PagesScreen({
    required this.document,
    required this.currentPage,
    required this.inkOf,
    required this.geometryOf,
    required this.bookmarks,
    required this.dark,
    required this.canEdit,
    required this.removedCount,
    required this.isBlank,
    required this.decorate,
  });

  final PdfDocument document;
  final int currentPage;
  final List<PageStroke> Function(int page) inkOf;
  final PageGeometry Function(PdfPage page) geometryOf;
  final List<int> bookmarks;
  final bool dark;
  final bool canEdit;
  final int removedCount;

  /// Whether page n is a blank page of our own (its paper can change).
  final bool Function(int page)? isBlank;

  /// Puts something over page n's thumbnail (e.g. its paper).
  final Widget Function(int page, Widget child)? decorate;

  @override
  State<_PagesScreen> createState() => _PagesScreenState();
}

class _PagesScreenState extends State<_PagesScreen> {
  static const _extent = 170.0;
  late final _scroll = ScrollController();
  bool _onlyWritten = false;

  @override
  void initState() {
    super.initState();
    // Starts near the page that was showing.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      // As the grid lays them out: as many columns of at most [_extent]
      // as fit, 12 apart, inside 12 of padding.
      final width = MediaQuery.sizeOf(context).width - 24;
      final perRow = (width / (_extent + 12)).ceil().clamp(1, 1000);
      final cell = (width - (perRow - 1) * 12) / perRow;
      final row = (widget.currentPage - 1) ~/ perRow;
      _scroll.jumpTo(
        (row * (cell * 1.3 + 12)).clamp(0, _scroll.position.maxScrollExtent),
      );
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final all = [for (var n = 1; n <= widget.document.pages.length; n++) n];
    final pages = _onlyWritten
        ? [
            for (final n in all)
              if (widget.inkOf(n).isNotEmpty || widget.bookmarks.contains(n)) n,
          ]
        : all;
    return Scaffold(
      appBar: AppBar(
        title: Text('Pages (${all.length})'),
        actions: [
          FilterChip(
            label: const Text('With ink or bookmarks'),
            selected: _onlyWritten,
            onSelected: (v) => setState(() => _onlyWritten = v),
          ),
          if (widget.canEdit) ...[
            IconButton(
              tooltip: 'Rearrange pages',
              icon: const Icon(Icons.swap_vert),
              onPressed: () =>
                  Navigator.of(context).pop(const ArrangeShownPages()),
            ),
            if (widget.removedCount > 0)
              IconButton(
                tooltip:
                    'Put back ${widget.removedCount} page'
                    '${widget.removedCount == 1 ? '' : 's'} taken out',
                icon: const Icon(Icons.restore_page_outlined),
                onPressed: () =>
                    Navigator.of(context).pop(const RestorePages()),
              ),
          ],
          const SizedBox(width: 8),
        ],
      ),
      body: pages.isEmpty
          ? const Center(child: Text('No pages with ink or bookmarks yet.'))
          : GridView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: _extent,
                childAspectRatio: 1 / 1.3,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
              ),
              itemCount: pages.length,
              itemBuilder: (context, i) {
                final n = pages[i];
                final page = widget.document.pages[n - 1];
                final here = n == widget.currentPage;
                return Semantics(
                  button: true,
                  label:
                      'Page $n'
                      '${widget.bookmarks.contains(n) ? ', bookmarked' : ''}',
                  child: InkWell(
                    onTap: () => Navigator.of(context).pop(GoToPage(n)),
                    onLongPress: widget.canEdit
                        ? () => _pageMenu(context, n, pages.length)
                        : null,
                    borderRadius: BorderRadius.circular(6),
                    child: Column(
                      children: [
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: here
                                    ? scheme.primary
                                    : scheme.outlineVariant,
                                width: here ? 3 : 1,
                              ),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: AspectRatio(
                              aspectRatio: page.width / page.height,
                              child: PageThumbnail(
                                document: widget.document,
                                page: page,
                                ink: widget.inkOf(n),
                                geometry: widget.geometryOf(page),
                                bookmarked: widget.bookmarks.contains(n),
                                dark: widget.dark,
                                decorate: widget.decorate == null
                                    ? null
                                    : (child) => widget.decorate!(n, child),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '$n',
                          style: TextStyle(
                            fontWeight: here ? FontWeight.bold : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

extension on _PagesScreenState {
  /// Long-press on page [n]: add, copy or take out.
  Future<void> _pageMenu(BuildContext context, int n, int shown) async {
    final navigator = Navigator.of(context);
    final action = await showModalBottomSheet<PagesAction>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Page $n',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.note_add_outlined),
              title: const Text('Add a blank page after this one'),
              onTap: () => Navigator.of(context).pop(AddPageAfter(n)),
            ),
            if (widget.isBlank?.call(n) ?? false)
              ListTile(
                leading: const Icon(Icons.grid_4x4),
                title: const Text('Change paper'),
                onTap: () => Navigator.of(context).pop(ChangePaper(n)),
              ),
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('Duplicate this page'),
              subtitle: const Text('A copy with its ink, just after it'),
              onTap: () => Navigator.of(context).pop(DuplicatePage(n)),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Take this page out'),
              enabled: widget.document.pages.length > 1,
              onTap: () => Navigator.of(context).pop(RemovePage(n)),
            ),
          ],
        ),
      ),
    );
    if (action != null) navigator.pop(action);
  }
}

/// One page, small, with its ink and bookmark (see [showPagesSheet]).
class PageThumbnail extends StatelessWidget {
  const PageThumbnail({
    super.key,
    required this.document,
    required this.page,
    required this.ink,
    required this.geometry,
    this.bookmarked = false,
    this.dark = false,
    this.decorate,
  });

  final PdfDocument document;
  final PdfPage page;
  final List<PageStroke> ink;
  final PageGeometry geometry;
  final bool bookmarked;
  final bool dark;

  /// Puts something over the page, under the ink (e.g. its paper).
  final Widget Function(Widget page)? decorate;

  // The page reversed and its black lifted to dark grey, close to how dark
  // pages show in the viewer (see paintDarkPage).
  static const _night = ColorFilter.matrix([
    -0.875, 0, 0, 0, 255, //
    0, -0.875, 0, 0, 255, //
    0, 0, -0.875, 0, 255, //
    0, 0, 0, 1, 0,
  ]);

  @override
  Widget build(BuildContext context) {
    Widget pdf = PdfPageView(
      document: document,
      pageNumber: page.pageNumber,
      maximumDpi: 48,
      decoration: const BoxDecoration(color: Colors.white),
    );
    if (dark) pdf = ColorFiltered(colorFilter: _night, child: pdf);
    if (decorate != null) pdf = decorate!(pdf);
    // The page and its ink share one box of the page's own shape, so the
    // ink sits on the page whatever space the thumbnail is given.
    return Center(
      child: AspectRatio(
        aspectRatio: page.width / page.height,
        child: _stack(context, pdf),
      ),
    );
  }

  Widget _stack(BuildContext context, Widget pdf) {
    return Stack(
      fit: StackFit.expand,
      children: [
        pdf,
        if (ink.isNotEmpty)
          PageInkPreview(strokes: ink, geometry: geometry, dark: dark),
        if (bookmarked)
          Positioned(
            top: 0,
            right: 6,
            child: Icon(
              Icons.bookmark,
              size: 20,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
      ],
    );
  }
}
