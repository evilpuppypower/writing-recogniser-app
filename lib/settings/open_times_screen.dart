import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/event_log.dart';
import '../core/latency.dart' show formatMs;
import '../core/open_timing.dart';
import '../platform/file_transfer.dart';
import '../storage/app_database.dart';
import '../storage/sqlite_event_log.dart';

/// Past PDF openings, newest first: how long from the tap until the first
/// page was shown, with file size and page count, to see how well large and
/// small PDFs open.
class OpenTimesScreen extends StatefulWidget {
  const OpenTimesScreen({
    super.key,
    this.openEventLog = _open,
    this.saveFile = saveFileAs,
  });

  final Future<EventLog> Function() openEventLog;

  /// Asks where to save the exported list (injectable for tests).
  final Future<bool> Function(String name, String mime, List<int> bytes)
  saveFile;

  static Future<EventLog> _open() async =>
      SqliteEventLog(await AppDatabase.open());

  @override
  State<OpenTimesScreen> createState() => _OpenTimesScreenState();
}

class _OpenTimesScreenState extends State<OpenTimesScreen> {
  late final Future<List<OpenTiming>> _times = _load();

  Future<List<OpenTiming>> _load() async {
    final log = await widget.openEventLog();
    final events = await log.ofType(OpenTiming.eventType);
    return [for (final e in events.reversed) ?OpenTiming.fromEvent(e)];
  }

  Future<void> _export() async {
    final messenger = ScaffoldMessenger.of(context);
    final times = await _times;
    if (times.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('There are no opening times to save.')),
      );
      return;
    }
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final name =
        'PDF opening times ${now.year}-${two(now.month)}-${two(now.day)}.csv';
    try {
      // Oldest first reads more naturally in a spreadsheet.
      final csv = OpenTiming.toCsv(times.reversed.toList());
      final saved = await widget.saveFile(name, 'text/csv', utf8.encode(csv));
      if (saved) {
        messenger.showSnackBar(SnackBar(content: Text('Saved $name')));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text("Couldn't save: $e")));
    }
  }

  String _when(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.day}/${t.month} ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('PDF opening times'),
      actions: [
        IconButton(
          tooltip: 'Save the list as a spreadsheet (CSV)',
          icon: const Icon(Icons.download),
          onPressed: _export,
        ),
      ],
    ),
    body: FutureBuilder(
      future: _times,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final times = snap.data ?? const <OpenTiming>[];
        if (times.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No PDFs opened yet. Each time a PDF opens, the time from '
                'your tap until its first page is shown is recorded here.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return ListView.separated(
          itemCount: times.length + 1,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            if (i == 0) {
              return const ListTile(
                subtitle: Text(
                  'Time from tapping a PDF until the page it opens at is '
                  'drawn and every page is ready. "File open" is when the '
                  'file itself was open. Newest first; stays on this tablet.',
                ),
              );
            }
            final t = times[i - 1];
            return ListTile(
              title: Text(t.name.isEmpty ? 'PDF' : t.name),
              subtitle: Text('${_when(t.at)} · ${t.details()}'),
              trailing: Text(
                formatMs(t.shownMs),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            );
          },
        );
      },
    ),
  );
}
