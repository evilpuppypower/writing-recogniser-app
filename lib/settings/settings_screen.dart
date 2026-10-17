import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:convert';

import '../core/app_settings.dart';
import '../core/diagnostics_report.dart';
import '../core/event_log.dart';
import '../library/home_screen.dart' show buildStamp;
import '../platform/diagnostics.dart';
import '../platform/file_transfer.dart';
import '../storage/app_database.dart';
import '../storage/sqlite_event_log.dart';
import '../core/pen_tools.dart';
import '../core/transfer_estimate.dart';
import '../import/pdf_import_channel.dart';
import '../recognition/myscript_keys.dart';
import '../viewer/pen_tools_controller.dart';
import 'settings_controller.dart';
import '../storage/sqlite_ink_store.dart';
import 'learning_screen.dart';
import 'open_times_screen.dart';
import 'replay_screen.dart';
import 'stored_copies_screen.dart';
import 'your_writing_screen.dart';
import 'backup_screen.dart';
import 'storage_screen.dart';
import 'dictionary_screen.dart';
import '../storage/sqlite_page_layout_store.dart';

/// App settings: scroll tab appearance and how many imported PDFs to keep.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.cacheInfo = PdfImportChannel.cacheInfo,
    this.trimCache = PdfImportChannel.trimCache,
    this.clearCache = PdfImportChannel.clearCache,
    this.myScriptKeys = const MyScriptKeyStore(),
    this.loadPenTools = PenToolsController.load,
    this.inkDocuments = _inkDocuments,
    this.deleteAllInk = _deleteAllInk,
    this.deleteNotebooks = _deleteNotebooks,
    this.loadDiagnostics = _loadDiagnostics,
    this.saveFile = saveFileAs,
  });

  /// The diagnostic log and the last crash, for "Save diagnostic report".
  final Future<(List<LoggedEvent>, String?)> Function() loadDiagnostics;
  final Future<bool> Function(String name, String mime, List<int> bytes)
  saveFile;

  static Future<(List<LoggedEvent>, String?)> _loadDiagnostics() async => (
    await SqliteEventLog(await AppDatabase.open()).ofType('diagnostic'),
    await lastCrashReport(),
  );

  static Future<Set<String>> _inkDocuments() async =>
      (await SqliteInkStore.open()).documentsWithInk();

  /// Notebooks go with every copy (they can't be opened again), with
  /// what's written in them.
  static Future<void> _deleteNotebooks() async {
    final layouts = await SqlitePageLayoutStore.open();
    final ink = await SqliteInkStore.open();
    for (final id in await layouts.notebooks()) {
      await ink.deleteDocument(id);
    }
  }

  static Future<void> _deleteAllInk() async {
    final store = await SqliteInkStore.open();
    for (final id in await store.documentsWithInk()) {
      await store.deleteDocument(id);
    }
  }

  // Injectable so the screen can be tested without Android.
  final Future<({int count, int bytes})> Function() cacheInfo;
  final Future<void> Function(int keep) trimCache;
  final Future<void> Function() clearCache;
  final MyScriptKeyStore myScriptKeys;
  final Future<PenToolsController> Function() loadPenTools;
  final Future<Set<String>> Function() inkDocuments;
  final Future<void> Function() deleteAllInk;
  final Future<void> Function() deleteNotebooks;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late Future<({int count, int bytes})> _cache = widget.cacheInfo();
  late Future<MyScriptKeys?> _keys = widget.myScriptKeys.load();
  late final Future<PenToolsController> _pens = widget.loadPenTools();

  Future<void> _editKeys() async {
    final current = await _keys;
    if (!mounted) return;
    final result = await showDialog<_KeysResult>(
      context: context,
      builder: (_) => _MyScriptKeysDialog(current: current),
    );
    if (result == null) return;
    if (result.remove) {
      await widget.myScriptKeys.clear();
    } else {
      final saved = await widget.myScriptKeys.save(result.keys!);
      if (!saved && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "Keys not saved: this device can't store them encrypted.",
            ),
          ),
        );
      }
    }
    final next = widget.myScriptKeys.load();
    setState(() {
      _keys = next;
    });
  }

  void _refreshCache() {
    final next = widget.cacheInfo();
    setState(() {
      _cache = next;
    });
  }

  /// Deletes copies beyond the new limit once the slider is released.
  Future<void> _applyLimit(int limit) async {
    await widget.trimCache(limit);
    _refreshCache();
  }

  /// Saves the diagnostic report where the user picks (owner's request).
  Future<void> _saveDiagnostics() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final (entries, crash) = await widget.loadDiagnostics();
      final now = DateTime.now();
      final text = diagnosticReport(
        entries,
        build: buildStamp,
        now: now,
        lastCrash: crash,
      );
      final saved = await widget.saveFile(
        diagnosticReportFileName(now),
        'text/plain',
        utf8.encode(text),
      );
      if (saved && mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Saved the diagnostic report (${entries.length} entries). '
              'Open it and paste its text to Claude.',
            ),
          ),
        );
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text("Couldn't save the diagnostic report: $e")),
      );
    }
  }

  Future<void> _confirmClearAll() async {
    final info = await _cache.catchError((_) => (count: -1, bytes: 0));
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    final what = info.count < 0
        ? 'every stored copy'
        : 'all ${info.count} stored '
              '${info.count == 1 ? 'copy' : 'copies'} '
              '(${formatBytes(info.bytes)})';
    final inkCount = (await widget.inkDocuments().catchError((_) => <String>{}))
        .length;
    if (!mounted) return;
    var deleteInk = !SettingsScope.of(context).value.keepInkOnDelete;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          icon: Icon(Icons.warning_amber_rounded, color: scheme.error),
          title: const Text('Delete ALL stored copies?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This deletes $what, including pinned ones. It can\'t be '
                'undone.\n\n'
                'Your original PDFs are not touched; they will be imported '
                'again the next time you open them.',
              ),
              if (inkCount > 0)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(
                    'Also delete my ink on $inkCount '
                    '${inkCount == 1 ? 'PDF' : 'PDFs'}',
                  ),
                  subtitle: Text(
                    deleteInk
                        ? "Your writing is deleted too. This can't be undone."
                        : 'Your writing is kept and comes back when you open '
                              'the same files again.',
                  ),
                  value: deleteInk,
                  onChanged: (v) => setDialog(() => deleteInk = v ?? false),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: scheme.error,
                foregroundColor: scheme.onError,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete ALL'),
            ),
          ],
        ),
      ),
    );
    if (ok ?? false) {
      await widget.clearCache();
      await widget.deleteNotebooks().catchError((_) {});
      if (deleteInk && inkCount > 0) await widget.deleteAllInk();
      _refreshCache();
    }
  }

  Future<void> _openStoredCopies() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const StoredCopiesScreen()));
    _refreshCache();
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsScope.of(context);
    final s = settings.value;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          const _Header('Appearance'),
          ListTile(
            title: const Text('App colour'),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in AppColour.values)
                    ChoiceChip(
                      avatar: c.argb == null
                          ? const Icon(Icons.wallpaper, size: 18)
                          : CircleAvatar(backgroundColor: Color(c.argb!)),
                      label: Text(c.label),
                      tooltip: c.argb == null
                          ? "Use your tablet's theme colour"
                          : null,
                      selected: s.appColour == c,
                      onSelected: (_) =>
                          settings.update(s.copyWith(appColour: c)),
                    ),
                ],
              ),
            ),
          ),
          ListTile(
            title: const Text('Message colours'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 8),
                SegmentedButton<MessageStyle>(
                  segments: [
                    for (final m in MessageStyle.values)
                      ButtonSegment(
                        value: m,
                        label: Text(m.label),
                        tooltip: m.description,
                      ),
                  ],
                  selected: {s.messageStyle},
                  onSelectionChanged: (v) =>
                      settings.update(s.copyWith(messageStyle: v.single)),
                ),
                const SizedBox(height: 4),
                Text(
                  'Pop-up messages and button labels: '
                  '${s.messageStyle.description.toLowerCase()}.',
                ),
              ],
            ),
          ),
          const Divider(),
          const _Header('Scroll tab'),
          ListTile(
            title: const Text('When not scrolling'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 8),
                SegmentedButton<ScrollTabIdle>(
                  segments: [
                    for (final m in ScrollTabIdle.values)
                      ButtonSegment(value: m, label: Text(m.label)),
                  ],
                  selected: {s.scrollTabIdle},
                  onSelectionChanged: (v) =>
                      settings.update(s.copyWith(scrollTabIdle: v.single)),
                ),
                const SizedBox(height: 4),
                Text(switch (s.scrollTabIdle) {
                  ScrollTabIdle.visible => 'The tab always stays full size.',
                  ScrollTabIdle.slim =>
                    'After ${AppSettings.scrollTabIdleAfter.inSeconds} '
                        'seconds it shrinks to a thin see-through bar you can '
                        'still drag.',
                  ScrollTabIdle.hidden =>
                    'After ${AppSettings.scrollTabIdleAfter.inSeconds} '
                        'seconds it fades out. Scroll or zoom to bring it back.',
                }),
                if (s.scrollTabIdle == ScrollTabIdle.slim) ...[
                  const SizedBox(height: 12),
                  Text('Slim bar: ${s.slimTabOpacityPercent}% solid'),
                  Row(
                    children: [
                      const Tooltip(
                        message: 'More see-through',
                        child: Icon(Icons.opacity, size: 18),
                      ),
                      Expanded(
                        child: Slider(
                          value: s.slimTabOpacityPercent.toDouble(),
                          min: AppSettings.minSlimTabOpacityPercent.toDouble(),
                          max: AppSettings.maxSlimTabOpacityPercent.toDouble(),
                          divisions: 17,
                          label: '${s.slimTabOpacityPercent}%',
                          onChanged: (v) => settings.update(
                            s.copyWith(slimTabOpacityPercent: v.round()),
                          ),
                        ),
                      ),
                      // Live preview of the slim bar.
                      Tooltip(
                        message: 'Preview',
                        child: Opacity(
                          opacity: s.slimTabOpacityPercent / 100,
                          child: Container(
                            width: 10,
                            height: 44,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(5),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const Divider(),
          const _Header('Pen toolbar'),
          FutureBuilder(
            future: _pens,
            builder: (context, snap) {
              final pens = snap.data;
              if (pens == null) return const SizedBox(height: 56);
              return ValueListenableBuilder(
                valueListenable: pens,
                builder: (context, tools, _) => ListTile(
                  title: const Text('Where the pen toolbar sits'),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 8),
                      SegmentedButton<ToolbarDock>(
                        segments: [
                          for (final d in ToolbarDock.values)
                            ButtonSegment(value: d, label: Text(d.label)),
                        ],
                        selected: {tools.dock},
                        onSelectionChanged: (v) =>
                            pens.update(tools.copyWith(dock: v.single)),
                      ),
                      const SizedBox(height: 4),
                      const Text('Applies the next time you open a PDF.'),
                    ],
                  ),
                ),
              );
            },
          ),
          const Divider(),
          const _Header('Handwriting'),
          SwitchListTile(
            title: const Text('Learn how long I pause'),
            subtitle: Text(
              s.autoPause
                  ? 'Waits ${(s.learnedPauseMs / 1000).toStringAsFixed(1)} s '
                        'after you lift the pen, learned from how long you '
                        'pause in the middle of words. Keeps adjusting as you '
                        'write.'
                  : 'Off: uses the pause you set below.',
            ),
            value: s.autoPause,
            onChanged: (v) => settings.update(s.copyWith(autoPause: v)),
          ),
          if (!s.autoPause)
            ListTile(
              title: Text(
                'Recognise after a '
                '${(s.recognitionPauseMs / 1000).toStringAsFixed(1)} s pause',
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Slider(
                    value: s.recognitionPauseMs.toDouble(),
                    min: AppSettings.minRecognitionPauseMs.toDouble(),
                    max: AppSettings.maxRecognitionPauseMs.toDouble(),
                    divisions:
                        (AppSettings.maxRecognitionPauseMs -
                            AppSettings.minRecognitionPauseMs) ~/
                        100,
                    label:
                        '${(s.recognitionPauseMs / 1000).toStringAsFixed(1)} s',
                    onChanged: (v) => settings.update(
                      s.copyWith(recognitionPauseMs: v.round()),
                    ),
                  ),
                  const Text(
                    'How long after you lift the pen before your writing is '
                    'turned into text. Shorter feels quicker but may cut words '
                    'in half if you pause mid-word.',
                  ),
                ],
              ),
            ),
          ListTile(
            title: const Text('Writing hand'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 8),
                SegmentedButton<WritingHand>(
                  segments: [
                    for (final h in WritingHand.values)
                      ButtonSegment(value: h, label: Text(h.label)),
                  ],
                  selected: {s.writingHand},
                  onSelectionChanged: (v) =>
                      settings.update(s.copyWith(writingHand: v.single)),
                ),
                const SizedBox(height: 12),
                Text('Writing box: ${s.writingBoxPercent}% of the width'),
                Slider(
                  value: s.writingBoxPercent.toDouble(),
                  min: AppSettings.minWritingBoxPercent.toDouble(),
                  max: AppSettings.maxWritingBoxPercent.toDouble(),
                  divisions:
                      AppSettings.maxWritingBoxPercent -
                      AppSettings.minWritingBoxPercent,
                  label: '${s.writingBoxPercent}%',
                  onChanged: (v) =>
                      settings.update(s.copyWith(writingBoxPercent: v.round())),
                ),
                Text(
                  s.writingBoxPercent >= AppSettings.maxWritingBoxPercent
                      ? 'The box for samples and the handwriting test uses '
                            'the full width.'
                      : 'The box for samples and the handwriting test sits '
                            'on the ${s.writingHand == WritingHand.right ? 'left' : 'right'}, '
                            'so your hand never has to write near the '
                            '${s.writingHand == WritingHand.right ? 'right' : 'left'} edge.',
                ),
              ],
            ),
          ),
          SwitchListTile(
            title: const Text('Pressure changes line thickness'),
            subtitle: Text(
              s.pressureOn
                  ? 'Yes: pressing harder draws a thicker line.'
                  : 'No: every line keeps its set thickness, like most PDF '
                        'apps. The pen pressure is still recorded.',
            ),
            value: s.pressureOn,
            onChanged: (v) => settings.update(s.copyWith(pressureOn: v)),
          ),
          if (s.pressureOn) ...[
            ListTile(
              title: Text(
                'How much thickness can change: '
                '±${s.pressureRangePercent}%'
                '${s.pressureRangePercent == AppSettings.defaultPressureRangePercent ? ' (standard)' : ''}',
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Slider(
                    value: s.pressureRangePercent.toDouble(),
                    min: AppSettings.minPressureRangePercent.toDouble(),
                    max: AppSettings.maxPressureRangePercent.toDouble(),
                    divisions: 18,
                    label: '±${s.pressureRangePercent}%',
                    onChanged: (v) => settings.update(
                      s.copyWith(pressureRangePercent: v.round()),
                    ),
                  ),
                  const Text(
                    'Move right for a bigger difference between light and '
                    'hard presses.',
                  ),
                ],
              ),
            ),
            PressureExample(response: s.pressureResponse),
          ],
          ListTile(
            leading: const Icon(Icons.menu_book_outlined),
            title: const Text('My words and shorthand'),
            subtitle: const Text(
              'Your own words, preferred when reading, and shorthand written '
              'out in full.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const DictionaryScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.straighten),
            title: const Text('Your writing'),
            subtitle: const Text(
              'Your usual letter size and slant, as learned. Change them '
              'if they\'re not right.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const YourWritingScreen(),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.backup_outlined),
            title: const Text('Backups'),
            subtitle: const Text(
              'Everything in one file, locked with your password: back up, '
              'or restore on this tablet or a new one.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const BackupScreen()),
            ),
          ),
          SwitchListTile(
            title: const Text('Suggest tags from what\'s in a document'),
            subtitle: const Text(
              'Tags are suggested from a document\'s name, and also from '
              'your writing in it. It\'s all read on this tablet.',
            ),
            value: s.suggestTagsFromContents,
            onChanged: (v) =>
                settings.update(s.copyWith(suggestTagsFromContents: v)),
          ),
          SwitchListTile(
            title: const Text('Writing box button'),
            subtitle: const Text(
              'A button in the PDF\'s toolbar that opens a strip along the '
              'bottom: write large there, and the ink lands small on the '
              'page, moving along as you write.',
            ),
            value: s.writingBoxButton,
            onChanged: (v) => settings.update(s.copyWith(writingBoxButton: v)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.pause_circle_outline),
            title: const Text('Read my writing later'),
            subtitle: const Text(
              'Handwriting isn\'t read as you write, only when you tap '
              '"Read all now" in the PDF. Until then it isn\'t typed text, '
              'found by search or learned from. Each document can change '
              'this with the button in its toolbar.',
            ),
            value: s.readLater,
            onChanged: (v) => settings.update(s.copyWith(readLater: v)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.battery_saver),
            title: const Text('Battery saver'),
            subtitle: const Text(
              'Writing is read after you pause for 2 seconds (fewer reads '
              'while you write), PDFs\' printed text is read for search '
              'only when you ask, and automatic backups wait.',
            ),
            value: s.batterySaver,
            onChanged: (v) => settings.update(s.copyWith(batterySaver: v)),
          ),
          SwitchListTile(
            title: const Text('Also when Android\'s battery saver is on'),
            subtitle: const Text(
              'Battery saver turns on by itself while the tablet\'s own '
              'battery saver is on.',
            ),
            value: s.batterySaverWithSystem,
            onChanged: (v) =>
                settings.update(s.copyWith(batterySaverWithSystem: v)),
          ),
          SwitchListTile(
            title: const Text('Highlights summary'),
            subtitle: const Text(
              'A button in the PDF\'s toolbar that lists the printed text '
              'you highlighted and your notes, page by page, to copy or '
              'save for revision.',
            ),
            value: s.highlightsSummary,
            onChanged: (v) => settings.update(s.copyWith(highlightsSummary: v)),
          ),
          SwitchListTile(
            title: const Text('Tidy up shapes'),
            subtitle: const Text(
              'Hold the pen still at the end of a circle, rectangle or '
              'triangle to make it neat. Undo or erase a tidied shape '
              'straight away and shapes like it are only tidied when '
              'drawn closer to it.',
            ),
            value: s.tidyShapes,
            onChanged: (v) => settings.update(s.copyWith(tidyShapes: v)),
          ),
          ListTile(
            title: const Text('Forget what it learned about shapes'),
            subtitle: const Text('Tidy shapes as eagerly as at first again.'),
            trailing: const Icon(Icons.restart_alt),
            onTap: () async {
              final messenger = ScaffoldMessenger.of(context);
              try {
                await SharedPreferencesAsync().remove('shapes.learned');
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text('Shapes are tidied as at first.'),
                  ),
                );
              } catch (e) {
                messenger.showSnackBar(
                  SnackBar(content: Text("Couldn't do that: $e")),
                );
              }
            },
          ),
          ListTile(
            title: Text(
              s.arrowHookMs == 0
                  ? 'Arrows: keep the whole line'
                  : 'Arrows: ignore the last ${s.arrowHookMs} ms of the line '
                        'if it hooks',
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Slider(
                  value: s.arrowHookMs.toDouble(),
                  max: AppSettings.maxArrowHookMs.toDouble(),
                  divisions: 20,
                  label: s.arrowHookMs == 0 ? 'Off' : '${s.arrowHookMs} ms',
                  onChanged: (v) =>
                      settings.update(s.copyWith(arrowHookMs: v.round())),
                ),
                const Text(
                  'Pens often flick sideways as they lift, which would twist '
                  'the arrowhead. A sharp turn in this last moment of the '
                  'line is dropped. Move left if real bends get cut off, '
                  'right if heads still point the wrong way. 0 turns it off.',
                ),
              ],
            ),
          ),
          const Divider(),
          const _Header('Recognised text'),
          ListTile(
            title: const Text('Text over your handwriting'),
            subtitle: const Text(
              'Small labels showing what each word was read as. '
              'Double-tap a label with a finger to correct it.',
            ),
            trailing: DropdownButton<TextLabelPlace>(
              value: s.textLabels,
              onChanged: (v) {
                if (v != null) settings.update(s.copyWith(textLabels: v));
              },
              items: [
                for (final p in TextLabelPlace.values)
                  DropdownMenuItem(value: p, child: Text(p.label)),
              ],
            ),
          ),
          SwitchListTile(
            title: const Text('Ask about words it isn\'t sure of'),
            subtitle: const Text(
              'A "?" on a label when the word may be misread. Tap it to say '
              "it's right or fix it; the app learns from either.",
            ),
            value: s.askWhenUnsure,
            onChanged: (v) => settings.update(s.copyWith(askWhenUnsure: v)),
          ),
          ListTile(
            title: const Text('Text panel'),
            subtitle: const Text(
              "The page's recognised text in a panel beside the PDF, or in "
              'a window you can move and resize.',
            ),
            trailing: DropdownButton<TextPanelPlace>(
              value: s.textPanel,
              onChanged: (v) {
                if (v != null) settings.update(s.copyWith(textPanel: v));
              },
              items: [
                for (final p in TextPanelPlace.values)
                  DropdownMenuItem(value: p, child: Text(p.label)),
              ],
            ),
          ),
          ListTile(
            title: const Text('Writing guide line'),
            subtitle: const Text(
              'A faint line that fades in under the line you are writing, '
              'to keep a sentence straight and together.',
            ),
            trailing: DropdownButton<WritingGuide>(
              value: s.writingGuide,
              onChanged: (v) {
                if (v != null) settings.update(s.copyWith(writingGuide: v));
              },
              items: [
                for (final g in WritingGuide.values)
                  DropdownMenuItem(value: g, child: Text(g.label)),
              ],
            ),
          ),
          ListTile(
            title: const Text('Page colours'),
            subtitle: const Text(
              'Dark pages for reading at night: the page and your ink are '
              'shown in reverse on screen. The PDF itself is unchanged. '
              'For PDFs without a choice of their own (hold a PDF on the '
              'home screen to give it one); exports can be dark too.',
            ),
            trailing: DropdownButton<PageColours>(
              value: s.pageColours,
              onChanged: (v) {
                if (v != null) settings.update(s.copyWith(pageColours: v));
              },
              items: [
                for (final c in PageColours.values)
                  DropdownMenuItem(value: c, child: Text(c.label)),
              ],
            ),
          ),
          SwitchListTile(
            title: const Text('Ask when I import a PDF'),
            subtitle: const Text('Light or dark pages for each new PDF'),
            value: s.askPageColours,
            onChanged: (v) => settings.update(s.copyWith(askPageColours: v)),
          ),
          const Divider(),
          const _Header('MyScript Cloud'),
          FutureBuilder(
            future: _keys,
            builder: (context, snap) => ListTile(
              leading: const Icon(Icons.key_outlined),
              title: const Text('MyScript keys'),
              subtitle: Text(
                snap.connectionState != ConnectionState.done
                    ? 'Checking…'
                    : snap.data == null
                    ? 'Not set. Needed to use MyScript Cloud in the '
                          'handwriting test.'
                    : 'Set. Stored only on this tablet.',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: _editKeys,
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'MyScript Cloud sends your pen strokes (only) over the internet '
              'to MyScript to be recognised. ML Kit works entirely on the '
              'tablet.',
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.insights_outlined),
            title: const Text('How well is it learning?'),
            subtitle: const Text(
              'Whether your corrections make recognition better over time.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const LearningScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.replay),
            title: const Text('Replay test'),
            subtitle: const Text(
              'Re-reads your saved practice sentences with and without '
              'learning from corrections, and compares the two.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ReplayScreen()),
            ),
          ),
          const Divider(),
          const _Header('Storage'),
          ListTile(
            leading: const Icon(Icons.timer_outlined),
            title: const Text('PDF opening times'),
            subtitle: const Text(
              'How long each PDF took from your tap until its first page '
              'was shown.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const OpenTimesScreen()),
            ),
          ),
          ListTile(
            title: Text(
              'Keep copies of the last ${s.cachedPdfLimit} PDFs '
              '(plus any you pin)',
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Slider(
                  value: s.cachedPdfLimit.toDouble(),
                  min: AppSettings.minCachedPdfs.toDouble(),
                  max: AppSettings.maxCachedPdfs.toDouble(),
                  divisions:
                      AppSettings.maxCachedPdfs - AppSettings.minCachedPdfs,
                  label: '${s.cachedPdfLimit}',
                  onChanged: (v) =>
                      settings.update(s.copyWith(cachedPdfLimit: v.round())),
                  onChangeEnd: (v) => _applyLimit(v.round()),
                ),
                const Text(
                  'Imported PDFs are copied into the app so they reopen '
                  'instantly. Each copy takes as much space as the original '
                  'file, so the space this app uses grows with the number '
                  'and size of PDFs kept.',
                ),
                const SizedBox(height: 8),
                FutureBuilder(
                  future: _cache,
                  builder: (context, snap) => Text(
                    snap.hasData
                        ? 'Now using ${formatBytes(snap.data!.bytes)} for '
                              '${snap.data!.count} '
                              '${snap.data!.count == 1 ? 'PDF' : 'PDFs'}.'
                        : snap.hasError
                        ? "Couldn't check storage use."
                        : 'Checking storage use…',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.pie_chart_outline),
            title: const Text('Storage used'),
            subtitle: const Text(
              'How much space PDFs, your writing, what the app has learned '
              'and the search index take.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const StorageScreen()),
            ),
          ),
          SwitchListTile(
            title: const Text('Ask before deleting a single copy'),
            subtitle: const Text(
              'Turned off when you tick "Don\'t ask again". Deleting ALL '
              'copies always asks.',
            ),
            value: s.confirmDeleteCopy,
            onChanged: (v) => settings.update(s.copyWith(confirmDeleteCopy: v)),
          ),
          SwitchListTile(
            title: const Text('Keep my ink when a stored PDF is deleted'),
            subtitle: Text(
              s.keepInkOnDelete
                  ? 'Your writing comes back if you open the same file again. '
                        'The delete message can still delete it for one PDF.'
                  : 'Deleting a stored PDF also deletes your writing on it, '
                        'unless you untick that in the delete message.',
            ),
            value: s.keepInkOnDelete,
            onChanged: (v) => settings.update(s.copyWith(keepInkOnDelete: v)),
          ),
          ListTile(
            leading: const Icon(Icons.folder_copy_outlined),
            title: const Text('Manage stored copies'),
            subtitle: const Text('See each copy, pin it, or delete it'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openStoredCopies,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
                icon: const Icon(Icons.delete_forever_outlined),
                label: const Text('Delete ALL stored copies'),
                onPressed: _confirmClearAll,
              ),
            ),
          ),
          const Divider(),
          const _Header('Testing'),
          SwitchListTile(
            title: const Text('Show smoothness graphs'),
            subtitle: const Text(
              'Two graphs at the top of the screen measure how smoothly the '
              'app draws. Thin green bars: smooth. Red bars: a stutter. '
              'Turns off when the app restarts.',
            ),
            value: settings.showSmoothnessGraphs,
            onChanged: (v) => settings.showSmoothnessGraphs = v,
          ),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('Save diagnostic report'),
            subtitle: const Text(
              'A text file to send Claude when something goes wrong: what '
              'happened in exports (step by step), how long the screen took '
              'to draw, and the last crash. No document names, words or '
              'handwriting.',
            ),
            onTap: _saveDiagnostics,
          ),
          const Divider(),
          const _Header('About'),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About and open source licences'),
            subtitle: const Text(
              'Writing Recogniser is open source (MIT licence), made by '
              'evilpuppypower. Also lists the licences of the libraries it '
              'uses.',
            ),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'Writing Recogniser',
              applicationLegalese:
                  'Copyright (c) 2026 evilpuppypower. MIT licence.\n'
                  'Handwriting recognition by MyScript iink (proprietary, '
                  'used under MyScript\'s licence) and Google ML Kit.',
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

class _KeysResult {
  const _KeysResult.save(MyScriptKeys this.keys) : remove = false;
  const _KeysResult.remove() : keys = null, remove = true;

  final MyScriptKeys? keys;
  final bool remove;
}

/// Enter or remove the MyScript Cloud keys.
class _MyScriptKeysDialog extends StatefulWidget {
  const _MyScriptKeysDialog({this.current});

  final MyScriptKeys? current;

  @override
  State<_MyScriptKeysDialog> createState() => _MyScriptKeysDialogState();
}

class _MyScriptKeysDialogState extends State<_MyScriptKeysDialog> {
  late final _app = TextEditingController(text: widget.current?.applicationKey);
  late final _hmac = TextEditingController(text: widget.current?.hmacKey);
  bool _show = false;

  @override
  void dispose() {
    _app.dispose();
    _hmac.dispose();
    super.dispose();
  }

  bool get _valid =>
      _app.text.trim().isNotEmpty && _hmac.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('MyScript keys'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'At developer.myscript.com, create an application, then copy '
            'its two keys here. They are stored only on this tablet.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _app,
            obscureText: !_show,
            // Secrets: the keyboard mustn't learn, suggest or sync them.
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            keyboardType: TextInputType.visiblePassword,
            decoration: const InputDecoration(labelText: 'Application key'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _hmac,
            obscureText: !_show,
            // Secrets: the keyboard mustn't learn, suggest or sync them.
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            keyboardType: TextInputType.visiblePassword,
            decoration: const InputDecoration(labelText: 'HMAC key'),
            onChanged: (_) => setState(() {}),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Show keys'),
            value: _show,
            onChanged: (v) => setState(() => _show = v ?? false),
          ),
        ],
      ),
    ),
    actions: [
      if (widget.current != null)
        TextButton(
          onPressed: () => Navigator.pop(context, const _KeysResult.remove()),
          child: const Text('Remove keys'),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _valid
            ? () => Navigator.pop(
                context,
                _KeysResult.save(MyScriptKeys(_app.text, _hmac.text)),
              )
            : null,
        child: const Text('Save'),
      ),
    ],
  );
}

