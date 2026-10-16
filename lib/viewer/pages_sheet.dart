import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../core/page_coordinates.dart';
import '../core/page_ink.dart';
import 'page_ink_layer.dart' show PageInkPreview;

/// Every page of the PDF, small, with its ink and bookmarks (owner's
/// choice: page tools). Tapping one goes there. Returns the page tapped,
/// or null.
Future<int?> showPagesSheet(
  BuildContext context, {
  required PdfDocument document,
  required int currentPage,
  required List<PageStroke> Function(int page) inkOf,
  required PageGeometry Function(PdfPage page) geometryOf,
  List<int> bookmarks = const [],
  bool dark = false,
}) => Navigator.of(context).push<int>(
  MaterialPageRoute(
    builder: (_) => _PagesScreen(
      document: document,
      currentPage: currentPage,
      inkOf: inkOf,
      geometryOf: geometryOf,
      bookmarks: bookmarks,
      dark: dark,
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
  });

  final PdfDocument document;
  final int currentPage;
  final List<PageStroke> Function(int page) inkOf;
  final PageGeometry Function(PdfPage page) geometryOf;
  final List<int> bookmarks;
  final bool dark;

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
                    onTap: () => Navigator.of(context).pop(n),
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
  });

  final PdfDocument document;
  final PdfPage page;
  final List<PageStroke> ink;
  final PageGeometry geometry;
  final bool bookmarked;
  final bool dark;

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
