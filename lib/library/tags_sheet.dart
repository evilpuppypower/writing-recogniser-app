import 'package:flutter/material.dart';

import '../core/tags.dart';

/// What was chosen on [TagsSheet]: the document's tags, and the tags made
/// there (to save first).
class TagsChoice {
  const TagsChoice(this.names, this.newTags);

  final Set<String> names;
  final List<Tag> newTags;
}

/// Choosing a document's tags: its tags (tap × to take one off), the
/// suggestions (tap to add), the other tags, and a new tag with a colour.
class TagsSheet extends StatefulWidget {
  const TagsSheet({
    super.key,
    required this.documentName,
    required this.known,
    required this.current,
    required this.suggestions,
    this.moreSuggestions,
  });

  final String documentName;
  final List<Tag> known;
  final Set<String> current;
  final List<String> suggestions;

  /// Suggestions that take a while (read from what's written): shown
  /// when ready, with a progress line until then.
  final Future<List<String>>? moreSuggestions;

  @override
  State<TagsSheet> createState() => _TagsSheetState();
}

class _TagsSheetState extends State<TagsSheet> {
  late final _names = {...widget.current};
  final _made = <String, Tag>{};
  final _field = TextEditingController();
  late int _colour = tagColours[(widget.known.length) % tagColours.length];
  late List<String> _suggestions = widget.suggestions;
  late bool _looking = widget.moreSuggestions != null;

