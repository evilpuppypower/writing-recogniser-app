import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/stored_copy.dart' show formatDateTime;
import '../core/transfer_estimate.dart';
import '../platform/backup_channel.dart';

/// When the last backup was made, and its size (kept on the tablet).
class BackupRecord {
  const BackupRecord({this.at, this.bytes = 0});

  final DateTime? at;
  final int bytes;

  static const _atKey = 'backup.lastAt', _bytesKey = 'backup.lastBytes';

  static Future<BackupRecord> load() async {
    try {
      final prefs = SharedPreferencesAsync();
      return BackupRecord(
        at: DateTime.tryParse(await prefs.getString(_atKey) ?? '')?.toLocal(),
        bytes: await prefs.getInt(_bytesKey) ?? 0,
      );
    } catch (_) {
      return const BackupRecord();
    }
  }

  static Future<void> save(BackupRecord r) async {
    try {
      final prefs = SharedPreferencesAsync();
      await prefs.setString(_atKey, r.at!.toUtc().toIso8601String());
      await prefs.setInt(_bytesKey, r.bytes);
    } catch (_) {}
  }
}

/// The reminder on the home screen (owner: after 7 days without a backup,
/// made by hand or automatically). "Not now" waits another 7 days.
class BackupReminder {
  static const after = Duration(days: 7);
  static const _snoozeKey = 'backup.remindAfter';

  /// Whether it's time: no backup for [after], and not put off.
  static bool due({
    required DateTime now,
    DateTime? lastManual,
    DateTime? lastAuto,
    DateTime? snoozedUntil,
  }) {
    if (snoozedUntil != null && now.isBefore(snoozedUntil)) return false;
    final last = [lastManual, lastAuto].whereType<DateTime>().fold<DateTime?>(
      null,
      (a, b) => a == null || b.isAfter(a) ? b : a,
    );
    return last == null || now.difference(last) >= after;
  }

  static Future<bool> load({
    BackupService service = const AndroidBackupService(),
  }) async {
    final manual = await BackupRecord.load();
    DateTime? auto;
    try {
      auto = (await service.autoStatus()).lastAt;
    } catch (_) {}
    DateTime? snoozed;
    try {
      snoozed = DateTime.tryParse(
        await SharedPreferencesAsync().getString(_snoozeKey) ?? '',
      );
    } catch (_) {}
    return due(
      now: DateTime.now(),
      lastManual: manual.at,
      lastAuto: auto,
      snoozedUntil: snoozed?.toLocal(),
    );
  }

  static Future<void> snooze() async {
    try {
      await SharedPreferencesAsync().setString(
        _snoozeKey,
        DateTime.now().add(after).toUtc().toIso8601String(),
      );
    } catch (_) {}
  }
}

/// A backup's file name, by the local date and time it was made.
String backupFileName(DateTime now) {
  String two(int v) => v.toString().padLeft(2, '0');
  return 'writing-recogniser-backup-${now.year}${two(now.month)}'
      '${two(now.day)}-${two(now.hour)}${two(now.minute)}.wrbackup';
}

/// Settings → Backups (owner, 2026-10-16): everything, PDFs included,
/// always encrypted with a password, and a recovery key in case the
/// password is forgotten.
class BackupScreen extends StatefulWidget {
  const BackupScreen({
    super.key,
    this.service = const AndroidBackupService(),
    this.loadRecord = BackupRecord.load,
    this.saveRecord = BackupRecord.save,
  });

  final BackupService service;
  final Future<BackupRecord> Function() loadRecord;
  final Future<void> Function(BackupRecord) saveRecord;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  bool? _setUp;
  BackupRecord _record = const BackupRecord();

  /// What's running, if anything: its words, how far, time left.
  String? _busy;
  double? _fraction;
  Duration? _left;
  bool _cancellable = false;
  TransferEstimator? _estimate;
  String? _phase;
  DateTime _phaseStarted = DateTime.now();

  /// A restore is unpacked and waits for the app to open again.
  bool _restoreReady = false;

