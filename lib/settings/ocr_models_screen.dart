import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/ocr_models.dart';
import '../core/transfer_estimate.dart';
import '../core/app_settings.dart';
import '../platform/ocr_channel.dart';
import 'settings_controller.dart';

/// Which downloaded model reads scanned PDFs (kept in the settings).
const ocrModelPrefsKey = 'ocr.model';

Future<List<OcrModel>> _loadCatalogue() async =>
    parseOcrModels(await rootBundle.loadString('assets/ocr_models.txt'));

/// Settings → Reading scanned PDFs (owner, 2026-10-17): the text-reading
/// models, downloaded only when the user taps, with a quick button for
/// the recommended one; which to use; removing one.
class OcrModelsScreen extends StatefulWidget {
  const OcrModelsScreen({
    super.key,
    this.reader = const AndroidTextReader(),
    this.catalogue = _loadCatalogue,
    this.loadChoice = _loadChoice,
    this.saveChoice = _saveChoice,
  });

  final TextReaderService reader;
  final Future<List<OcrModel>> Function() catalogue;
  final Future<String?> Function() loadChoice;
  final Future<void> Function(String? id) saveChoice;

  static Future<String?> _loadChoice() =>
      SharedPreferencesAsync().getString(ocrModelPrefsKey);
  static Future<void> _saveChoice(String? id) async {
    final prefs = SharedPreferencesAsync();
    if (id == null) {
      await prefs.remove(ocrModelPrefsKey);
    } else {
      await prefs.setString(ocrModelPrefsKey, id);
    }
  }

  @override
  State<OcrModelsScreen> createState() => _OcrModelsScreenState();
}

class _OcrModelsScreenState extends State<OcrModelsScreen> {
  List<OcrModel>? _models;
  Set<String> _installed = const {};
  String? _chosen;

