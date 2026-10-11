/// Runs saved labelled samples through a recognizer and summarises accuracy
/// and speed (GATE A). Pure Dart.
library;

import 'labeled_sample.dart';
import 'recognition/recognizer.dart';
import 'text_metrics.dart';

class SampleResult {
  const SampleResult({
    required this.sample,
    required this.recognised,
    required this.ms,
    this.error,
  });

  final LabeledSample sample;

  /// Top candidate ('' if none or on error).
  final String recognised;

  /// Time the engine took to answer, in ms.
  final int ms;
  final String? error;

  TextErrors errors(Matching m) => TextErrors.of(sample.text, recognised, m);
}

class EvaluationSummary {
  EvaluationSummary(this.engine, this.results);

  final String engine;
  final List<SampleResult> results;

  List<SampleResult> get _ok => results.where((r) => r.error == null).toList();

  int get failures => results.length - _ok.length;

  /// Character error rate over all successful samples, weighted by length.
  double cer(Matching m) => cerOf(_ok, m);

  /// Result for [sample], if it was run.
  SampleResult? resultFor(LabeledSample sample) {
    for (final r in results) {
      if (identical(r.sample, sample) ||
          (r.sample.id != null && r.sample.id == sample.id)) {
        return r;
      }
    }
    return null;
  }

  /// Word error rate over all successful samples, weighted by length.
  double wer(Matching m) {
    var edits = 0, words = 0;
    for (final r in _ok) {
      final e = r.errors(m);
      edits += e.wordEdits;
      words += e.refWords;
    }
    return words == 0 ? 0 : edits / words;
  }

  /// Share of samples recognised perfectly.
  double exactRate(Matching m) =>
      _ok.isEmpty ? 0 : _ok.where((r) => r.errors(m).exact).length / _ok.length;

  int? get medianMs => percentile(_ok.map((r) => r.ms).toList(), 50);
  int? get p90Ms => percentile(_ok.map((r) => r.ms).toList(), 90);

  /// Successful samples with the most character errors first.
  List<SampleResult> worst(Matching m, {int count = 5}) =>
      (_ok.toList()..sort((a, b) => b.errors(m).cer.compareTo(a.errors(m).cer)))
          .where((r) => !r.errors(m).exact)
          .take(count)
          .toList();
}

/// Character error rate over [results] (errors skipped), weighted by length.
double cerOf(Iterable<SampleResult> results, Matching m) {
  var edits = 0, chars = 0;
  for (final r in results) {
    if (r.error != null) continue;
    final e = r.errors(m);
    edits += e.charEdits;
    chars += e.refChars;
  }
  return chars == 0 ? 0 : edits / chars;
}

/// Nearest-rank percentile; null for an empty list.
int? percentile(List<int> values, int p) {
  if (values.isEmpty) return null;
  final sorted = values.toList()..sort();
  final rank = ((p / 100) * sorted.length).ceil().clamp(1, sorted.length);
  return sorted[rank - 1];
}

/// Recognises every sample with [recognizer], one at a time, reporting
/// progress after each. [clock] is injectable for tests.
Future<EvaluationSummary> evaluate(
  List<LabeledSample> samples,
  Recognizer recognizer, {
  void Function(int done, int total)? onProgress,
  bool Function()? cancelled,
  Stopwatch Function() clock = Stopwatch.new,
}) async {
  final results = <SampleResult>[];
  for (final s in samples) {
    if (cancelled?.call() ?? false) break;
    final watch = clock()..start();
    try {
      final c = await recognizer.recognize(
        s.strokes,
        RecognitionContext(
          writingAreaWidth: s.canvasWidth,
          writingAreaHeight: s.canvasHeight,
        ),
      );
      results.add(
        SampleResult(
          sample: s,
          recognised: c.isEmpty ? '' : c.first.text,
          ms: watch.elapsedMilliseconds,
        ),
      );
    } catch (e) {
      results.add(
        SampleResult(
          sample: s,
          recognised: '',
          ms: watch.elapsedMilliseconds,
          error: '$e',
        ),
      );
    }
    onProgress?.call(results.length, samples.length);
  }
  return EvaluationSummary(recognizer.name, results);
}
