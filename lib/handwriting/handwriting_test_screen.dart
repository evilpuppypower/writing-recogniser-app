import 'package:flutter/material.dart';

import '../core/event_log.dart';
import '../core/prompts.dart';
import '../core/recognition/recognizer.dart';
import '../core/sample_store.dart';
import '../recognition/engines.dart';
import '../storage/app_database.dart';
import '../storage/sqlite_event_log.dart';
import '../storage/sqlite_sample_store.dart';
import 'gate_a_report_screen.dart';
import 'live_recognition_screen.dart';
import 'sample_recorder_screen.dart';
import 'saved_samples_screen.dart';

/// Entry point for the task 0.3 handwriting test.
class HandwritingTestScreen extends StatefulWidget {
  const HandwritingTestScreen({super.key, this.openStores, this.engines});

  /// Opens the sample store and event log; overridable for tests.
  final Future<({SampleStore samples, EventLog events})> Function()? openStores;

  /// Recognition engines; defaults to [buildEngines].
  final List<Recognizer>? engines;

  @override
  State<HandwritingTestScreen> createState() => _HandwritingTestScreenState();
}

class _HandwritingTestScreenState extends State<HandwritingTestScreen> {
  late final Future<({SampleStore samples, EventLog events})> _stores =
      widget.openStores?.call() ??
      AppDatabase.open().then(
        (db) => (samples: SqliteSampleStore(db), events: SqliteEventLog(db)),
      );
  late final List<Recognizer> _engines = widget.engines ?? buildEngines();
  int? _count;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final n = await (await _stores).samples.count();
    if (mounted) setState(() => _count = n);
  }

  Future<void> _open(
    Widget Function(({SampleStore samples, EventLog events}) s) screen,
  ) async {
    final stores = await _stores;
    if (!mounted) return;
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => screen(stores)));
    await _refresh();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Handwriting test')),
    body: ListView(
      children: [
        ListTile(
          leading: const Icon(Icons.draw_outlined),
          title: const Text('Record labelled samples'),
          subtitle: Text(
            _count == null
                ? 'Loading…'
                : '$_count saved · goal $sampleGoal. Copy sentences or '
                      'write freely.',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _open((s) => SampleRecorderScreen(store: s.samples)),
        ),
        ListTile(
          leading: const Icon(Icons.list_alt),
          title: const Text('Saved samples'),
          subtitle: const Text('Review or delete samples'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _open((s) => SavedSamplesScreen(store: s.samples)),
        ),
        ListTile(
          leading: const Icon(Icons.text_fields),
          title: const Text('Live recognition'),
          subtitle: Text(
            'Write and see the text appear. Engines: '
            '${_engines.map((e) => e.name).join(', ')}',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _open(
            (s) => LiveRecognitionScreen(engines: _engines, eventLog: s.events),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.assessment_outlined),
          title: const Text('GATE A report'),
          subtitle: const Text(
            'Run your samples through each engine and compare accuracy and '
            'speed',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _open(
            (s) => GateAReportScreen(
              samples: s.samples,
              eventLog: s.events,
              engines: _engines,
            ),
          ),
        ),
      ],
    ),
  );
}