  BackupService get _s => widget.service;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final setUp = await _s.isSetUp().catchError((_) => false);
    final record = await widget.loadRecord();
    final auto = await _s
        .autoStatus()
        .then<AutoBackupStatus?>((a) => a)
        .catchError((_) => null);
    if (!mounted) return;
    setState(() {
      _setUp = setUp;
      _record = record;
      _auto = auto;
    });
  }

  /// Automatic backups, as last read.
  AutoBackupStatus? _auto;

  Future<void> _refreshAuto() async {
    final auto = await _s
        .autoStatus()
        .then<AutoBackupStatus?>((a) => a)
        .catchError((_) => null);
    if (mounted) setState(() => _auto = auto);
  }

  Future<void> _chooseFolder() async {
    try {
      await _s.chooseFolder();
    } catch (e) {
      _message("Couldn't use that folder: $e");
    }
    await _refreshAuto();
  }

  Future<void> _setAuto({int? everyDays, int? keep}) async {
    final a = _auto;
    try {
      await _s.setAuto(
        everyDays: everyDays ?? a?.everyDays ?? 0,
        keep: keep ?? a?.keep ?? 5,
      );
    } catch (e) {
      _message("Couldn't change automatic backups: $e");
    }
    await _refreshAuto();
  }

  Future<void> _backUpToFolder() async {
    _start('Backing up…', cancellable: true);
    try {
      await _s.backUpToFolder(progress: _onProgress);
    } catch (e) {
      _message("The backup couldn't be made: $e");
    }
    if (!mounted) return;
    _done();
    await _refreshAuto();
    final a = _auto;
    if (a?.lastAt != null &&
        DateTime.now().difference(a!.lastAt!).inMinutes < 2) {
      _message(
        'Backup saved in ${a.folder ?? 'the folder'} and checked'
        '${a.bytes > 0 ? ' (${formatBytes(a.bytes)})' : ''}.',
      );
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  void _onProgress(BackupProgress p) {
    if (!mounted) return;
    if (p.phase != _phase) {
      _phase = p.phase;
      _phaseStarted = DateTime.now();
      _estimate = TransferEstimator(totalBytes: p.total);
    }
    _estimate!.update(
      bytesDone: p.done,
      elapsed: DateTime.now().difference(_phaseStarted),
    );
    setState(() {
      _busy = switch (p.phase) {
        'check' => 'Checking the backup can be restored…',
        'restore' => 'Unpacking the backup…',
        _ => 'Backing up…',
      };
      _fraction = _estimate!.fraction;
      _left = _estimate!.remaining;
    });
  }

  void _start(String words, {bool cancellable = false}) => setState(() {
    _busy = words;
    _fraction = null;
    _left = null;
    _phase = null;
    _cancellable = cancellable;
  });

  void _done() => setState(() => _busy = null);

  // ---- Setting up ---------------------------------------------------------

  Future<void> _setUpPassword({required bool change}) async {
    final password = await showDialog<String>(
      context: context,
      builder: (_) => _PasswordDialog(change: change),
    );
    if (password == null || !mounted) return;
    _start('Locking the backups with your password…');
    String recovery;
    try {
      recovery = await _s.setUp(password);
    } catch (e) {
      if (mounted) _done();
      _message("Couldn't set up backups: $e");
      return;
    }
    if (!mounted) return;
    _done();
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RecoveryKeyDialog(recoveryKey: recovery),
    );
    if (!mounted) return;
    setState(() => _setUp = true);
  }

  // ---- Backing up ---------------------------------------------------------

  Future<void> _backUp() async {
    _start('Backing up…', cancellable: true);
    int? bytes;
    try {
      bytes = await _s.backUp(
        backupFileName(DateTime.now()),
        progress: _onProgress,
      );
    } catch (e) {
      if (mounted) _done();
      _message("The backup couldn't be made: $e");
      return;
    }
    if (!mounted) return;
    _done();
    if (bytes == null) return; // cancelled
    final record = BackupRecord(at: DateTime.now(), bytes: bytes);
    await widget.saveRecord(record);
    if (!mounted) return;
    setState(() => _record = record);
    _message(
      'Backup saved and checked'
      '${bytes > 0 ? ' (${formatBytes(bytes)})' : ''}.',
    );
  }

  // ---- Restoring ----------------------------------------------------------

  Future<void> _restore() async {
    PickedBackup? backup;
    try {
      backup = await _s.chooseBackup();
    } catch (e) {
      _message("That file isn't a backup from this app, or it can't be read.");
      return;
    }
    if (backup == null || !mounted) return;
    String? error;
    while (mounted) {
      final key = await showDialog<_Key>(
        context: context,
        builder: (_) => _RestoreDialog(backup: backup!, error: error),
      );
      if (key == null || !mounted) return;
      _start('Unpacking the backup…', cancellable: true);
      RestoreResult result;
      try {
        result = await _s.restore(
          backup,
          password: key.recovery ? null : key.text,
          recovery: key.recovery ? key.text : null,
          progress: _onProgress,
        );
      } catch (e) {
        if (mounted) _done();
        _message("The backup couldn't be restored: $e");
        return;
      }
      if (!mounted) return;
      _done();
      switch (result) {
        case RestoreResult.ready:
          setState(() => _restoreReady = true);
          return;
        case RestoreResult.cancelled:
          return;
        case RestoreResult.wrongKey:
          error = key.recovery
              ? "That recovery key doesn't open this backup."
              : "That password doesn't open this backup.";
      }
    }
  }

  // ---- Layout -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final setUp = _setUp;
    final busy = _busy;
    return PopScope(
      // A restore waiting to be put in place: put in place, or forgotten,
      // never left waiting (it would replace later work).
      canPop: !_restoreReady,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final restart = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Finish restoring?'),
            content: const Text(
              'The backup is ready. Restart the app to put it in place, or '
              'don\'t restore it and keep everything as it is.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Don\'t restore'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Restart the app now'),
              ),
            ],
          ),
        );
        if (restart == null || !context.mounted) return;
        if (restart) {
          await _s.restart();
        } else {
          await _s.discardRestore().catchError((_) {});
          if (!context.mounted) return;
          setState(() => _restoreReady = false);
          Navigator.of(context).pop();
        }
      },
      child: _scaffold(theme, setUp, busy),
    );
  }

  Widget _scaffold(ThemeData theme, bool? setUp, String? busy) {
    return Scaffold(
      appBar: AppBar(title: const Text('Backups')),
      body: setUp == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'A backup is one file holding everything: your PDFs and '
                  'notebooks, what you\'ve written, what the app has '
                  'learned, and your settings. It\'s always locked with '
                  'your password. Save it anywhere you like: this tablet, '
                  'a USB stick or a cloud folder.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                if (busy != null)
                  _ProgressCard(
                    words: busy,
                    fraction: _fraction,
                    left: _left,
                    onCancel: _cancellable ? () => _s.cancel() : null,
                  )
                else if (_restoreReady)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'The backup is ready. The app needs to close '
                            'and open again to put it in place.',
                          ),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            icon: const Icon(Icons.restart_alt),
                            label: const Text('Restart the app now'),
                            onPressed: () => _s.restart(),
                          ),
                          TextButton(
                            onPressed: () async {
                              await _s.discardRestore().catchError((_) {});
                              if (mounted) {
                                setState(() => _restoreReady = false);
                              }
                            },
                            child: const Text('Don\'t restore'),
                          ),
                        ],
                      ),
                    ),
                  )
                else if (!setUp) ...[
                  Text(
                    'First, choose a password for your backups. You\'ll also '
                    'get a recovery key, which opens them if you forget the '
                    'password. Without both, nobody can open your backups: '
                    'not you, and not the app\'s makers.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    icon: const Icon(Icons.lock_outline),
                    label: const Text('Set up backups'),
                    onPressed: () => _setUpPassword(change: false),
                  ),
                ] else ...[
                  Text(
                    _record.at == null
                        ? 'No backup made on this tablet yet.'
                        : 'Last backup: ${formatDateTime(_record.at!)}'
                              '${_record.bytes > 0 ? ' (${formatBytes(_record.bytes)})' : ''}',
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    icon: const Icon(Icons.backup_outlined),
                    label: const Text('Back up now'),
                    onPressed: _backUp,
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.password),
                    label: const Text('Change the password'),
                    onPressed: () => _setUpPassword(change: true),
                  ),
                  const SizedBox(height: 24),
                  const Divider(),
                  const SizedBox(height: 8),
                  _AutoBackups(
                    status: _auto,
                    onChooseFolder: _chooseFolder,
                    onEvery: (d) => _setAuto(everyDays: d),
                    onKeep: (k) => _setAuto(keep: k),
                    onNow: _backUpToFolder,
                  ),
                ],
                if (busy == null && !_restoreReady) ...[
                  const SizedBox(height: 24),
                  const Divider(),
                  const SizedBox(height: 8),
                  Text('Restore', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  const Text(
                    'Puts back everything from a backup, on this tablet or '
                    'a new one. What\'s on this tablet now is replaced.',
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.settings_backup_restore),
                    label: const Text('Restore from a backup'),
                    onPressed: _restore,
                  ),
                ],
              ],
            ),
    );
  }
}

