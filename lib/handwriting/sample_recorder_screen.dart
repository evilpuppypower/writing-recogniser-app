import 'package:flutter/material.dart';

import '../core/labeled_sample.dart';
import '../core/prompts.dart';
import '../core/sample_store.dart';
import '../settings/settings_controller.dart';
import 'handed_writing_box.dart';
import 'ink_canvas.dart';
import 'ink_controller.dart';

enum _Mode { prompted, free }

/// Records labeled handwriting samples: either copying a prompted sentence,
/// or free writing followed by typing what was written.
class SampleRecorderScreen extends StatefulWidget {
  const SampleRecorderScreen({super.key, required this.store});

  final SampleStore store;

  @override
  State<SampleRecorderScreen> createState() => _SampleRecorderScreenState();
}

class _SampleRecorderScreenState extends State<SampleRecorderScreen> {
  final _ink = InkController();
  _Mode _mode = _Mode.prompted;
  int _promptIndex = 0;
  int _saved = 0;
  Size _canvasSize = Size.zero;

  @override
  void initState() {
    super.initState();
    _ink.addListener(_onInkChanged);
    widget.store.count().then((n) {
      if (!mounted) return;
      setState(() {
        _saved = n;
        _promptIndex = n % samplePrompts.length;
      });
    });
  }

  void _onInkChanged() => setState(() {});

  @override
  void dispose() {
    _ink.removeListener(_onInkChanged);
    _ink.dispose();
    super.dispose();
  }

  String get _prompt => samplePrompts[_promptIndex];

  void _nextPrompt() => setState(() {
    _promptIndex = (_promptIndex + 1) % samplePrompts.length;
    _ink.clear();
  });

  Future<void> _save() async {
    if (_ink.strokes.isEmpty) return;
    String? text = _prompt;
    if (_mode == _Mode.free) {
      text = await showDialog<String>(
        context: context,
        builder: (_) => const _TypeWhatYouWroteDialog(),
      );
      if (text == null || text.trim().isEmpty) return;
    }
    await widget.store.add(
      LabeledSample(
        text: text.trim(),
        strokes: _ink.strokes,
        createdAt: DateTime.now(),
        canvasWidth: _canvasSize.width,
        canvasHeight: _canvasSize.height,
        hover: _ink.hover,
      ),
    );
    if (!mounted) return;
    setState(() => _saved++);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Saved sample $_saved')));
    if (_mode == _Mode.prompted) {
      _nextPrompt();
    } else {
      _ink.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Record samples'),
        actions: [
          IconButton(
            tooltip: 'Undo last stroke',
            icon: const Icon(Icons.undo),
            onPressed: _ink.strokes.isEmpty ? null : _ink.undo,
          ),
          IconButton(
            tooltip: 'Clear the writing area',
            icon: const Icon(Icons.clear_all),
            onPressed: _ink.isEmpty ? null : _ink.clear,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: LinearProgressIndicator(
                        value: (_saved / sampleGoal).clamp(0.0, 1.0),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text('$_saved saved · goal $sampleGoal'),
                  ],
                ),
                const SizedBox(height: 12),
                SegmentedButton<_Mode>(
                  segments: const [
                    ButtonSegment(
                      value: _Mode.prompted,
                      label: Text('Copy a sentence'),
                      icon: Icon(Icons.format_quote),
                    ),
                    ButtonSegment(
                      value: _Mode.free,
                      label: Text('Free writing'),
                      icon: Icon(Icons.edit_note),
                    ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (v) => setState(() {
                    _mode = v.single;
                    _ink.clear();
                  }),
                ),
                const SizedBox(height: 12),
                if (_mode == _Mode.prompted)
                  Card(
                    child: ListTile(
                      title: Text(_prompt, style: theme.textTheme.titleMedium),
                      subtitle: const Text(
                        'Write this sentence below, as you normally would.',
                      ),
                      trailing: TextButton(
                        onPressed: _nextPrompt,
                        child: const Text('Skip'),
                      ),
                    ),
                  )
                else
                  const Card(
                    child: ListTile(
                      title: Text('Write anything you like'),
                      subtitle: Text(
                        "When you tap Save, you'll type what you wrote.",
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: HandedWritingBox(
                child: Card(
                  clipBehavior: Clip.antiAlias,
                  margin: EdgeInsets.zero,
                  child: LayoutBuilder(
                    builder: (context, c) {
                      _canvasSize = c.biggest;
                      return InkCanvas(
                        controller: _ink,
                        pressure: SettingsScope.of(context)
                            .value
                            .pressureResponse,
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Write with the pen. Hold its button to erase.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                FilledButton.icon(
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Save sample'),
                  onPressed: _ink.strokes.isEmpty ? null : _save,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TypeWhatYouWroteDialog extends StatefulWidget {
  const _TypeWhatYouWroteDialog();

  @override
  State<_TypeWhatYouWroteDialog> createState() =>
      _TypeWhatYouWroteDialogState();
}

class _TypeWhatYouWroteDialogState extends State<_TypeWhatYouWroteDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('What did you write?'),
    content: TextField(
      controller: _text,
      autofocus: true, // opens the keyboard
      decoration: const InputDecoration(
        hintText: 'Type exactly what you wrote',
      ),
      onSubmitted: (v) => Navigator.pop(context, v),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _text.text),
        child: const Text('Save'),
      ),
    ],
  );
}
