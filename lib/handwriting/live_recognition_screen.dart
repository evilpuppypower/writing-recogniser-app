import 'dart:async';

import 'package:flutter/material.dart';

import '../core/event_log.dart';
import '../core/latency.dart';
import '../core/recognition/recognizer.dart';
import '../settings/settings_controller.dart';
import 'handed_writing_box.dart';
import 'ink_canvas.dart';
import 'ink_controller.dart';

/// Write with the pen; after a short pause the ink is recognised and the
/// top guesses are shown with how long they took.
class LiveRecognitionScreen extends StatefulWidget {
  const LiveRecognitionScreen({
    super.key,
    required this.engines,
    required this.eventLog,
  });

  final List<Recognizer> engines;
  final EventLog eventLog;

  @override
  State<LiveRecognitionScreen> createState() => _LiveRecognitionScreenState();
}

class _Result {
  const _Result({
    required this.engine,
    this.candidates = const [],
    this.timing,
    this.error,
  });

  final String engine;
  final List<Candidate> candidates;

  /// Where the time from pen lift to text on screen went. Null until the
  /// text has been drawn (or when recognition failed).
  final LatencyBreakdown? timing;
  final String? error;

  _Result withTiming(LatencyBreakdown t) =>
      _Result(engine: engine, candidates: candidates, timing: t);
}

class _LiveRecognitionScreenState extends State<LiveRecognitionScreen> {
  final _ink = InkController();
  int _engineIndex = 0;
  RecognizerStatus? _status;
  bool _preparing = false;
  final _prepareWatch = Stopwatch();

  /// Timings this session, per engine, for the running medians.
  final _history = <String, List<LatencyBreakdown>>{};
  Timer? _pauseTimer;
  Timer? _ticker;
  int _sequence = 0;
  bool _recognizing = false;
  _Result? _result;
  Size _canvasSize = Size.zero;

  Recognizer get _engine => widget.engines[_engineIndex];

  @override
  void initState() {
    super.initState();
    _ink.addListener(_rebuild);
    _checkStatus();
  }

  void _rebuild() => setState(() {});

  @override
  void dispose() {
    _pauseTimer?.cancel();
    _ticker?.cancel();
    _ink.removeListener(_rebuild);
    _ink.dispose();
    super.dispose();
  }

  Future<void> _checkStatus() async {
    setState(() => _status = null);
    final engine = _engine;
    RecognizerStatus status;
    try {
      status = await engine.status();
    } catch (e) {
      status = RecognizerStatus(RecognizerState.unavailable, '$e');
    }
    if (mounted && engine == _engine) setState(() => _status = status);
  }

