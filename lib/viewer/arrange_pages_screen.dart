import 'package:flutter/material.dart';

/// Arranging the pages of an export (owner's choice: page tools): drag to
/// reorder, remove pages, add blank ones. Only the exported copy changes;
/// the PDF itself never does (CLAUDE.md rule 6). [start] is the current
/// arrangement (1-based page numbers; null is a blank page). Returns the
/// new arrangement, or null if cancelled.
Future<List<int?>?> arrangePages(
  BuildContext context, {
  required int pageCount,
  List<int?>? start,
  Widget Function(int page)? thumbnail,
}) => Navigator.of(context).push<List<int?>>(
  MaterialPageRoute(
    builder: (_) => _ArrangePagesScreen(
      pageCount: pageCount,
      start: start ?? [for (var n = 1; n <= pageCount; n++) n],
      thumbnail: thumbnail,
    ),
  ),
);

class _ArrangePagesScreen extends StatefulWidget {
  const _ArrangePagesScreen({
    required this.pageCount,
    required this.start,
    required this.thumbnail,
  });

  final int pageCount;
  final List<int?> start;
  final Widget Function(int page)? thumbnail;

  @override
  State<_ArrangePagesScreen> createState() => _ArrangePagesScreenState();
}

class _ArrangePagesScreenState extends State<_ArrangePagesScreen> {
  // Each entry keeps its own key, so a page listed twice or several blank
  // pages move as themselves.
  late final _pages = [
    for (final n in widget.start) (key: UniqueKey(), page: n),
  ];

  @override
  Widget build(BuildContext context) {
    final real = _pages.where((p) => p.page != null).length;
    return Scaffold(
      appBar: AppBar(
        title: Text('Arrange pages (${_pages.length})'),
        actions: [
          TextButton(
            onPressed: () => setState(() {
              _pages
                ..clear()
                ..addAll([
                  for (var n = 1; n <= widget.pageCount; n++)
                    (key: UniqueKey(), page: n),
                ]);
            }),
            child: const Text('Reset'),
          ),
          FilledButton(
            onPressed: real == 0
                ? null
                : () =>
                      Navigator.of(context)
                          .pop([for (final p in _pages) p.page]),
            child: const Text('Done'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Drag the handle to move a page. Only the exported copy '
              'changes: your PDF stays as it is.',
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              itemCount: _pages.length,
              onReorderItem: (from, to) =>
                  setState(() => _pages.insert(to, _pages.removeAt(from))),
              itemBuilder: (context, i) {
                final p = _pages[i];
                final n = p.page;
                return ListTile(
                  key: p.key,
                  leading: SizedBox(
                    width: 48,
                    height: 64,
                    child: n == null
                        ? DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              border: Border.all(
                                color: Theme.of(context).colorScheme.outline,
                              ),
                            ),
                          )
                        : (widget.thumbnail?.call(n) ??
                              const Icon(Icons.description_outlined)),
                  ),
                  title: Text(n == null ? 'Blank page' : 'Page $n'),
                  subtitle: Text('${i + 1} in the export'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Add a blank page after this one',
                        icon: const Icon(Icons.note_add_outlined),
                        onPressed: () => setState(
                          () => _pages.insert(i + 1, (
                            key: UniqueKey(),
                            page: null,
                          )),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Leave this page out',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => setState(() => _pages.removeAt(i)),
                      ),
                      ReorderableDragStartListener(
                        index: i,
                        child: const Tooltip(
                          message: 'Drag to move',
                          child: Padding(
                            padding: EdgeInsets.all(8),
                            child: Icon(Icons.drag_handle),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
