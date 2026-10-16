import 'package:flutter/material.dart';

import '../core/app_settings.dart' show PageColours;

/// What was picked in [askPageColours]: the PDF's own page colours (null:
/// Settings' choice), and whether to stop asking when PDFs are imported.
typedef PageColoursPick = ({PageColours? colours, bool stopAsking});

/// Asks how this PDF's pages are shown (owner: dark pages are chosen when a
/// PDF comes in, at export and in Settings). When importing, it starts on
/// Settings' choice [byDefault] and offers to stop asking; otherwise it
/// starts on [current] and offers going back to Settings' choice. Null if
/// cancelled.
Future<PageColoursPick?> askPageColours(
  BuildContext context, {
  required PageColours byDefault,
  PageColours? current,
  bool importing = false,
}) => showDialog<PageColoursPick>(
  context: context,
  builder: (_) => _PageColoursDialog(
    byDefault: byDefault,
    current: current,
    importing: importing,
  ),
);

class _PageColoursDialog extends StatefulWidget {
  const _PageColoursDialog({
    required this.byDefault,
    required this.current,
    required this.importing,
  });

  final PageColours byDefault;
  final PageColours? current;
  final bool importing;

  @override
  State<_PageColoursDialog> createState() => _PageColoursDialogState();
}

class _PageColoursDialogState extends State<_PageColoursDialog> {
  // Null stands for "Settings' choice" (only offered outside importing).
  late PageColours? _picked = widget.importing
      ? widget.byDefault
      : widget.current;
  bool _stopAsking = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.importing ? 'How should this PDF look?' : 'Page colours',
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Dark pages are easier on the eyes at night. Only the screen '
              'changes: the PDF itself never does.',
            ),
            const SizedBox(height: 8),
            RadioGroup<PageColours?>(
              groupValue: _picked,
              onChanged: (v) => setState(() => _picked = v),
              child: Column(
                children: [
                  for (final c in PageColours.values)
                    RadioListTile<PageColours?>(
                      value: c,
                      title: Text(c.label),
                      contentPadding: EdgeInsets.zero,
                    ),
                  if (!widget.importing)
                    RadioListTile<PageColours?>(
                      value: null,
                      title: const Text("Same as Settings"),
                      subtitle: Text('Now: ${widget.byDefault.label}'),
                      contentPadding: EdgeInsets.zero,
                    ),
                ],
              ),
            ),
            if (widget.importing)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text("Don't ask when I import a PDF"),
                subtitle: const Text(
                  'New PDFs then use the choice in Settings. You can change '
                  "any PDF's colours by holding it on the home screen.",
                ),
                value: _stopAsking,
                onChanged: (v) => setState(() => _stopAsking = v ?? false),
              ),
          ],
        ),
      ),
      actions: [
        if (!widget.importing)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context)
                  .pop((colours: _picked, stopAsking: _stopAsking)),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