  Future<void> _prepare() async {
    setState(() => _preparing = true);
    _prepareWatch
      ..reset()
      ..start();
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => setState(() {}),
    );
    String? error;
    try {
      await _engine.prepare();
    } catch (e) {
      error = '$e';
    } finally {
      _ticker?.cancel();
      _prepareWatch.stop();
    }
    if (!mounted) return;
    setState(() => _preparing = false);
    if (error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }
    await _checkStatus();
  }

  void _onPenDown() => _pauseTimer?.cancel();

  void _onInkChanged() {
    _pauseTimer?.cancel();
    if (_ink.strokes.isEmpty) return;
    final pause = SettingsScope.of(context).value.recognitionPauseMs;
    _pauseTimer = Timer(Duration(milliseconds: pause), _recognize);
  }

  Future<void> _recognize() async {
    if (!(_status?.isReady ?? false) || _ink.strokes.isEmpty) return;
    final strokes = _ink.strokes;
    final penLift = strokes.last.endTime;
    final engine = _engine;
    final pauseMs = SettingsScope.of(context).value.recognitionPauseMs;
    final seq = ++_sequence;
    setState(() => _recognizing = true);
    final sent = DateTime.now().millisecondsSinceEpoch;
    _Result result;
    try {
      final candidates = await engine.recognize(
        strokes,
        RecognitionContext(
          writingAreaWidth: _canvasSize.width,
          writingAreaHeight: _canvasSize.height,
        ),
      );
      result = _Result(engine: engine.name, candidates: candidates);
    } catch (e) {
      result = _Result(engine: engine.name, error: '$e');
    }
    final answered = DateTime.now().millisecondsSinceEpoch;
    // Ignore answers to older requests that finish after a newer one.
    if (!mounted || seq != _sequence) return;
    setState(() {
      _recognizing = false;
      _result = result;
    });
    if (result.error != null) return;
    // Wait for the frame that draws the text, so "shown" means on screen.
    await WidgetsBinding.instance.endOfFrame;
    final timing = LatencyBreakdown.fromTimes(
      penLift: penLift,
      sent: sent,
      answered: answered,
      shown: DateTime.now().millisecondsSinceEpoch,
    );
    if (!mounted || seq != _sequence) return;
    setState(() {
      _result = result.withTiming(timing);
      _history.putIfAbsent(engine.name, () => []).add(timing);
    });
    final candidates = result.candidates;
    unawaited(
      widget.eventLog
          .log(
            LoggedEvent(
              type: 'recognition',
              at: DateTime.now(),
              engine: engine.name,
              latencyMs: timing.totalMs,
              data: {
                'top': candidates.isEmpty ? null : candidates.first.text,
                'candidates': candidates.length,
                'strokes': strokes.length,
                'pauseMs': pauseMs,
                ...timing.toJson(),
              },
            ),
          )
          .catchError((_) {}),
    );
  }

  void _clear() {
    _pauseTimer?.cancel();
    _sequence++;
    _ink.clear();
    setState(() {
      _result = null;
      _recognizing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live recognition'),
        actions: [
          IconButton(
            tooltip: 'Undo last stroke',
            icon: const Icon(Icons.undo),
            onPressed: _ink.strokes.isEmpty
                ? null
                : () {
                    _ink.undo();
                    _onInkChanged();
                  },
          ),
          IconButton(
            tooltip: 'Clear the writing area',
            icon: const Icon(Icons.clear_all),
            onPressed: _ink.isEmpty ? null : _clear,
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
                if (widget.engines.length > 1)
                  SegmentedButton<int>(
                    segments: [
                      for (var i = 0; i < widget.engines.length; i++)
                        ButtonSegment(
                          value: i,
                          label: Text(widget.engines[i].name),
                          icon: Icon(
                            widget.engines[i].onDevice
                                ? Icons.tablet_android
                                : Icons.cloud_outlined,
                          ),
                          tooltip: widget.engines[i].onDevice
                              ? 'Runs on this tablet'
                              : 'Sends pen strokes to a server',
                        ),
                    ],
                    selected: {_engineIndex},
                    onSelectionChanged: (v) {
                      setState(() {
                        _engineIndex = v.single;
                        _result = null;
                      });
                      _checkStatus();
                    },
                  ),
                const SizedBox(height: 12),
                _statusOrResult(theme),
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
                        onPenDown: _onPenDown,
                        onStrokeEnd: (_) => _onInkChanged(),
                        onErase: _onInkChanged,
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusOrResult(ThemeData theme) {
    final status = _status;
    if (status == null) {
      return const Card(
        child: ListTile(
          leading: SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          title: Text('Checking the engine…'),
        ),
      );
    }
    if (_preparing) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Downloading the ${_engine.name} model (about 20 MB)…'),
              const SizedBox(height: 8),
              const LinearProgressIndicator(),
              const SizedBox(height: 4),
              Text(
                '${_prepareWatch.elapsed.inSeconds} s so far. '
                "${_engine.name} doesn't report progress, so there's no time "
                'estimate.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );
    }
    if (!status.isReady) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(status.message),
              if (status.state == RecognizerState.needsDownload) ...[
                const SizedBox(height: 12),
                FilledButton.icon(
                  icon: const Icon(Icons.download),
                  label: const Text('Download model (about 20 MB)'),
                  onPressed: _prepare,
                ),
              ],
            ],
          ),
        ),
      );
    }
    final result = _result;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: _recognizing && result == null
            ? const Text('Recognising…')
            : result == null
            ? Text(
                'Write with the pen below. About '
                '${(SettingsScope.of(context).value.recognitionPauseMs / 1000).toStringAsFixed(1)} s '
                'after you lift the pen, the text appears here.',
              )
            : result.error != null
            ? Text(
                result.error!,
                style: TextStyle(color: theme.colorScheme.error),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    result.candidates.isEmpty
                        ? '(no text recognised)'
                        : result.candidates.first.text,
                    style: theme.textTheme.headlineSmall,
                  ),
                  if (result.candidates.length > 1) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Other guesses: '
                      '${result.candidates.skip(1).take(4).map((c) => c.text).join('  ·  ')}',
                    ),
                  ],
                  const SizedBox(height: 8),
                  _TimingText(
                    engine: result.engine,
                    timing: result.timing,
                    history: _history[result.engine] ?? const [],
                    updating: _recognizing,
                  ),
                ],
              ),
      ),
    );
  }
}

/// Pen-lift-to-text time, split into its steps, plus this session's medians.
class _TimingText extends StatelessWidget {
  const _TimingText({
    required this.engine,
    required this.timing,
    required this.history,
    required this.updating,
  });

  final String engine;
  final LatencyBreakdown? timing;
  final List<LatencyBreakdown> history;
  final bool updating;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    final t = timing;
    if (t == null) return Text('$engine · timing…', style: style);
    String med(int Function(LatencyBreakdown) f) =>
        formatMs(medianMs(history.map(f)) ?? 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$engine · ${formatMs(t.totalMs)} from lifting the pen to this text'
          '${updating ? ' · updating…' : ''}',
          style: style,
        ),
        Text(
          'Waiting for the pause ${formatMs(t.waitMs)} · '
          'engine ${formatMs(t.engineMs)} · '
          'drawing ${formatMs(t.displayMs)}',
          style: style,
        ),
        if (history.length > 1)
          Text(
            'Median of ${history.length} tries with $engine: '
            'total ${med((h) => h.totalMs)}, engine ${med((h) => h.engineMs)}',
            style: style,
          ),
      ],
    );
  }
}
