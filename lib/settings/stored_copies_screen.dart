import 'package:flutter/material.dart';

import '../core/stored_copy.dart';
import '../core/transfer_estimate.dart';
import '../import/pdf_import_channel.dart';
import '../storage/sqlite_ink_store.dart';
import 'settings_controller.dart';

/// Lists the stored PDF copies so the user can pin or delete them one by one.
class StoredCopiesScreen extends StatefulWidget {
  const StoredCopiesScreen({
    super.key,
    this.listCopies = PdfImportChannel.listCopies,
    this.deleteCopy = PdfImportChannel.deleteCopy,
    this.setPinned = PdfImportChannel.setPinned,
    this.inkDocuments = _inkDocuments,
    this.deleteInk = _deleteInk,
  });

  static Future<Set<String>> _inkDocuments() async =>
      (await SqliteInkStore.open()).documentsWithInk();

  static Future<void> _deleteInk(String id) async =>
      (await SqliteInkStore.open()).deleteDocument(id);

  // Injectable so the screen can be tested without Android.
  final Future<List<StoredCopy>> Function() listCopies;
  final Future<void> Function(StoredCopy copy) deleteCopy;
  final Future<void> Function(StoredCopy copy, bool pinned, int keep) setPinned;

  /// Library ids of PDFs with saved ink, and deleting one PDF's ink.
  final Future<Set<String>> Function() inkDocuments;
  final Future<void> Function(String id) deleteInk;

  @override
  State<StoredCopiesScreen> createState() => _StoredCopiesScreenState();
}

class _StoredCopiesScreenState extends State<StoredCopiesScreen> {
  late Future<List<StoredCopy>> _copies = _load();

  Future<List<StoredCopy>> _load() async =>
      sortForDisplay(await widget.listCopies());

  void _reload() {
    final next = _load();
    setState(() {
      _copies = next;
    });
  }

  Future<void> _togglePin(StoredCopy copy) async {
    final keep = SettingsScope.of(context).value.cachedPdfLimit;
    await widget.setPinned(copy, !copy.pinned, keep);
    _reload();
  }

  Future<void> _delete(StoredCopy copy) async {
    final settings = SettingsScope.of(context);
    final hasInk = (await widget.inkDocuments().catchError((_) => <String>{}))
        .contains(copy.id);
    if (!mounted) return;
    // Owner (2026-10-11): ink is kept by default (Settings), and the
    // dialog can delete it too for this PDF.
    var deleteInk = hasInk && !settings.value.keepInkOnDelete;
    if (settings.value.confirmDeleteCopy) {
      final result = await showDialog<({bool ok, bool dontAsk, bool ink})>(
        context: context,
        builder: (context) =>
            _DeleteCopyDialog(copy: copy, hasInk: hasInk, deleteInk: deleteInk),
      );
      if (result == null || !result.ok) return;
      deleteInk = hasInk && result.ink;
      if (result.dontAsk) {
        await settings.update(
          settings.value.copyWith(confirmDeleteCopy: false),
        );
      }
    }
    await widget.deleteCopy(copy);
    if (deleteInk) await widget.deleteInk(copy.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            'Deleted the copy of ${copy.displayName}'
            '${!hasInk
                ? ''
                : deleteInk
                ? ' and your ink on it'
                : '. Your ink is kept'}',
          ),
        ),
      );
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final limit = SettingsScope.of(context).value.cachedPdfLimit;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Stored copies')),
      body: FutureBuilder(
        future: _copies,
        builder: (context, snap) {
          if (snap.hasError) {
            return const Center(child: Text("Couldn't read stored copies."));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final copies = snap.data!;
          final total = copies.fold<int>(0, (sum, c) => sum + c.size);
          return ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'Pinned copies are always kept and don\'t count toward '
                  'your limit of $limit. Unpinned copies are removed oldest '
                  'first when you go over it.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              if (copies.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: Text('No stored copies.')),
                )
              else ...[
                for (final c in copies)
                  ListTile(
                    leading: Icon(
                      c.pinned ? Icons.push_pin : Icons.picture_as_pdf_outlined,
                      color: c.pinned ? theme.colorScheme.primary : null,
                    ),
                    title: Text(c.displayName, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      '${formatBytes(c.size)} · last opened '
                      '${formatDateTime(c.lastUsed)}'
                      '${c.pinned ? ' · pinned' : ''}',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: c.pinned
                              ? 'Unpin (may be removed when over the limit)'
                              : 'Pin (always keep this copy)',
                          icon: Icon(
                            c.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                          ),
                          onPressed: () => _togglePin(c),
                        ),
                        IconButton(
                          tooltip: 'Delete this copy',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _delete(c),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Total: ${formatBytes(total)} for ${copies.length} '
                    '${copies.length == 1 ? 'copy' : 'copies'}.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Asks before deleting one copy, with a "Don't ask again" tick box and,
/// if the PDF has ink, whether to delete the ink too.
class _DeleteCopyDialog extends StatefulWidget {
  const _DeleteCopyDialog({
    required this.copy,
    required this.hasInk,
    required this.deleteInk,
  });

  final StoredCopy copy;
  final bool hasInk;

  /// Starting value of "Also delete my ink" (from Settings).
  final bool deleteInk;

  @override
  State<_DeleteCopyDialog> createState() => _DeleteCopyDialogState();
}

class _DeleteCopyDialogState extends State<_DeleteCopyDialog> {
  bool _dontAsk = false;
  late bool _deleteInk = widget.deleteInk;

  @override
  Widget build(BuildContext context) {
    final copy = widget.copy;
    return AlertDialog(
      title: const Text('Delete this copy?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${copy.displayName} (${formatBytes(copy.size)}) will be removed '
            'from the app. Your original file is not touched; it will just '
            'be imported again the next time you open it.',
          ),
          if (widget.hasInk) ...[
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Also delete my ink on this PDF'),
              subtitle: Text(
                _deleteInk
                    ? "Your writing on it is deleted too. This can't be undone."
                    : 'Your writing is kept and comes back if you open the '
                          'same file again.',
              ),
              value: _deleteInk,
              onChanged: (v) => setState(() => _deleteInk = v ?? false),
            ),
          ],
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text("Don't ask again"),
            subtitle: const Text('You can turn this back on in Settings.'),
            value: _dontAsk,
            onChanged: (v) => setState(() => _dontAsk = v ?? false),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(context, (ok: false, dontAsk: false, ink: false)),
          child: const Text('Keep'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, (
            ok: true,
            dontAsk: _dontAsk,
            ink: _deleteInk,
          )),
          child: const Text('Delete'),
        ),
      ],
    );
  }
}