/// Automatic backups: the folder, how often, how many are kept, and how
/// the last one went.
class _AutoBackups extends StatelessWidget {
  const _AutoBackups({
    required this.status,
    required this.onChooseFolder,
    required this.onEvery,
    required this.onKeep,
    required this.onNow,
  });

  final AutoBackupStatus? status;
  final VoidCallback onChooseFolder;
  final ValueChanged<int> onEvery;
  final ValueChanged<int> onKeep;
  final VoidCallback onNow;

  static const everyChoices = {
    0: 'Off',
    1: 'Every day',
    3: 'Every 3 days',
    7: 'Every week',
    14: 'Every 2 weeks',
  };
  static const keepChoices = [3, 5, 10];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = status;
    final folder = s?.folder;
    final every = everyChoices.containsKey(s?.everyDays) ? s!.everyDays : 0;
    final keep = keepChoices.contains(s?.keep) ? s!.keep : 5;
    final failedAt = s?.failedAt;
    final lastAt = s?.lastAt;
    final failedLast =
        failedAt != null && (lastAt == null || failedAt.isAfter(lastAt));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Automatic backups', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        const Text(
          'Made by themselves every few days, when the battery isn\'t low, '
          'into a folder you choose. It can be a cloud app\'s folder (such '
          'as Google Drive): that app then moves the file. The newest are '
          'kept and older ones removed.',
        ),
        const SizedBox(height: 8),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.folder_outlined),
          title: Text(folder ?? 'No folder chosen'),
          trailing: TextButton(
            onPressed: onChooseFolder,
            child: Text(folder == null ? 'Choose a folder' : 'Change'),
          ),
        ),
        if (folder == null && every > 0)
          Text(
            'The folder can\'t be used any more (it may have been removed). '
            'Choose a folder again, or turn automatic backups off.',
            style: TextStyle(color: theme.colorScheme.error),
          ),
        Row(
          children: [
            const Expanded(child: Text('How often')),
            DropdownButton<int>(
              value: every,
              items: [
                for (final e in everyChoices.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              // Can always be turned off, even if the folder's gone.
              onChanged: folder == null && every == 0
                  ? null
                  : (v) {
                      if (v != null) onEvery(v);
                    },
            ),
          ],
        ),
        Row(
          children: [
            const Expanded(child: Text('Backups kept in the folder')),
            DropdownButton<int>(
              value: keep,
              items: [
                for (final k in keepChoices)
                  DropdownMenuItem(value: k, child: Text('The newest $k')),
              ],
              onChanged: (v) {
                if (v != null) onKeep(v);
              },
            ),
          ],
        ),
        if (lastAt != null)
          Text(
            'Last automatic backup: ${formatDateTime(lastAt)}'
            '${(s?.bytes ?? 0) > 0 ? ' (${formatBytes(s!.bytes)})' : ''}',
          ),
        if (failedLast)
          Text(
            'The last try didn\'t work (${formatDateTime(failedAt)}): '
            '${s?.error ?? 'unknown reason'}',
            style: TextStyle(color: theme.colorScheme.error),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.drive_folder_upload_outlined),
          label: const Text('Back up to the folder now'),
          onPressed: folder == null ? null : onNow,
        ),
      ],
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({
    required this.words,
    required this.fraction,
    required this.left,
    this.onCancel,
  });

  final String words;
  final double? fraction;
  final Duration? left;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('$words${left == null ? '' : ' ${formatRemaining(left!)}'}'),
          const SizedBox(height: 12),
          LinearProgressIndicator(value: fraction),
          if (onCancel != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: onCancel, child: const Text('Stop')),
            ),
        ],
      ),
    ),
  );
}