  @override
  void initState() {
    super.initState();
    widget.moreSuggestions?.catchError((_) => const <String>[]).then((more) {
      if (!mounted) return;
      setState(() {
        _looking = false;
        _suggestions = more;
      });
    });
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Tag? _tag(String name) {
    for (final t in [...widget.known, ..._made.values]) {
      if (t.name.toLowerCase() == name.toLowerCase()) return t;
    }
    return null;
  }

  /// Adds [name] (a new tag gets the colour chosen).
  void _add(String name, {int? colour}) {
    final n = tidyTagName(name);
    if (n.isEmpty) return;
    final known = _tag(n);
    setState(() {
      if (known != null) {
        _names.add(known.name);
      } else {
        _made[n] = Tag(n, colour ?? _colour);
        _names.add(n);
        _colour =
            tagColours[(widget.known.length + _made.length) %
                tagColours.length];
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final others = [
      for (final t in widget.known)
        if (!_names.contains(t.name)) t,
    ];
    final suggested = [
      for (final s in _suggestions)
        if (!_names.any((n) => n.toLowerCase() == s.toLowerCase())) s,
    ];
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          0,
          16,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Tags for ${widget.documentName}',
                style: theme.textTheme.titleMedium,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              if (_names.isEmpty)
                const Text('No tags yet.')
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final n in _names.toList()..sort())
                      InputChip(
                        avatar: _Dot(_tag(n)?.colourArgb ?? _colour),
                        label: Text(n),
                        deleteButtonTooltipMessage: 'Take the tag "$n" off',
                        onDeleted: () => setState(() => _names.remove(n)),
                      ),
                  ],
                ),
              if (_looking) ...[
                const SizedBox(height: 16),
                Text(
                  'Looking through what\'s written for suggestions…',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                const LinearProgressIndicator(),
              ],
              if (suggested.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('Suggested', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final s in suggested)
                      ActionChip(
                        avatar: const Icon(Icons.add, size: 18),
                        label: Text(s),
                        tooltip: 'Add the tag "$s"',
                        onPressed: () => _add(s),
                      ),
                  ],
                ),
              ],
              if (others.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('Your tags', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final t in others)
                      ActionChip(
                        avatar: _Dot(t.colourArgb),
                        label: Text(t.name),
                        tooltip: 'Add the tag "${t.name}"',
                        onPressed: () => _add(t.name),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              Text('New tag', style: theme.textTheme.titleSmall),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _field,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(hintText: 'Name'),
                      onSubmitted: (v) {
                        _add(v);
                        _field.clear();
                      },
                    ),
                  ),
                  IconButton(
                    tooltip: 'Add this tag',
                    icon: const Icon(Icons.add),
                    onPressed: () {
                      _add(_field.text);
                      _field.clear();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ColourChoice(
                selected: _colour,
                onSelected: (c) => setState(() => _colour = c),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(
                    TagsChoice(_names, [
                      for (final t in _made.values)
                        if (_names.contains(t.name)) t,
                    ]),
                  ),
                  child: const Text('Done'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The tag colours to pick from.
class ColourChoice extends StatelessWidget {
  const ColourChoice({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final int selected;
  final ValueChanged<int> onSelected;

  static const _names = [
    'blue',
    'green',
    'orange',
    'purple',
    'red',
    'teal',
    'yellow',
    'brown',
  ];

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    children: [
      for (final (i, c) in tagColours.indexed)
        Tooltip(
          message: 'Colour: ${_names[i]}',
          child: InkResponse(
            onTap: () => onSelected(c),
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: Color(c),
                shape: BoxShape.circle,
                border: Border.all(
                  color: c == selected
                      ? Theme.of(context).colorScheme.onSurface
                      : Colors.transparent,
                  width: 3,
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

/// A tag's colour or deleting it. Pops the new colour, or [delete].
class TagColourSheet extends StatefulWidget {
  const TagColourSheet({super.key, required this.tag, this.usedBy = 0});

  final Tag tag;

  /// How many documents have it (said before it's deleted).
  final int usedBy;

  static const delete = 'delete';

  @override
  State<TagColourSheet> createState() => _TagColourSheetState();
}

class _TagColourSheetState extends State<TagColourSheet> {
  late int _colour = widget.tag.colourArgb;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Tag "${widget.tag.name}"',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          ColourChoice(
            selected: _colour,
            onSelected: (c) => setState(() => _colour = c),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              TextButton.icon(
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete this tag'),
                onPressed: () async {
                  final n = widget.usedBy;
                  final sure = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Text('Delete the tag "${widget.tag.name}"?'),
                      content: Text(
                        n == 0
                            ? 'No documents have it.'
                            : 'It comes off ${n == 1 ? 'the 1 document' : 'all $n documents'} '
                                  'that have it. The documents themselves '
                                  'are kept.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );
                  if (sure == true && context.mounted) {
                    Navigator.of(context).pop(TagColourSheet.delete);
                  }
                },
              ),
              const Spacer(),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(_colour),
                child: const Text('Done'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// The home screen's row of tags: tap one to see only its documents,
/// long-press to change its colour or delete it.
class TagFilterRow extends StatelessWidget {
  const TagFilterRow({
    super.key,
    required this.tags,
    required this.selected,
    required this.onSelected,
    required this.onEdit,
  });

  final List<Tag> tags;
  final String? selected;
  final ValueChanged<String?> onSelected;
  final ValueChanged<Tag> onEdit;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ChoiceChip(
            label: const Text('All'),
            selected: selected == null,
            onSelected: (_) => onSelected(null),
          ),
        ),
        for (final t in tags)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            // The tip shows on hover only, so a long-press reaches the
            // GestureDetector and opens the tag's colour and delete.
            child: GestureDetector(
              onLongPress: () => onEdit(t),
              child: Tooltip(
                triggerMode: TooltipTriggerMode.manual,
                message: 'Show only "${t.name}" (long-press to change it)',
                child: ChoiceChip(
                  avatar: _Dot(t.colourArgb),
                  label: Text(t.name),
                  selected: selected == t.name,
                  onSelected: (on) => onSelected(on ? t.name : null),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

/// A document's tags on its card: coloured dots with the first names.
class TagDots extends StatelessWidget {
  const TagDots({super.key, required this.tags});

  final List<Tag> tags;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        for (final t in tags.take(4))
          Padding(
            padding: const EdgeInsets.only(right: 3),
            child: _Dot(t.colourArgb, size: 10),
          ),
        const SizedBox(width: 3),
        Expanded(
          child: Text(
            tags.map((t) => t.name).join(', '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    ),
  );
}

class _Dot extends StatelessWidget {
  const _Dot(this.argb, {this.size = 14});

  final int argb;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: Color(argb), shape: BoxShape.circle),
  );
}
