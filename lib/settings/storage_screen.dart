import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../core/storage_use.dart';
import '../core/stored_copy.dart';
import '../core/transfer_estimate.dart' show formatBytes;
import '../import/pdf_import_channel.dart';
import '../storage/app_database.dart';
import '../storage/sqlite_page_layout_store.dart';
import 'stored_copies_screen.dart';

/// Measures what the app keeps: the stored PDFs and notebooks, the
/// database by what it holds, and the first-page pictures.
Future<StorageUse> measureStorage({
  required Database db,
  required String dbPath,
  required List<StoredCopy> copies,
  required Set<String> notebooks,
  Directory? thumbnails,
}) async {
  var pdfs = 0, pdfCount = 0, books = 0, bookCount = 0;
  for (final c in copies) {
    if (notebooks.contains(c.id)) {
      books += c.size;
      bookCount++;
    } else {
      pdfs += c.size;
      pdfCount++;
    }
  }
  final parts = <StoragePart>[
    StoragePart(
      'Stored PDFs',
      pdfs,
      '$pdfCount ${pdfCount == 1 ? 'PDF' : 'PDFs'} copied into the app so '
          'they open instantly. PDFs you\'ve written on are always kept; '
          'others can be deleted (they open from the original file again).',
    ),
    StoragePart(
      'Notebooks',
      books,
      '$bookCount ${bookCount == 1 ? 'notebook' : 'notebooks'} (their '
          'writing is counted under "Your writing").',
    ),
  ];
  var measured = 0;
  for (final e in storageTables.entries) {
    var bytes = 0;
    for (final sql in e.value.sums) {
      try {
        bytes +=
            ((await db.rawQuery(sql)).first.values.first as num?)?.toInt() ?? 0;
      } catch (_) {
        // A table this version doesn't have.
      }
    }
    measured += bytes;
    parts.add(StoragePart(e.key, bytes, e.value.about));
  }
  var file = 0;
  for (final suffix in ['', '-wal', '-journal']) {
    final f = File('$dbPath$suffix');
    if (await f.exists()) file += await f.length();
  }
  parts.add(
    StoragePart(
      'Other',
      (file - measured).clamp(0, file),
      'Settings, tags, bookmarks, page changes, and the database\'s own '
          'bookkeeping.',
    ),
  );
  if (thumbnails != null && await thumbnails.exists()) {
    var bytes = 0;
    await for (final f in thumbnails.list(recursive: true)) {
      if (f is File) bytes += await f.length();
    }
    parts.add(
      StoragePart(
        'First-page pictures',
        bytes,
        'The small pictures on the home screen. Made again when needed.',
      ),
    );
  }
  return StorageUse(parts);
}

Future<StorageUse> _measure() async {
  final db = await AppDatabase.open();
  final layouts = await SqlitePageLayoutStore.open();
  final support = await getApplicationSupportDirectory();
  return measureStorage(
    db: db,
    dbPath: p.join(await getDatabasesPath(), AppDatabase.fileName),
    copies: await PdfImportChannel.listCopies(),
    notebooks: (await layouts.notebooks()).toSet(),
    thumbnails: Directory(p.join(support.path, 'thumbnails')),
  );
}

Future<void> _clearSearchIndex() async {
  final db = await AppDatabase.open();
  await db.transaction((t) async {
    await t.delete('printed_text');
    await t.delete('printed_documents');
  });
}

/// Settings → Storage used: what the app keeps, biggest first, as a share
/// of the whole.
class StorageScreen extends StatefulWidget {
  const StorageScreen({
    super.key,
    this.measure = _measure,
    this.clearSearchIndex = _clearSearchIndex,
  });

  final Future<StorageUse> Function() measure;
  final Future<void> Function() clearSearchIndex;

  @override
  State<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends State<StorageScreen> {
  late Future<StorageUse> _use = widget.measure();

  void _again() => setState(() {
    _use = widget.measure();
  });

  Future<void> _clearIndex() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear the search index?'),
        content: const Text(
          'Your PDFs and writing aren\'t touched. The printed text is read '
          'again the next time you search everything, which takes a while '
          'for big PDFs.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    try {
      await widget.clearSearchIndex();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("Couldn't clear it: $e")));
      }
    }
    _again();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Storage used')),
      body: FutureBuilder<StorageUse>(
        future: _use,
        builder: (context, snap) {
          if (snap.hasError) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Text("Couldn't measure the storage used."),
            );
          }
          final use = snap.data;
          if (use == null) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('Measuring…'),
                ],
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'This app uses ${formatBytes(use.total)} on this tablet.',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              const Text(
                'Everything stays on the tablet. Backups are made '
                'separately, where you save them.',
              ),
              const SizedBox(height: 16),
              for (final part in use.parts) ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(part.name, style: theme.textTheme.titleSmall),
                    ),
                    Text(formatBytes(part.bytes)),
                  ],
                ),
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  value: use.share(part),
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(3),
                ),
                const SizedBox(height: 4),
                Text(part.about, style: theme.textTheme.bodySmall),
                const SizedBox(height: 16),
              ],
              const Divider(),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.folder_copy_outlined),
                label: const Text('Manage stored PDFs'),
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const StoredCopiesScreen(),
                    ),
                  );
                  _again();
                },
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.manage_search),
                label: const Text('Clear the search index'),
                onPressed: _clearIndex,
              ),
            ],
          );
        },
      ),
    );
  }
}
