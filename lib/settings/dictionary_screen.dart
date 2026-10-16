import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/feedback/personal_dictionary.dart';

/// "My words and shorthand" (owner: a personal dictionary to add to from
/// Settings, as well as from the PDF).
class DictionaryScreen extends StatefulWidget {
  const DictionaryScreen({super.key, this.load = _load, this.save = _save});

  final Future<PersonalDictionary> Function() load;
  final Future<void> Function(PersonalDictionary d) save;

  static Future<PersonalDictionary> _load() async {
    final d = PersonalDictionary();
    final raw = await SharedPreferencesAsync().getString(
      PersonalDictionary.prefsKey,
    );
    if (raw != null) d.load(jsonDecode(raw));
    return d;
  }

  static Future<void> _save(PersonalDictionary d) => SharedPreferencesAsync()
      .setString(PersonalDictionary.prefsKey, jsonEncode(d.toJson()));

  @override
  State<DictionaryScreen> createState() => _DictionaryScreenState();
}

class _DictionaryScreenState extends State<DictionaryScreen> {
  PersonalDictionary? _d;
  final _word = TextEditingController();
  final _short = TextEditingController();
  final _full = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.load().then(
      (d) {
        if (mounted) setState(() => _d = d);
      },
      onError: (_) {
        if (mounted) setState(() => _d = PersonalDictionary());
      },
    );
  }

  @override
  void dispose() {
    _word.dispose();
    _short.dispose();
    _full.dispose();
    super.dispose();
  }

  Future<void> _change(void Function(PersonalDictionary d) f) async {
    final d = _d;
    if (d == null) return;
    setState(() => f(d));
    try {
      await widget.save(d);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Couldn't save it: $e")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('My words and shorthand')),
      body: d == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('My words', style: theme.textTheme.titleMedium),
                const Text(
                  'Names, terms and spellings of your own: preferred when '
                  'your writing could be read more than one way.',
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _word,
                        decoration: const InputDecoration(hintText: 'A word'),
                        onSubmitted: (_) => _addWord(),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Add this word',
                      icon: const Icon(Icons.add),
                      onPressed: _addWord,
                    ),
                  ],
                ),
                for (final w in d.words)
                  ListTile(
                    dense: true,
                    title: Text(w),
                    trailing: IconButton(
                      tooltip: 'Remove “$w”',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _change((d) => d.removeWord(w)),
                    ),
                  ),
                const SizedBox(height: 24),
                Text('Shorthand', style: theme.textTheme.titleMedium),
                const Text(
                  'Written out in full in typed text, and found by search '
                  '(e.g. “w/” for “with”). Corrected the same way twice, '
                  'shorthand is learned and shows here.',
                ),
                Row(
                  children: [
                    SizedBox(
                      width: 90,
                      child: TextField(
                        controller: _short,
                        decoration: const InputDecoration(hintText: 'w/'),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Icon(Icons.arrow_forward, size: 18),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _full,
                        decoration: const InputDecoration(hintText: 'with'),
                        onSubmitted: (_) => _addShort(),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Add this shorthand',
                      icon: const Icon(Icons.add),
                      onPressed: _addShort,
                    ),
                  ],
                ),
                for (final e in d.shorthand.entries)
                  ListTile(
                    dense: true,
                    title: Text('${e.key}  →  ${e.value.full}'),
                    subtitle: e.value.learned
                        ? const Text('Learned from your corrections')
                        : null,
                    trailing: IconButton(
                      tooltip: 'Remove “${e.key}”',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _change((d) => d.removeShorthand(e.key)),
                    ),
                  ),
              ],
            ),
    );
  }

  void _addWord() {
    final w = _word.text.trim();
    if (w.isEmpty) return;
    _word.clear();
    _change((d) => d.addWord(w));
  }

  void _addShort() {
    final s = _short.text.trim(), f = _full.text.trim();
    if (s.isEmpty || f.isEmpty) return;
    _short.clear();
    _full.clear();
    _change((d) => d.addShorthand(s, f));
  }
}
