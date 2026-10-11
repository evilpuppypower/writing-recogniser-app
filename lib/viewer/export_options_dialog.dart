import 'package:flutter/material.dart';

import '../core/page_ranges.dart';

/// What the user chose before exporting (task 1.4b).
class ExportChoice {
  const ExportChoice({required this.searchable, this.pages});

  /// Add the recognised handwriting as invisible, searchable text.
  final bool searchable;

  /// Only these pages get searchable text; null means every page with
  /// writing.
  final Set<int>? pages;
}

/// Asks how to export: searchable handwriting text on (owner: the default)
/// or off, for all pages or only some. Null if cancelled.
Future<ExportChoice?> showExportOptions(
  BuildContext context, {
  required int pageCount,
  required bool share,
}) => showDialog<ExportChoice>(
  context: context,
  builder: (_) => _ExportOptionsDialog(pageCount: pageCount, share: share),
);

class _ExportOptionsDialog extends StatefulWidget {
  const _ExportOptionsDialog({required this.pageCount, required this.share});

  final int pageCount;
  final bool share;

  @override
  State<_ExportOptionsDialog> createState() => _ExportOptionsDialogState();
}

class _ExportOptionsDialogState extends State<_ExportOptionsDialog> {
  bool _searchable = true;
  bool _allPages = true;
  final _pages = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _done() {
    Set<int>? pages;
    if (_searchable && !_allPages) {
      try {
        pages = parsePageRanges(_pages.text, widget.pageCount);
      } on FormatException catch (e) {
        setState(() => _error = e.message);
        return;
      }
    }
    Navigator.of(context)
        .pop(ExportChoice(searchable: _searchable, pages: pages));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.share ? 'Share with ink' : 'Export with ink'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Make handwriting searchable'),
              subtitle: const Text(
                'Adds the recognised text, invisibly, over your handwriting, '
                'so you can search and copy it in other PDF apps.',
              ),
              value: _searchable,
              onChanged: (v) => setState(() => _searchable = v),
            ),
            if (_searchable)
              RadioGroup<bool>(
                groupValue: _allPages,
                onChanged: (v) => setState(() {
                  _allPages = v ?? true;
                  _error = null;
                }),
                child: Column(
                  children: [
                    const RadioListTile<bool>(
                      value: true,
                      title: Text('All pages'),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const RadioListTile<bool>(
                      value: false,
                      title: Text('Only some pages'),
                      contentPadding: EdgeInsets.zero,
                    ),
                    if (!_allPages)
                      TextField(
                        controller: _pages,
                        autofocus: true,
                        keyboardType: TextInputType.text,
                        decoration: InputDecoration(
                          labelText: 'Pages',
                          hintText: 'e.g. 1-3, 7',
                          helperText: 'This PDF has ${widget.pageCount} pages.',
                          errorText: _error,
                        ),
                        onSubmitted: (_) => _done(),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _done,
          child: Text(widget.share ? 'Share' : 'Export'),
        ),
      ],
    );
  }
}
