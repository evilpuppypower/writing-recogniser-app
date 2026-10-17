import 'package:flutter/material.dart';

import '../core/highlights.dart';

/// The highlights summary (owner's idea 17): what you highlighted and
/// noted, page by page. Tap a page to go there; copy or save all of it.
class HighlightsSheet extends StatelessWidget {
  const HighlightsSheet({
    super.key,
    required this.pages,
    required this.onGoTo,
    required this.onCopy,
    required this.onSave,
  });

  final List<PageHighlights> pages;
  final ValueChanged<int> onGoTo;
  final VoidCallback onCopy;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = [
      for (final p in pages)
        if (!p.isEmpty) p,
    ];
    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (context, scroll) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Highlights and notes',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy'),
                    onPressed: shown.isEmpty ? null : onCopy,
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.save_alt),
                    label: const Text('Save'),
                    onPressed: shown.isEmpty ? null : onSave,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: shown.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Nothing highlighted or noted yet. Use the '
                        'highlighter over printed text, or write a note '
                        'beside it, and it shows here.',
                      ),
                    )
                  : ListView(
                      controller: scroll,
                      children: [
                        for (final p in shown) ...[
                          ListTile(
                            dense: true,
                            title: Text(
                              'Page ${p.page}',
                              style: theme.textTheme.titleSmall,
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => onGoTo(p.page),
                          ),
                          for (final h in p.highlights)
                            ListTile(
                              dense: true,
                              leading: const Icon(Icons.format_quote),
                              title: Text(h),
                              onTap: () => onGoTo(p.page),
                            ),
                          for (final n in p.notes)
                            ListTile(
                              dense: true,
                              leading: const Icon(Icons.edit_note),
                              title: Text(n.note),
                              subtitle: n.nextTo == null
                                  ? null
                                  : Text(
                                      'Next to: “${n.nextTo}”',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                              onTap: () => onGoTo(p.page),
                            ),
                          const Divider(height: 1),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
