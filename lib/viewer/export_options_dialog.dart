import 'package:flutter/material.dart';

import '../core/page_ranges.dart';
import '../core/typed_text.dart' show ExportHandwriting;

/// What the user chose before exporting (task 1.4b).
class ExportChoice {
  const ExportChoice({
    required this.searchable,
    this.pages,
    this.handwriting = ExportHandwriting.ink,
  });

  /// Handwriting, typed text or both (task 2.3d; only asked when some
  /// handwriting has been converted).
  final ExportHandwriting handwriting;

  /// Add the recognised handwriting as invisible, searchable text.
  final bool searchable;

  /// Only these pages are exported (and made searchable, if chosen); null
  /// means every page (task 1.4c, owner).
  final Set<int>? pages;
}

/// Asks how to export: searchable handwriting text on (owner: the default)
/// or off, and all pages or only some (only those go in the new PDF).
/// Null if cancelled.
Future<ExportChoice?> showExportOptions(
  BuildContext context, {
  required int pageCount,
  required bool share,
  ExportHandwriting? typed,
}) => showDialog<ExportChoice>(
  context: context,
  builder: (_) =>
      _ExportOptionsDialog(pageCount: pageCount, share: share, typed: typed),
);

class _ExportOptionsDialog extends StatefulWidget {
  const _ExportOptionsDialog({
    required this.pageCount,
    required this.share,
    this.typed,
  });

  final int pageCount;
  final bool share;

  /// Null when nothing has been converted to typed text; otherwise the
  /// choice to start with (what's on screen).
  final ExportHandwriting? typed;

  @override
  State<_ExportOptionsDialog> createState() => _ExportOptionsDialogState();
}

class _ExportOptionsDialogState extends State<_ExportOptionsDialog> {
  bool _searchable = true;
  late ExportHandwriting _handwriting = widget.typed ?? ExportHandwriting.ink;
  bool _allPages = true;
  final _pages = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  /// "Exports pages 1–3 (3 of 5)" once the pages typed can be read.
  String _preview() {
    final all = 'This PDF has ${widget.pageCount} pages.';
    if (_pages.text.trim().isEmpty) return all;
    try {
      final pages = parsePageRanges(_pages.text, widget.pageCount);
      final n = pages.length;
      return 'Exports ${n == 1 ? 'page' : 'pages'} ${describePages(pages)} '
          '($n of ${widget.pageCount}).';
    } on FormatException {
      return all;
    }
  }

  void _done() {
    Set<int>? pages;
    if (!_allPages) {
      try {
        pages = parsePageRanges(_pages.text, widget.pageCount);
      } on FormatException catch (e) {
        setState(() => _error = e.message);
        return;
      }
    }
    Navigator.of(context).pop(
      ExportChoice(
        searchable: _searchable,
        pages: pages,
        handwriting: _handwriting,
      ),
    );
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
            if (widget.typed != null) ...[
              const SizedBox(height: 8),
              Text(
                'Converted handwriting',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              RadioGroup<ExportHandwriting>(
                groupValue: _handwriting,
                onChanged: (v) =>
                    setState(() => _handwriting = v ?? _handwriting),
                child: Column(
                  children: [
                    for (final h in ExportHandwriting.values)
                      RadioListTile<ExportHandwriting>(
                        value: h,
                        title: Text(h.label),
                        contentPadding: EdgeInsets.zero,
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text('Pages', style: Theme.of(context).textTheme.titleSmall),
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
                    subtitle: Text('The new PDF has just these pages.'),
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
                        // Says which pages will go in, as you type.
                        helperText: _preview(),
                        errorText: _error,
                      ),
                      onChanged: (_) => setState(() => _error = null),
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
