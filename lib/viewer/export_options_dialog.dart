import 'package:flutter/material.dart';

import '../core/page_ranges.dart';
import '../core/typed_text.dart' show ExportHandwriting;
import 'arrange_pages_screen.dart';

/// What the user chose before exporting (task 1.4b).
class ExportChoice {
  const ExportChoice({
    required this.searchable,
    this.pages,
    this.handwriting = ExportHandwriting.ink,
    this.convertRest = false,
    this.askedConvertRest = false,
    this.darkPages = false,
    this.pageOrder,
  });

  /// The new PDF's pages in this order (1-based page numbers; null is a
  /// blank page), instead of [pages] (owner's choice: page tools).
  final List<int?>? pageOrder;

  /// The new PDF's pages dark, as on screen (owner: dark pages are chosen
  /// at export too).
  final bool darkPages;

  /// Handwriting, typed text or both (task 2.3d).
  final ExportHandwriting handwriting;

  /// For typed text: also convert the handwriting not converted yet, in the
  /// exported copy only (task 1.4, owner's choice 1b).
  final bool convertRest;

  /// Whether the "Also convert" tick was shown (so its choice is
  /// remembered for next time).
  final bool askedConvertRest;

  /// Add the recognised handwriting as invisible, searchable text.
  final bool searchable;

  /// Only these pages are exported (and made searchable, if chosen); null
  /// means every page (task 1.4c, owner).
  final Set<int>? pages;
}

/// Asks how to export: searchable handwriting text on (owner: the default)
/// or off, and all pages or only some (only those go in the new PDF).
/// Null if cancelled.
///
/// How handwriting goes in (ink, typed text or both) is asked when there is
/// any: [anyConverted] (some was converted to typed text) or
/// [anyUnconverted] (some wasn't, and could be at export). It starts on
/// [startWith] (what's on screen).
Future<ExportChoice?> showExportOptions(
  BuildContext context, {
  required int pageCount,
  required bool share,
  ExportHandwriting startWith = ExportHandwriting.ink,
  bool anyConverted = false,
  bool anyUnconverted = false,
  bool? convertRest,
  bool darkNow = false,
  Widget Function(int page)? thumbnail,
}) => showDialog<ExportChoice>(
  context: context,
  builder: (_) => _ExportOptionsDialog(
    pageCount: pageCount,
    share: share,
    startWith: startWith,
    anyConverted: anyConverted,
    anyUnconverted: anyUnconverted,
    convertRest: convertRest,
    darkNow: darkNow,
    thumbnail: thumbnail,
  ),
);

class _ExportOptionsDialog extends StatefulWidget {
  const _ExportOptionsDialog({
    required this.pageCount,
    required this.share,
    required this.startWith,
    required this.anyConverted,
    required this.anyUnconverted,
    this.convertRest,
    this.darkNow = false,
    this.thumbnail,
  });

  /// A small picture of a page, for arranging pages.
  final Widget Function(int page)? thumbnail;

  /// Whether the pages are dark on screen now (the dark switch starts so).
  final bool darkNow;

  final int pageCount;
  final bool share;
  final ExportHandwriting startWith;
  final bool anyConverted;
  final bool anyUnconverted;

  /// The "Also convert" tick as last chosen (null: not chosen yet).
  final bool? convertRest;

  @override
  State<_ExportOptionsDialog> createState() => _ExportOptionsDialogState();
}

class _ExportOptionsDialogState extends State<_ExportOptionsDialog> {
  bool _searchable = true;
  late bool _dark = widget.darkNow;
  late ExportHandwriting _handwriting = widget.startWith;

  /// As last chosen (owner); before that, ticked when nothing is converted
  /// yet (typed text would be empty otherwise).
  late bool _convertRest = widget.convertRest ?? !widget.anyConverted;
  // Which pages: all, some (typed), or arranged by hand.
  _Pages _which = _Pages.all;
  List<int?>? _arranged;
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
    if (_which == _Pages.arranged && _arranged == null) {
      setState(() => _error = 'Arrange the pages first.');
      return;
    }
    if (_which == _Pages.some) {
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
        convertRest:
            _handwriting != ExportHandwriting.ink &&
            widget.anyUnconverted &&
            _convertRest,
        askedConvertRest:
            _handwriting != ExportHandwriting.ink && widget.anyUnconverted,
        darkPages: _dark,
        pageOrder: _which == _Pages.arranged ? _arranged : null,
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
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Dark pages'),
              subtitle: const Text(
                'The new PDF has dark pages with light ink, as on screen. '
                'Text in it can still be searched and copied.',
              ),
              value: _dark,
              onChanged: (v) => setState(() => _dark = v),
            ),
            if (widget.anyConverted || widget.anyUnconverted) ...[
              const SizedBox(height: 8),
              Text(
                'Handwriting',
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
              if (_handwriting != ExportHandwriting.ink &&
                  widget.anyUnconverted)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text(
                    "Also convert handwriting I haven't converted",
                  ),
                  subtitle: const Text(
                    'Only in the exported copy: your handwriting in the app '
                    'stays as it is.',
                  ),
                  value: _convertRest,
                  onChanged: (v) => setState(() => _convertRest = v ?? false),
                ),
            ],
            const SizedBox(height: 8),
            Text('Pages', style: Theme.of(context).textTheme.titleSmall),
            RadioGroup<_Pages>(
              groupValue: _which,
              onChanged: (v) => setState(() {
                _which = v ?? _Pages.all;
                _error = null;
              }),
              child: Column(
                children: [
                  const RadioListTile<_Pages>(
                    value: _Pages.all,
                    title: Text('All pages'),
                    contentPadding: EdgeInsets.zero,
                  ),
                  const RadioListTile<_Pages>(
                    value: _Pages.some,
                    title: Text('Only some pages'),
                    subtitle: Text('The new PDF has just these pages.'),
                    contentPadding: EdgeInsets.zero,
                  ),
                  if (_which == _Pages.some)
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
                  const RadioListTile<_Pages>(
                    value: _Pages.arranged,
                    title: Text('Arrange pages'),
                    subtitle: Text(
                      'Reorder, leave out or add blank pages, in the new PDF '
                      'only.',
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),
                  if (_which == _Pages.arranged) ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.view_list_outlined),
                        label: Text(
                          _arranged == null
                              ? 'Arrange…'
                              : 'Arranged: ${_arranged!.length} '
                                    '${_arranged!.length == 1 ? 'page' : 'pages'} (change)',
                        ),
                        onPressed: () async {
                          final order = await arrangePages(
                            context,
                            pageCount: widget.pageCount,
                            start: _arranged,
                            thumbnail: widget.thumbnail,
                          );
                          if (order != null && mounted) {
                            setState(() {
                              _arranged = order;
                              _error = null;
                            });
                          }
                        },
                      ),
                    ),
                    if (_error != null)
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                  ],
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

enum _Pages { all, some, arranged }
