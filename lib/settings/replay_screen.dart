import 'package:flutter/material.dart';

import '../core/feedback/feedback_layer.dart';
import '../core/labeled_sample.dart';
import '../core/recognition/recognizer.dart';
import '../core/replay.dart';
import '../core/replay_cases.dart';
import '../core/transfer_estimate.dart';
import '../recognition/engines.dart';
import '../storage/app_database.dart';
import '../storage/sqlite_sample_store.dart';

/// The replay test (task 3.1): re-reads the practice sentences saved in the
/// handwriting test, word by word, through the main engine twice over:
/// once on its own, and once learning from each mistake as if it had been
/// corrected. Shows whether learning from corrections helps, without
/// waiting weeks for real use. Everything stays on the tablet.
class ReplayScreen extends StatefulWidget {
  const ReplayScreen({super.key, this.loadSamples = _loadSamples, this.engine});

  /// The saved practice sentences (injectable for tests).
  final Future<List<LabeledSample>> Function() loadSamples;

  /// Defaults to the app's main engine, the one used on PDFs.
  final Recognizer? engine;

  static Future<List<LabeledSample>> _loadSamples() async =>
      SqliteSampleStore(await AppDatabase.open()).all();

  @override
  State<ReplayScreen> createState() => _ReplayScreenState();
}

class _ReplayScreenState extends State<ReplayScreen> {
  late final Recognizer _engine = widget.engine ?? buildEngines().first;
  SampleWords? _words;
  RecognizerStatus? _status;
  String? _loadError;

