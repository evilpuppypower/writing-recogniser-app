import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

/// The PDF's own contents list and the user's bookmarks; picking one
/// closes the sheet with its page number.
class ContentsSheet extends StatelessWidget {
  const ContentsSheet({
    super.key,
    required this.outline,
    required this.bookmarks,
  });

  final List<PdfOutlineNode> outline;
  final List<int> bookmarks;

  @override
  Widget build(BuildContext context) {
    final entries = <Widget>[];
    void add(List<PdfOutlineNode> nodes, int depth) {
      for (final n in nodes) {
        final page = n.dest?.pageNumber;
        entries.add(
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.only(left: 16.0 + depth * 20, right: 16),
            title: Text(n.title.trim().isEmpty ? '(untitled)' : n.title),
            trailing: page == null ? null : Text('$page'),
            enabled: page != null,
            onTap: page == null ? null : () => Navigator.of(context).pop(page),
          ),
        );
        add(n.children, depth + 1);
      }
    }

    add(outline, 0);
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        children: [
          ListTile(
            title: Text('Bookmarks', style: theme.textTheme.titleMedium),
          ),
          if (bookmarks.isEmpty)
            const ListTile(
              dense: true,
              title: Text(
                'None yet. Use the bookmark button in the title bar to mark '
                'the page you are on.',
              ),
            ),
          for (final p in bookmarks)
            ListTile(
              dense: true,
              leading: const Icon(Icons.bookmark),
              title: Text('Page $p'),
              onTap: () => Navigator.of(context).pop(p),
            ),
          const Divider(),
          ListTile(title: Text('Contents', style: theme.textTheme.titleMedium)),
          if (entries.isEmpty)
            const ListTile(
              dense: true,
              title: Text("This PDF doesn't have a contents list."),
            ),
          ...entries,
        ],
      ),
    );
  }
}