/// Shows what the pressure settings do: a line drawn from a light press
/// (left) to a hard press (right), and the widths for a 2 pt pen.
class PressureExample extends StatelessWidget {
  const PressureExample({super.key, required this.response});

  final PressureResponse response;

  static String _pt(double v) {
    final t = v.toStringAsFixed(1);
    return t.endsWith('.0') ? t.substring(0, t.length - 2) : t;
  }

  @override
  Widget build(BuildContext context) {
    const width = 2.0;
    final light = width * response.factor(0);
    final hard = width * response.factor(1);
    final colour = Theme.of(context).colorScheme.onSurface;
    return ListTile(
      title: SizedBox(
        height: 48,
        child: CustomPaint(
          painter: _PressureLinePainter(response, colour),
          size: Size.infinite,
        ),
      ),
      subtitle: Text(
        'Example, a 2 pt pen: light press ${_pt(light)} pt · normal 2 pt · '
        'hard press ${_pt(hard)} pt',
      ),
    );
  }
}

class _PressureLinePainter extends CustomPainter {
  _PressureLinePainter(this.response, this.colour);

  final PressureResponse response;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    // A 6 px line (a 2 pt pen shown 3x bigger) as pressure rises from light
    // to hard.
    const steps = 40;
    final paint = Paint()
      ..color = colour
      ..strokeCap = StrokeCap.round;
    final y = size.height / 2;
    final left = 12.0, right = size.width - 12;
    for (var i = 0; i < steps; i++) {
      final p = (i + 0.5) / steps;
      paint.strokeWidth = 6 * response.factor(p);
      canvas.drawLine(
        Offset(left + (right - left) * i / steps, y),
        Offset(left + (right - left) * (i + 1) / steps, y),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_PressureLinePainter old) =>
      old.response != response || old.colour != colour;
}