  bool _running = false;
  bool _cancel = false;
  int _done = 0;
  TransferEstimator? _estimate;
  final _watch = Stopwatch();
  ReplayReport? _report;
  String? _runError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    // Leaving the screen stops a replay that's still running.
    _cancel = true;
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final words = wordsFromSamples(await widget.loadSamples());
      RecognizerStatus status;
      try {
        status = await _engine.status();
      } catch (e) {
        status = RecognizerStatus(RecognizerState.unavailable, '$e');
      }
      if (!mounted) return;
      setState(() {
        _words = words;
        _status = status;
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = '$e');
    }
  }

  Future<void> _run() async {
    final cases = _words!.cases;
    setState(() {
      _running = true;
      _cancel = false;
      _done = 0;
      _report = null;
      _runError = null;
      _estimate = TransferEstimator(totalBytes: cases.length);
    });
    _watch
      ..reset()
      ..start();
    try {
      // A fresh memory: it learns only from this replay, never from (or
      // into) the corrections made on PDFs.
      final report = await replay(
        cases,
        _engine,
        CorrectionMemory(),
        cancelled: () => _cancel,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _done = done;
            _estimate!.update(bytesDone: done, elapsed: _watch.elapsed);
          });
        },
      );
      if (mounted) setState(() => _report = report);
    } catch (e) {
      if (mounted) setState(() => _runError = '$e');
    } finally {
      _watch.stop();
      if (mounted) setState(() => _running = false);
    }
  }

  static String _count(int n, String thing) => '$n $thing${n == 1 ? '' : 's'}';

  static String _pct(double? v) =>
      v == null ? '–' : '${(v * 100).toStringAsFixed(v < 0.1 ? 1 : 0)}%';

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Replay test')),
    body: _body(context),
  );

  Widget _body(BuildContext context) {
    if (_loadError != null) {
      return Center(child: Text("Couldn't read the samples: $_loadError"));
    }
    final words = _words, status = _status;
    if (words == null || status == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Re-reads the practice sentences you saved in the handwriting '
          'test, one word at a time, twice over: by the engine on its own, '
          'and while learning from each mistake as if you had corrected it. '
          'It shows whether learning from corrections helps, without '
          'waiting for weeks of real use. Your corrections on PDFs are not '
          'used or changed.',
        ),
        const SizedBox(height: 12),
        Text(
          '${_count(words.samplesUsed, 'sentence')}, '
          '${_count(words.cases.length, 'word')}'
          '${words.samplesSkipped == 0 ? '' : ' (${_count(words.samplesSkipped, 'sentence')} '
                    "left out: the ink didn't split into the right number "
                    'of words)'}.',
        ),
        const SizedBox(height: 16),
        if (!status.isReady)
          Text(
            "The reading engine (${_engine.name}) isn't ready: "
            '${status.message}',
            style: TextStyle(color: theme.colorScheme.error),
          )
        else if (words.cases.isEmpty)
          const Text(
            'No words to replay yet. Save some practice sentences first: '
            'Handwriting test (on the home screen) → Record labelled samples.',
          )
        else if (_running)
          _progress(context)
        else
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              icon: const Icon(Icons.replay),
              label: Text(_report == null ? 'Start replay' : 'Replay again'),
              onPressed: _run,
            ),
          ),
        if (_runError != null) ...[
          const SizedBox(height: 12),
          Text(
            'The replay stopped: $_runError',
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ],
        if (_report != null) ..._results(context, _report!, words),
      ],
    );
  }

  Widget _progress(BuildContext context) {
    final total = _words!.cases.length;
    final remaining = _estimate?.remaining;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(value: total == 0 ? null : _done / total),
        const SizedBox(height: 8),
        Text(
          'Word $_done of $total, '
          '${remaining == null ? 'estimating time left…' : formatRemaining(remaining)}',
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: _cancel ? null : () => setState(() => _cancel = true),
          child: Text(_cancel ? 'Stopping…' : 'Cancel'),
        ),
      ],
    );
  }

  List<Widget> _results(
    BuildContext context,
    ReplayReport r,
    SampleWords words,
  ) {
    final theme = Theme.of(context);
    final repeated = r.steps.where((s) => s.seenBefore).length;
    final improvement = r.repeatedImprovement;
    Widget row(String label, String value, {String? note}) => ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      subtitle: note == null ? null : Text(note),
      trailing: Text(value, style: theme.textTheme.titleMedium),
    );
    final perWindow = r.correctionsPer100(window: 25);
    return [
      const Divider(height: 32),
      Text(
        '${r.steps.length} words replayed'
        '${r.steps.length < words.cases.length ? ' (stopped early)' : ''}',
        style: theme.textTheme.titleMedium,
      ),
      const Text('Words that needed fixing. Lower is better.'),
      row(
        'Engine on its own',
        _pct(r.wer(feedback: false)),
        note: 'Letters wrong: ${_pct(r.cer(feedback: false))}',
      ),
      row(
        'Learning from corrections',
        _pct(r.wer(feedback: true)),
        note: 'Letters wrong: ${_pct(r.cer(feedback: true))}',
      ),
      const Divider(),
      row(
        'Words written before',
        _pct(repeated == 0 ? null : r.wer(feedback: true, repeated: true)),
        note:
            '$repeated words; the engine alone: '
            '${_pct(repeated == 0 ? null : r.wer(feedback: false, repeated: true))}',
      ),
      row(
        'New words',
        _pct(r.wer(feedback: true, repeated: false)),
        note: '${r.steps.length - repeated} words',
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Fewer fixes on words written before'),
        subtitle: const Text(
          'Compared with the engine alone. GATE B target: at least a third '
          'fewer.',
        ),
        trailing: Text(
          _pct(improvement),
          style: theme.textTheme.titleLarge?.copyWith(
            color: improvement == null
                ? null
                : improvement >= 1 / 3
                ? theme.colorScheme.primary
                : theme.colorScheme.error,
          ),
        ),
      ),
      row('Automatic swaps', '${r.steps.where((s) => s.autoReplaced).length}'),
      const Divider(),
      const Text('Corrections per 100 words, every 25 words in order'),
      const Text('Should go down as it learns.'),
      for (var i = 0; i < perWindow.length; i++)
        row(
          'Words ${i * 25 + 1}–${(i * 25 + 25).clamp(0, r.steps.length)}',
          perWindow[i].toStringAsFixed(0),
        ),
    ];
  }
}