/// Choosing the password (twice), with the warning in place.
class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({required this.change});

  final bool change;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _a = TextEditingController(), _b = TextEditingController();
  bool _show = false;
  String? _error;

  static const minLength = 8;

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  void _ok() {
    final a = _a.text, b = _b.text;
    if (a.length < minLength) {
      setState(() => _error = 'Use at least $minLength characters.');
    } else if (a != b) {
      setState(() => _error = "The two passwords aren't the same.");
    } else {
      Navigator.pop(context, a);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.change ? 'New backup password' : 'Backup password'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _a,
            obscureText: !_show,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Password',
              suffixIcon: IconButton(
                tooltip: _show ? 'Hide the password' : 'Show the password',
                icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _show = !_show),
              ),
            ),
          ),
          TextField(
            controller: _b,
            obscureText: !_show,
            decoration: const InputDecoration(labelText: 'The same again'),
            onSubmitted: (_) => _ok(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            widget.change
                ? 'New backups open with the new password, or the new '
                      'recovery key you\'ll get next. Backups made before '
                      'still open only with the old password or old '
                      'recovery key.'
                : 'If you forget this password and lose the recovery key, '
                      'your backups can\'t be opened by anyone.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _ok, child: const Text('Next')),
    ],
  );
}

/// The recovery key, to write down: Done only once the user says they
/// have.
class _RecoveryKeyDialog extends StatefulWidget {
  const _RecoveryKeyDialog({required this.recoveryKey});

