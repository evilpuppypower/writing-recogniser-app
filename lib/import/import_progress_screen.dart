import 'package:flutter/material.dart';

import '../core/transfer_estimate.dart';
import 'pdf_import_channel.dart';

/// Shows a progress bar and time remaining while a picked PDF is copied into
/// app storage, then calls [onDone] with the copy's path.
///
/// The copy itself is done by [copy] (normally [PdfImportChannel.copy]); it
/// is injectable so the screen can be tested without Android.
class ImportProgressScreen extends StatefulWidget {
  const ImportProgressScreen({
    super.key,
    required this.pdf,
    required this.onDone,
    required this.keep,
    this.copy = PdfImportChannel.copy,
    this.cancel = PdfImportChannel.cancel,
  });

  final PickedPdf pdf;

  /// How many PDF copies to keep in total (the user's setting).
  final int keep;
  final void Function(BuildContext context, String path, Duration took) onDone;
  final Future<String> Function(
    PickedPdf pdf, {
    required int keep,
    required void Function(int copied, int total) onProgress,
  })
  copy;
  final Future<void> Function() cancel;

  @override
  State<ImportProgressScreen> createState() => _ImportProgressScreenState();
}

class _ImportProgressScreenState extends State<ImportProgressScreen> {
  final _stopwatch = Stopwatch();
  late final _estimator = TransferEstimator(totalBytes: widget.pdf.size);
  String? _error;
  bool _cancelling = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    _stopwatch.start();
    try {
      final path = await widget.copy(
        widget.pdf,
        keep: widget.keep,
        onProgress: (copied, total) {
          if (!mounted) return;
          setState(
            () => _estimator.update(
              bytesDone: copied,
              elapsed: _stopwatch.elapsed,
            ),
          );
        },
      );
      if (!mounted) return;
      widget.onDone(context, path, _stopwatch.elapsed);
    } on ImportCancelled {
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _onCancel() async {
    setState(() => _cancelling = true);
    await widget.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final pdf = widget.pdf;
    final theme = Theme.of(context);
    final remaining = _estimator.remaining;
    final sizeText = pdf.size >= 0
        ? '${formatBytes(_estimator.bytesDone)} of ${formatBytes(pdf.size)}'
        : '${formatBytes(_estimator.bytesDone)} copied';
    final timeText = _cancelling
        ? 'Cancelling…'
        : remaining != null
        ? formatRemaining(remaining)
        : 'Estimating time left…';

    return Scaffold(
      appBar: AppBar(title: const Text('Importing PDF')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: _error != null
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.error_outline, color: theme.colorScheme.error),
                      const SizedBox(height: 12),
                      Text("Couldn't import ${pdf.name}"),
                      const SizedBox(height: 8),
                      Text(_error!, style: theme.textTheme.bodySmall),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Back'),
                      ),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        pdf.name,
                        style: theme.textTheme.titleMedium,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Copying into the app so it opens quickly next time. '
                        'Your original file is not changed.',
                        style: theme.textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      LinearProgressIndicator(value: _estimator.fraction),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(child: Text(sizeText)),
                          Text(timeText),
                        ],
                      ),
                      const SizedBox(height: 20),
                      Align(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.close),
                          label: const Text('Cancel'),
                          onPressed: _cancelling ? null : _onCancel,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