  /// The model downloading, and how far.
  String? _downloading;
  double? _fraction;
  Duration? _left;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    // Leaving the screen stops a download (it can be started again), so
    // none runs on unseen.
    if (_downloading != null) widget.reader.cancel().catchError((_) {});
    super.dispose();
  }

  Future<void> _load() async {
    final models = await widget.catalogue().catchError((_) => <OcrModel>[]);
    final known = {for (final m in models) m.id};
    final installed = (await widget.reader.installed().catchError(
      (_) => <String>{},
    )).where(known.contains).toSet();
    final chosen = await widget.loadChoice().catchError((_) => null);
    if (!mounted) return;
    setState(() {
      _models = models;
      _installed = installed;
      _chosen = installed.contains(chosen)
          ? chosen
          : (installed.isEmpty ? null : installed.first);
    });
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _download(OcrModel m) async {
    final started = DateTime.now();
    TransferEstimator? estimate;
    setState(() {
      _downloading = m.id;
      _fraction = null;
      _left = null;
    });
    try {
      await widget.reader.download(
        m,
        progress: (done, total) {
          if (!mounted) return;
          estimate ??= downloadEstimate(total);
          estimate!.update(
            bytesDone: done,
            elapsed: DateTime.now().difference(started),
          );
          setState(() {
            _fraction = estimate!.fraction;
            _left = estimate!.remaining;
          });
        },
      );
      if (_chosen == null) {
        _chosen = m.id;
        await widget.saveChoice(m.id);
      }
      _message('${m.name} is ready.');
    } catch (e) {
      final text = '$e';
      if (!text.contains('stopped')) {
        _message("${m.name} couldn't be downloaded: ${_plain(text)}");
      }
    }
    if (!mounted) return;
    setState(() => _downloading = null);
    await _load();
  }

  String _plain(String error) => error
      .replaceFirst(RegExp(r'^PlatformException\([^,]*, '), '')
      .replaceAll(RegExp(r', null, null\)$'), '');

  Future<void> _remove(OcrModel m) async {
    try {
      await widget.reader.remove(m.id);
    } catch (e) {
      _message("Couldn't remove it: $e");
    }
    if (_chosen == m.id) await widget.saveChoice(null);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final models = _models;
    final recommended = models
        ?.where((m) => m.id == recommendedOcrModel)
        .firstOrNull;
    return Scaffold(
      appBar: AppBar(title: const Text('Reading scanned PDFs')),
      body: models == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'Scanned PDFs are pictures of pages, so their text can\'t '
                  'be searched or highlighted until it\'s read. A '
                  'text-reading model does that here on the tablet. It\'s '
                  'downloaded only when you choose; nothing of yours is '
                  'sent anywhere.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                if (_downloading != null)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Downloading…'
                            '${_left == null ? '' : ' ${formatRemaining(_left!)}'}',
                          ),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(value: _fraction),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: () => widget.reader.cancel(),
                              child: const Text('Stop'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else if (recommended != null &&
                    !_installed.contains(recommended.id))
                  FilledButton.icon(
                    icon: const Icon(Icons.download),
                    label: Text('Download ${recommended.name}'),
                    onPressed: recommended.ready
                        ? () => _download(recommended)
                        : null,
                  ),
                const SizedBox(height: 16),
                if (context
                        .getInheritedWidgetOfExactType<SettingsScope>()
                        ?.notifier
                    case final settings?) ...[
                  Text(
                    'When a PDF looks scanned',
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<ScannedChoice>(
                    segments: const [
                      ButtonSegment(
                        value: ScannedChoice.ask,
                        label: Text('Ask'),
                      ),
                      ButtonSegment(
                        value: ScannedChoice.read,
                        label: Text('Read it'),
                      ),
                      ButtonSegment(
                        value: ScannedChoice.leave,
                        label: Text('Leave it'),
                      ),
                    ],
                    selected: {SettingsScope.valueOf(context).scannedPdfs},
                    onSelectionChanged: (v) => settings.update(
                      settings.value.copyWith(scannedPdfs: v.first),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                Text('Models', style: theme.textTheme.titleSmall),
                RadioGroup<String>(
                  groupValue: _chosen,
                  onChanged: (v) async {
                    if (v == null || !_installed.contains(v)) return;
                    setState(() => _chosen = v);
                    await widget.saveChoice(v);
                  },
                  child: Column(
                    children: [
                      for (final m in models)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Radio<String>(
                            value: m.id,
                            enabled: _installed.contains(m.id),
                          ),
                          title: Text(m.name),
                          subtitle: Text(
                            _installed.contains(m.id)
                                ? (_chosen == m.id
                                      ? 'Downloaded · in use'
                                      : 'Downloaded')
                                : m.ready
                                ? 'Not downloaded'
                                : 'Not available yet (its files are still being '
                                      'checked)',
                          ),
                          trailing: _installed.contains(m.id)
                              ? IconButton(
                                  tooltip: 'Remove ${m.name}',
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: _downloading == null
                                      ? () => _remove(m)
                                      : null,
                                )
                              : IconButton(
                                  tooltip: 'Download ${m.name}',
                                  icon: const Icon(Icons.download),
                                  onPressed: m.ready && _downloading == null
                                      ? () => _download(m)
                                      : null,
                                ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Models are PaddleOCR\'s, in a form the tablet can run, '
                  'from Hugging Face. Each file is checked against its '
                  'known fingerprint before it\'s kept.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
    );
  }
}

/// The downloaded model to read scanned pages with: the one chosen in
/// Settings, or else any downloaded one in the app's list; null if none.
Future<String?> chosenOcrModel(TextReaderService reader) async {
  try {
    final known = {for (final m in await _loadCatalogue()) m.id};
    final installed = (await reader.installed()).where(known.contains);
    if (installed.isEmpty) return null;
    final chosen = await OcrModelsScreen._loadChoice();
    return installed.contains(chosen) ? chosen : installed.first;
  } catch (_) {
    return null;
  }
}
