import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/event_log.dart';
import '../core/latency.dart' show formatMs;
import '../core/learning_stats.dart';
import '../platform/file_transfer.dart';
import '../storage/app_database.dart';
import '../storage/sqlite_event_log.dart';

/// "How well is it learning?" (task 3.1): whether corrections make
/// recognition better, from real use on PDFs. Everything is worked out on
/// the tablet from its own log.
class LearningScreen extends StatefulWidget {
  const LearningScreen({
    super.key,
    this.openEventLog = _open,
    this.saveFile = saveFileAs,
  });

  final Future<EventLog> Function() openEventLog;

  /// Asks where to save the spreadsheet (injectable for tests).
  final Future<bool> Function(String name, String mime, List<int> bytes)
  saveFile;

  static Future<EventLog> _open() async =>
      SqliteEventLog(await AppDatabase.open());

  @override
  State<LearningScreen> createState() => _LearningScreenState();
}

class _LearningScreenState extends State<LearningScreen> {
  late final Future<LearningStats> _stats = _load();

  Future<LearningStats> _load() async {
    final log = await widget.openEventLog();
    return LearningStats.fromEvents([
      ...await log.ofType('recognition'),
      ...await log.ofType('correction'),
      ...await log.ofType('not_writing'),
    ]);
  }

  Future<void> _export() async {
    final messenger = ScaffoldMessenger.of(context);
    final stats = await _stats;
    if (stats.words.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('There are no words to save yet.')),
      );
      return;
    }
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final name =
        'Handwriting learning ${now.year}-${two(now.month)}-${two(now.day)}.csv';
    try {
      final saved = await widget.saveFile(
        name,
        'text/csv',
        utf8.encode(stats.toCsv()),
      );
      if (saved) {
        messenger.showSnackBar(SnackBar(content: Text('Saved $name')));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text("Couldn't save: $e")));
    }
  }

  static String _pct(double? v) =>
      v == null ? '–' : '${(v * 100).toStringAsFixed(v < 0.1 ? 1 : 0)}%';

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('How well is it learning?'),
      actions: [
        IconButton(
          tooltip: 'Save every word as a spreadsheet (CSV)',
          icon: const Icon(Icons.download_outlined),
          onPressed: _export,
        ),
      ],
    ),
    body: FutureBuilder<LearningStats>(
      future: _stats,
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text("Couldn't read the log: ${snap.error}"));
        }
        final s = snap.data;
        if (s == null) return const Center(child: CircularProgressIndicator());
        if (s.words.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Nothing yet. Write on a PDF and correct any wrong words: the '
              'numbers here show whether your corrections make reading '
              'better over time.',
            ),
          );
        }
        final theme = Theme.of(context);
        final engine = s.engineAlone, shown = s.withCorrections;
        final repeatedEngine = ErrorRates.of(s.repeatedWords, (w) => w.engine);
        final repeatedShown = ErrorRates.of(s.repeatedWords, (w) => w.shown);
        final newShown = ErrorRates.of(s.newWords, (w) => w.shown);
        final improvement = s.repeatedImprovement;
        final latency = s.medianLatencyMs;
        Widget row(String label, String value, {String? note}) => ListTile(
          dense: true,
          title: Text(label),
          subtitle: note == null ? null : Text(note),
          trailing: Text(value, style: theme.textTheme.titleMedium),
        );
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            ListTile(
              title: Text('${s.words.length} words read'),
              subtitle: const Text(
                'Words that needed fixing, out of all words read. Lower is '
                'better.',
              ),
            ),
            row(
              'Engine on its own',
              _pct(engine.wordRate),
              note: 'Letters wrong: ${_pct(engine.charRate)}',
            ),
            row(
              'With your corrections',
              _pct(shown.wordRate),
              note: 'Letters wrong: ${_pct(shown.charRate)}',
            ),
            const Divider(),
            row(
              "Words you've written before",
              _pct(repeatedShown.wordRate),
              note:
                  '${repeatedShown.words} words; the engine alone: '
                  '${_pct(repeatedEngine.wordRate)}',
            ),
            row(
              'New words',
              _pct(newShown.wordRate),
              note: '${newShown.words} words',
            ),
            ListTile(
              title: const Text('Fewer fixes on words written before'),
              subtitle: const Text(
                'Compared with the engine alone. Target for the next step '
                '(GATE B): at least a third fewer.',
              ),
              trailing: Text(
                improvement == null ? '–' : _pct(improvement),
                style: theme.textTheme.titleLarge?.copyWith(
                  color: improvement == null
                      ? null
                      : improvement >= 1 / 3
                      ? theme.colorScheme.primary
                      : theme.colorScheme.error,
                ),
              ),
            ),
            const Divider(),
            row(
              'Automatic swaps',
              '${s.swaps}',
              note: '${s.swapsUndone} undone',
            ),
            row(
              'Pen lift to text',
              latency == null ? '–' : formatMs(latency),
              note: 'Middle value',
            ),
            const Divider(),
            const ListTile(
              title: Text('Corrections per 100 words, by week'),
              subtitle: Text('Should go down as it learns.'),
            ),
            for (final w in s.weeks.reversed)
              row(
                'Week of ${w.monday.day}/${w.monday.month}',
                w.correctionsPer100 == null
                    ? '–'
                    : w.correctionsPer100!.toStringAsFixed(1),
                note: '${w.words} words, ${w.corrections} corrections',
              ),
          ],
        );
      },
    ),
  );
}
