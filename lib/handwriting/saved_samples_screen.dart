import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/labeled_sample.dart';
import '../core/sample_backup.dart';
import '../core/sample_store.dart';
import '../core/stored_copy.dart' show formatDateTime;
import '../platform/file_transfer.dart' as files;

/// Lists saved samples so bad ones can be deleted, and backs them up to (or
/// restores them from) a file the user chooses.
class SavedSamplesScreen extends StatefulWidget {
  const SavedSamplesScreen({
    super.key,
    required this.store,
    this.saveFileAs = files.saveFileAs,
    this.openFile = files.openFile,
    this.now = DateTime.now,
  });

  final SampleStore store;
  final Future<bool> Function(String name, String mime, List<int> bytes)
  saveFileAs;
  final Future<List<int>?> Function(List<String> mimes) openFile;
  final DateTime Function() now;

  @override
  State<SavedSamplesScreen> createState() => _SavedSamplesScreenState();
}

class _SavedSamplesScreenState extends State<SavedSamplesScreen> {
  late Future<List<LabeledSample>> _samples = widget.store.all();

  /// True while backing up or restoring (shows a progress bar).
  bool _busy = false;

  void _say(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _run(Future<void> Function() job) async {
    setState(() => _busy = true);
    try {
      await job();
    } on SampleBackupException catch (e) {
      _say(e.message);
    } on PlatformException catch (e) {
      _say(
        e.code == 'too_big'
            ? (e.message ?? 'This file is too big.')
            : 'Something went wrong: ${e.message}',
      );
    } catch (e) {
      _say('Something went wrong: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _backUp() => _run(() async {
    final samples = await widget.store.all();
    if (samples.isEmpty) {
      _say('There are no samples to back up yet.');
      return;
    }
    final bytes = encodeSampleBackup(
      samples,
      exportedAt: widget.now(),
      appBuild: const String.fromEnvironment('BUILD_STAMP'),
    );
    final saved = await widget.saveFileAs(
      sampleBackupFileName(widget.now()),
      'application/zip',
      bytes,
    );
    if (!mounted || !saved) return;
    _say(
      'Backed up ${samples.length} samples '
      '(${(bytes.length / 1024).toStringAsFixed(0)} KB).',
    );
  });

  Future<void> _restore() => _run(() async {
    final bytes = await widget.openFile(const [
      'application/zip',
      'application/x-zip-compressed',
      'application/gzip',
      'application/x-gzip',
      'application/json',
      'application/octet-stream',
    ]);
    if (bytes == null) return;
    final incoming = decodeSampleBackup(bytes);
    final fresh = newSamplesOnly(await widget.store.all(), incoming);
    for (final s in fresh) {
      await widget.store.add(s);
    }
    final next = widget.store.all();
    if (!mounted) return;
    setState(() {
      _samples = next;
    });
    final skipped = incoming.length - fresh.length;
    _say(
      'Restored ${fresh.length} samples'
      '${skipped > 0 ? ' ($skipped were already here)' : ''}.',
    );
  });

  Future<void> _delete(LabeledSample s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this sample?'),
        content: Text('"${s.text}"'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!(ok ?? false)) return;
    await widget.store.delete(s.id!);
    final next = widget.store.all();
    setState(() {
      _samples = next;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Saved samples'),
      actions: [
        IconButton(
          tooltip: 'Back up samples to a file',
          icon: const Icon(Icons.save_alt),
          onPressed: _busy ? null : _backUp,
        ),
        IconButton(
          tooltip: 'Restore samples from a backup file',
          icon: const Icon(Icons.settings_backup_restore),
          onPressed: _busy ? null : _restore,
        ),
      ],
      bottom: _busy
          ? const PreferredSize(
              preferredSize: Size.fromHeight(4),
              child: LinearProgressIndicator(),
            )
          : null,
    ),
    body: FutureBuilder(
      future: _samples,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final samples = snap.data!.reversed.toList();
        if (samples.isEmpty) {
          return const Center(child: Text('No samples yet.'));
        }
        return ListView(
          children: [
            for (final s in samples)
              ListTile(
                title: Text(s.text),
                subtitle: Text(
                  '${formatDateTime(s.createdAt)} · ${s.strokes.length} '
                  'strokes',
                ),
                trailing: IconButton(
                  tooltip: 'Delete this sample',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _delete(s),
                ),
              ),
          ],
        );
      },
    ),
  );
}
