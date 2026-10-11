import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/evaluation.dart';
import '../core/event_log.dart';
import '../core/labeled_sample.dart';
import '../core/recognition/recognizer.dart';
import '../core/sample_store.dart';
import '../core/stored_copy.dart' show formatDateTime;
import '../core/text_metrics.dart';
import '../core/transfer_estimate.dart';
import '../core/writing_stats.dart';
import '../library/home_screen.dart' show buildStamp;

/// GATE A: runs the saved samples through each engine and reports accuracy
/// and speed, plus live pen-lift-to-text times from the event log.
class GateAReportScreen extends StatefulWidget {
  const GateAReportScreen({
    super.key,
    required this.samples,
    required this.eventLog,
    required this.engines,
  });

  final SampleStore samples;
  final EventLog eventLog;
  final List<Recognizer> engines;

  @override
  State<GateAReportScreen> createState() => _GateAReportScreenState();
}

class _LiveStats {
  const _LiveStats(this.count, this.median, this.p90);
  final int count;
  final int? median, p90;
}

class _GateAReportScreenState extends State<GateAReportScreen> {
  List<LabeledSample>? _samples;
  final Map<String, RecognizerStatus> _status = {};
  final Map<String, EvaluationSummary> _results = {};
  Map<String, _LiveStats> _live = {};
  String? _running;
  int _done = 0;
  bool _cancel = false;
  TransferEstimator? _estimate;
  final _watch = Stopwatch();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final samples = await widget.samples.all();
    final events = await widget.eventLog.ofType('recognition');
    final live = <String, _LiveStats>{};
    for (final e in widget.engines) {
      final ms = [
        for (final ev in events)
          if (ev.engine == e.name && ev.latencyMs != null) ev.latencyMs!,
      ];
      live[e.name] = _LiveStats(
        ms.length,
        percentile(ms, 50),
        percentile(ms, 90),
      );
    }
    for (final e in widget.engines) {
      try {
        _status[e.name] = await e.status();
      } catch (err) {
        _status[e.name] = RecognizerStatus(RecognizerState.unavailable, '$err');
      }
    }
    if (!mounted) return;
    setState(() {
      _samples = samples;
      _live = live;
    });
  }

  Future<void> _run(Recognizer engine) async {
    final samples = _samples!;
    setState(() {
      _running = engine.name;
      _done = 0;
      _cancel = false;
      _estimate = TransferEstimator(totalBytes: samples.length);
    });
    _watch
      ..reset()
      ..start();
    final summary = await evaluate(
      samples,
      engine,
      cancelled: () => _cancel,
      onProgress: (done, total) {
        if (!mounted) return;
        setState(() {
          _done = done;
          _estimate!.update(bytesDone: done, elapsed: _watch.elapsed);
        });
      },
    );
    _watch.stop();
    await widget.eventLog
        .log(
          LoggedEvent(
            type: 'evaluation',
            at: DateTime.now(),
            engine: engine.name,
            latencyMs: summary.medianMs,
            data: {
              'samples': summary.results.length,
              'failures': summary.failures,
              'cerStrict': summary.cer(Matching.strict),
              'cerLenient': summary.cer(Matching.lenient),
              'werLenient': summary.wer(Matching.lenient),
              'exactLenient': summary.exactRate(Matching.lenient),
              'p90Ms': summary.p90Ms,
            },
          ),
        )
        .catchError((_) {});
    if (!mounted) return;
    setState(() {
      _running = null;
      _results[engine.name] = summary;
    });
  }

  static String _pct(double v) => '${(v * 100).toStringAsFixed(1)}%';
  static String _ms(int? v) =>
      v == null ? '–' : '${(v / 1000).toStringAsFixed(2)} s';

  String _report() {
    final b = StringBuffer()
      ..writeln('# GATE A report')
      ..writeln()
      ..writeln(
        '${formatDateTime(DateTime.now())} · build $buildStamp · '
        '${_samples?.length ?? 0} samples',
      )
      ..writeln();
    for (final e in widget.engines) {
      final r = _results[e.name];
      final live = _live[e.name];
      b.writeln('## ${e.name} (${e.onDevice ? 'on device' : 'cloud'})');
      if (r == null) {
        b.writeln('- Not run');
      } else {
        b
          ..writeln(
            '- Character errors: ${_pct(r.cer(Matching.lenient))} lenient, '
            '${_pct(r.cer(Matching.strict))} strict',
          )
          ..writeln('- Word errors (lenient): ${_pct(r.wer(Matching.lenient))}')
          ..writeln(
            '- Perfect samples (lenient): ${_pct(r.exactRate(Matching.lenient))}',
          )
          ..writeln(
            '- Engine time: median ${_ms(r.medianMs)}, 90% within ${_ms(r.p90Ms)}',
          )
          ..writeln('- Failures: ${r.failures} of ${r.results.length}');
        final worst = r.worst(Matching.lenient, count: 3);
        if (worst.isNotEmpty) {
          b.writeln('- Worst:');
          for (final w in worst) {
            b.writeln('  - "${w.sample.text}" → "${w.recognised}"');
          }
        }
      }
      if (live != null && live.count > 0) {
        b.writeln(
          '- Live pen-lift-to-text: median ${_ms(live.median)}, '
          '90% within ${_ms(live.p90)} (${live.count} recognitions)',
        );
      }
      b.writeln();
    }
    _writePositionCheck(b);
    _writePerSample(b);
    return b.toString();
  }

  /// Ink reaching this far across the box counts as "near the right edge".
  static const _rightEdge = 0.8;

  /// Do samples written close to the right edge have more errors? (For a
  /// right-handed writer, writing got less legible as the hand moved right.)
  void _writePositionCheck(StringBuffer b) {
    final samples = _samples ?? const <LabeledSample>[];
    if (_results.isEmpty || samples.isEmpty) return;
    final nearRight = {
      for (final s in samples)
        if ((WritingStats.of(s).rightPct ?? 0) >= _rightEdge) s,
    };
    b
      ..writeln('## Writing position')
      ..writeln(
        'Samples whose ink reaches past ${(_rightEdge * 100).round()}% of the '
        'box width (${nearRight.length}) vs the rest '
        '(${samples.length - nearRight.length}), character errors (lenient):',
      );
    for (final e in widget.engines) {
      final r = _results[e.name];
      if (r == null) continue;
      final near = r.results.where((x) => nearRight.contains(x.sample));
      final rest = r.results.where((x) => !nearRight.contains(x.sample));
      b.writeln(
        '- ${e.name}: ${_pct(cerOf(near, Matching.lenient))} near the right '
        'edge vs ${_pct(cerOf(rest, Matching.lenient))} elsewhere',
      );
    }
    b.writeln();
  }

  void _writePerSample(StringBuffer b) {
    final samples = _samples ?? const <LabeledSample>[];
    if (_results.isEmpty || samples.isEmpty) return;
    b.writeln('## Per sample');
    for (var i = 0; i < samples.length; i++) {
      final s = samples[i];
      b
        ..writeln()
        ..writeln('${i + 1}. "${s.text}"')
        ..writeln('   - Writing: ${WritingStats.of(s).describe()}');
      for (final e in widget.engines) {
        final r = _results[e.name]?.resultFor(s);
        if (r == null) continue;
        if (r.error != null) {
          b.writeln('   - ${e.name}: failed (${r.error})');
          continue;
        }
        final err = r.errors(Matching.lenient);
        final verdict = err.exact
            ? 'perfect'
            : '${err.charEdits} character error${err.charEdits == 1 ? '' : 's'} '
                  '(${_pct(err.cer)})';
        b.writeln(
          '   - ${e.name}: "${r.recognised}" · $verdict · ${_ms(r.ms)}',
        );
      }
    }
    b.writeln();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _report()));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Report copied. Paste it into the Claude chat.'),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final samples = _samples;
    return Scaffold(
      appBar: AppBar(
        title: const Text('GATE A report'),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.copy),
            label: const Text('Copy report'),
            onPressed: samples == null || _running != null ? null : _copy,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: samples == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  '${samples.length} labelled samples saved. Run each engine '
                  "on them to compare how accurately and how fast they read "
                  'your handwriting.',
                ),
                if (samples.length < 25)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Tip: record at least 25 samples for a fair comparison.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                for (final e in widget.engines) _engineCard(e, samples),
              ],
            ),
    );
  }

  Widget _engineCard(Recognizer engine, List<LabeledSample> samples) {
    final theme = Theme.of(context);
    final status = _status[engine.name];
    final result = _results[engine.name];
    final live = _live[engine.name];
    final running = _running == engine.name;
    final remaining = _estimate?.remaining;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  engine.onDevice ? Icons.tablet_android : Icons.cloud_outlined,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(engine.name, style: theme.textTheme.titleMedium),
                ),
                if (running)
                  TextButton(
                    onPressed: () => setState(() => _cancel = true),
                    child: const Text('Stop'),
                  )
                else
                  FilledButton(
                    onPressed:
                        (status?.isReady ?? false) &&
                            _running == null &&
                            samples.isNotEmpty
                        ? () => _run(engine)
                        : null,
                    child: Text(
                      result == null
                          ? 'Run on ${samples.length} samples'
                          : 'Run again',
                    ),
                  ),
              ],
            ),
            if (status != null && !status.isReady)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Not ready: ${status.message} (Set it up in Live '
                  'recognition or Settings first.)',
                ),
              ),
            if (!engine.onDevice)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Uses about ${samples.length} requests from your MyScript '
                  'monthly quota per run.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            if (running) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: samples.isEmpty ? null : _done / samples.length,
              ),
              const SizedBox(height: 4),
              Text(
                '$_done of ${samples.length} · '
                '${remaining == null ? 'estimating time left…' : formatRemaining(remaining)}',
              ),
            ],
            if (result != null) ...[
              const SizedBox(height: 12),
              _row(
                'Character errors (lenient)',
                _pct(result.cer(Matching.lenient)),
              ),
              _row(
                'Character errors (strict)',
                _pct(result.cer(Matching.strict)),
              ),
              _row('Word errors (lenient)', _pct(result.wer(Matching.lenient))),
              _row(
                'Perfect samples (lenient)',
                _pct(result.exactRate(Matching.lenient)),
              ),
              _row(
                'Engine time',
                'median ${_ms(result.medianMs)} · 90% within ${_ms(result.p90Ms)}',
              ),
              _row(
                'Failures',
                '${result.failures} of ${result.results.length}',
              ),
              const SizedBox(height: 8),
              Text(
                'Lenient ignores capital letters and punctuation; strict '
                'counts everything.',
                style: theme.textTheme.bodySmall,
              ),
              for (final w in result.worst(Matching.lenient, count: 3))
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Wrote "${w.sample.text}"\nRead  "${w.recognised}"',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
            ],
            if (live != null && live.count > 0) ...[
              const SizedBox(height: 8),
              _row(
                'Live pen-lift to text',
                'median ${_ms(live.median)} · 90% within ${_ms(live.p90)} '
                    '(${live.count} times)',
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
      ],
    ),
  );
}