  final String recoveryKey;

  @override
  State<_RecoveryKeyDialog> createState() => _RecoveryKeyDialogState();
}

class _RecoveryKeyDialogState extends State<_RecoveryKeyDialog> {
  bool _kept = false;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Your recovery key'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Write this down and keep it somewhere safe, away from the '
            'tablet. It opens your backups if you forget the password. It '
            'isn\'t shown again.',
          ),
          const SizedBox(height: 12),
          SelectableText(
            widget.recoveryKey,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          TextButton.icon(
            icon: const Icon(Icons.copy),
            label: const Text('Copy'),
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: widget.recoveryKey)),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _kept,
            onChanged: (v) => setState(() => _kept = v ?? false),
            title: const Text('I\'ve written it down or saved it safely'),
          ),
        ],
      ),
    ),
    actions: [
      FilledButton(
        onPressed: _kept ? () => Navigator.pop(context) : null,
        child: const Text('Done'),
      ),
    ],
  );
}

typedef _Key = ({String text, bool recovery});

/// Which backup, and the password (or recovery key) that opens it.
class _RestoreDialog extends StatefulWidget {
  const _RestoreDialog({required this.backup, this.error});

  final PickedBackup backup;
  final String? error;

  @override
  State<_RestoreDialog> createState() => _RestoreDialogState();
}

class _RestoreDialogState extends State<_RestoreDialog> {
  final _field = TextEditingController();
  bool _recovery = false;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _ok() {
    final t = _field.text.trim();
    if (t.isEmpty) return;
    Navigator.pop(context, (
      text: _recovery ? t : _field.text,
      recovery: _recovery,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.backup;
    return AlertDialog(
      title: const Text('Restore this backup?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Made ${b.created == null ? 'at an unknown time' : formatDateTime(b.created!)}'
              '${b.bytes > 0 ? ' · ${formatBytes(b.bytes)}' : ''}.\n'
              'Everything on this tablet now is replaced by what\'s in the '
              'backup. On a new tablet, enter your MyScript keys again '
              'afterwards.',
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('restore-key'),
              controller: _field,
              obscureText: !_recovery,
              autofocus: true,
              decoration: InputDecoration(
                labelText: _recovery ? 'Recovery key' : 'Backup password',
                errorText: widget.error,
              ),
              onSubmitted: (_) => _ok(),
            ),
            TextButton(
              onPressed: () => setState(() {
                _recovery = !_recovery;
                _field.clear();
              }),
              child: Text(
                _recovery
                    ? 'Use the password instead'
                    : 'Forgot the password? Use the recovery key',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _ok, child: const Text('Restore')),
      ],
    );
  }
}
