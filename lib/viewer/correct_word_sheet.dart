import 'package:flutter/material.dart';

import 'ink_text_controller.dart';

/// What the user chose in the correction pop-up.
sealed class WordFix {
  const WordFix();
}

/// The word really reads [text] (an alternative, typed or dictated).
class UseText extends WordFix {
  const UseText(this.text);
  final String text;
}

/// The word was read right (it was shown with a "?").
class LooksRight extends WordFix {
  const LooksRight();
}

/// Add [word] to the user's own words (it's preferred when reading).
class AddToMyWords extends WordFix {
  const AddToMyWords(this.word);
  final String word;
}

/// [short] is the user's shorthand for [full].
class AddShorthand extends WordFix {
  const AddShorthand(this.short, this.full);
  final String short, full;
}

/// The ink isn't writing (a drawing, a tick); stop reading it.
class NotWriting extends WordFix {
  const NotWriting();
}

/// The correction pop-up (task 2.4): the engine's other readings to tap,
/// a box to type the right word (the keyboard's microphone works for
/// speaking it), and "this isn't writing". An automatic swap can be undone
/// from here. Returns null if closed without a choice.
Future<WordFix?> showCorrectWordSheet(
  BuildContext context,
  RecognizedWord word,
) => showModalBottomSheet<WordFix>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => _CorrectWordSheet(word: word),
);

class _CorrectWordSheet extends StatefulWidget {
  const _CorrectWordSheet({required this.word});

  final RecognizedWord word;

  @override
  State<_CorrectWordSheet> createState() => _CorrectWordSheetState();
}

class _CorrectWordSheetState extends State<_CorrectWordSheet> {
  final _typed = TextEditingController();

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  void _use(String text) {
    if (text.trim().isEmpty) return;
    Navigator.pop(context, UseText(text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.word;
    final theme = Theme.of(context);
    final options = [
      for (final a in w.alternatives)
        if (a != w.text) a,
    ];
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Read as “${w.text}”', style: theme.textTheme.titleMedium),
          if (w.unsure && !w.corrected) ...[
            const SizedBox(height: 4),
            Text(
              "Not sure about this one. If it's right, say so: it won't ask "
              'about this word again.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.check),
              label: Text("It's right: “${w.text}”"),
              onPressed: () => Navigator.pop(context, const LooksRight()),
            ),
          ],
          if (w.autoReplaced) ...[
            const SizedBox(height: 4),
            Text(
              w.fromYourWords
                  ? 'Changed automatically from “${w.engineReading}” because '
                        "it's a word you often write."
                  : 'Changed automatically from “${w.engineReading}” because '
                        'you corrected it before.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.undo),
              label: Text('Undo: use “${w.engineReading}”'),
              onPressed: () => _use(w.engineReading),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.bookmark_add_outlined),
                label: const Text('Add to my words'),
                onPressed: () {
                  final typed = _typed.text.trim();
                  Navigator.pop(
                    context,
                    AddToMyWords(typed.isEmpty ? w.text : typed),
                  );
                },
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.short_text),
                label: Text('“${w.text}” is my shorthand for…'),
                onPressed: () async {
                  final full = await showDialog<String>(
                    context: context,
                    builder: (_) => _ShorthandDialog(short: w.text),
                  );
                  if (full == null || full.trim().isEmpty || !context.mounted) {
                    return;
                  }
                  Navigator.pop(context, AddShorthand(w.text, full.trim()));
                },
              ),
            ],
          ),
          if (options.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('Did you mean', style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final o in options.take(6))
                  ActionChip(label: Text(o), onPressed: () => _use(o)),
              ],
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _typed,
            autofocus: options.isEmpty && !w.autoReplaced,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'Type the right word',
              helperText: "Or tap the keyboard's microphone and say it.",
              border: OutlineInputBorder(),
            ),
            onSubmitted: _use,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              TextButton.icon(
                icon: const Icon(Icons.gesture),
                label: const Text("This isn't writing"),
                onPressed: () => Navigator.pop(context, const NotWriting()),
              ),
              const Spacer(),
              FilledButton(
                onPressed: () => _use(_typed.text),
                child: const Text('Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Asks what a shorthand stands for; pops it.
class _ShorthandDialog extends StatefulWidget {
  const _ShorthandDialog({required this.short});

  final String short;

  @override
  State<_ShorthandDialog> createState() => _ShorthandDialogState();
}

class _ShorthandDialogState extends State<_ShorthandDialog> {
  final _full = TextEditingController();

  @override
  void dispose() {
    _full.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('“${widget.short}” stands for'),
    content: TextField(
      controller: _full,
      autofocus: true,
      decoration: const InputDecoration(hintText: 'e.g. with'),
      onSubmitted: (v) => Navigator.of(context).pop(v),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(_full.text),
        child: const Text('Add'),
      ),
    ],
  );
}
