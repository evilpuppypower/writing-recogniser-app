import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/material.dart';

import '../core/event_log.dart';
import '../core/feedback/correction.dart';
import '../core/labeled_sample.dart';
import '../core/latency.dart' show formatMs;
import '../core/learning_stats.dart';
import '../core/training_data.dart';
import '../platform/file_transfer.dart';
import '../storage/app_database.dart';
import '../storage/sqlite_correction_store.dart';
import '../storage/sqlite_event_log.dart';
import '../storage/sqlite_ink_store.dart';
import '../storage/sqlite_sample_store.dart';

/// "How well is it learning?" (task 3.1): whether corrections make
/// recognition better, from real use on PDFs. Everything is worked out on
/// the tablet from its own log.
class LearningScreen extends StatefulWidget {
  const LearningScreen({
    super.key,
    this.openEventLog = _open,
    this.saveFile = saveFileAs,
    this.loadTrainingData = _loadTrainingData,
  });

  final Future<EventLog> Function() openEventLog;

  /// The corrections, samples and words read on PDF pages for "Save
  /// training data" (tasks 4.1, 4.1b).
  final Future<
    (List<CorrectionRecord>, List<LabeledSample>, List<SavedPageText>)
  >
  Function()
  loadTrainingData;

  static Future<
    (List<CorrectionRecord>, List<LabeledSample>, List<SavedPageText>)
  >
  _loadTrainingData() async {
    final db = await AppDatabase.open();
    return (
      await SqliteCorrectionStore(db).all(),
      await SqliteSampleStore(db).all(),
      await SqliteInkStore(db).allText(),
    );
  }

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

  /// Saves corrections and samples, with their ink, as one file on the
  /// tablet (task 4.1: groundwork for a personal model, if GATE B says so).
  Future<void> _saveTrainingData() async {
    final messenger = ScaffoldMessenger.of(context);
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save training data'),
        content: const Text(
          'Saves your corrections, handwriting samples and the words read on '
          'your PDFs, with their ink, as one file wherever you choose. It '
          'can teach a model your handwriting on your computer.\n\n'
          'Handwriting identifies a person, so keep the file private. Nothing '
          'else about you is in it: times are UTC and PDFs are numbered, '
          'not named. The app never sends it anywhere.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    // Gathering and packing can take a while with lots of ink.
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 20),
              Expanded(child: Text('Gathering your corrections and samples…')),
            ],
          ),
        ),
      ),
    );
    var dialogOpen = true;
    void closeDialog() {
      if (dialogOpen && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      dialogOpen = false;
    }

    try {
      final (corrections, samples, pageTexts) = await widget.loadTrainingData();
      if (corrections.isEmpty && samples.isEmpty && pageTexts.isEmpty) {
        closeDialog();
        messenger.showSnackBar(
          const SnackBar(
            content: Text('There are no corrections or samples to save yet.'),
          ),
        );
        return;
      }
      final now = DateTime.now();
      final name = trainingDataFileName(now);
      final bytes = await _pack(corrections, samples, pageTexts, now);
      closeDialog();
      final saved = await widget.saveFile(name, 'application/zip', bytes);
      if (saved) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Saved $name (${corrections.length} corrections, '
              '${samples.length} samples).',
            ),
          ),
        );
      }
    } catch (e) {
      closeDialog();
      messenger.showSnackBar(SnackBar(content: Text("Couldn't save: $e")));
    }
  }

  /// Packs the file on a background isolate, so the screen never freezes.
  /// (Static, so the work sent to the isolate carries only the data.)
  static Future<List<int>> _pack(
    List<CorrectionRecord> corrections,
    List<LabeledSample> samples,
    List<SavedPageText> pageTexts,
    DateTime now,
  ) => Isolate.run(
    () => encodeTrainingData(
      corrections: corrections,
      samples: samples,
      pageTexts: pageTexts,
      exportedAt: now,
    ),
  );

  static String _pct(double? v) =>
      v == null ? '–' : '${(v * 100).toStringAsFixed(v < 0.1 ? 1 : 0)}%';

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('How well is it learning?'),
      actions: [
        IconButton(
          tooltip: 'Save training data (corrections and samples, with ink)',
          icon: const Icon(Icons.inventory_2_outlined),
          onPressed: _saveTrainingData,
        ),
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
