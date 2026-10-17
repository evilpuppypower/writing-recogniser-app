import 'package:flutter/services.dart';

/// Automatic backups: the folder (null if none, or it can't be written to
/// any more), every how many days (0 = off), how many are kept, and the
/// last one made or tried.
typedef AutoBackupStatus = ({
  String? folder,
  int everyDays,
  int keep,
  DateTime? lastAt,
  int bytes,
  DateTime? failedAt,
  String? error,
});

/// How a restore ended.
enum RestoreResult { ready, wrongKey, cancelled }

/// A backup file picked to restore from.
typedef PickedBackup = ({String uri, DateTime? created, int bytes});

/// How far a backup or restore is: "backup", "check" or "restore", and
/// bytes done of the total.
typedef BackupProgress = ({String phase, int done, int total});

/// Backups of everything, always encrypted (BackupChannel.kt). Behind an
/// interface so the screen can be tested without Android.
abstract class BackupService {
  Future<bool> isSetUp();

  /// Sets up (or changes) the password; the new recovery key to write down.
  Future<String> setUp(String password);

  /// Asks where to save a backup named [name], then saves and checks it.
  /// Its size in bytes, or null if cancelled.
  Future<int?> backUp(String name, {void Function(BackupProgress)? progress});

  /// Asks for a backup file; null if cancelled. Throws if it isn't one.
  Future<PickedBackup?> chooseBackup();

  /// Unpacks [backup] to be put in place when the app opens again.
  Future<RestoreResult> restore(
    PickedBackup backup, {
    String? password,
    String? recovery,
    void Function(BackupProgress)? progress,
  });

  Future<void> cancel();

  /// Closes and opens the app again, putting an unpacked restore in place.
  Future<void> restart();

  /// Forgets an unpacked restore: nothing changes.
  Future<void> discardRestore();

  /// Why the last restore couldn't be put in place (once), or null.
  Future<String?> restoreProblem();

  /// Asks for the folder for automatic backups; its name, or null.
  Future<String?> chooseFolder();

  /// Every [everyDays] days (0 = off), keeping the newest [keep].
  Future<void> setAuto({required int everyDays, required int keep});

  Future<AutoBackupStatus> autoStatus();

  /// An automatic backup now; false if stopped.
  Future<bool> backUpToFolder({void Function(BackupProgress)? progress});
}

class AndroidBackupService implements BackupService {
  const AndroidBackupService();

  static const _channel = MethodChannel('writing_recogniser/backup');
  static void Function(BackupProgress)? _progress;

  static void _listen(void Function(BackupProgress)? progress) {
    _progress = progress;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'progress') return;
      final a = (call.arguments as Map).cast<String, Object?>();
      _progress?.call((
        phase: a['phase']! as String,
        done: (a['done']! as num).toInt(),
        total: (a['total']! as num).toInt(),
      ));
    });
  }

  @override
  Future<bool> isSetUp() async =>
      await _channel.invokeMethod<bool>('isSetUp') ?? false;

  @override
  Future<String> setUp(String password) async =>
      (await _channel.invokeMethod<String>('setUp', {'password': password}))!;

  @override
  Future<int?> backUp(
    String name, {
    void Function(BackupProgress)? progress,
  }) async {
    _listen(progress);
    try {
      return await _channel.invokeMethod<int>('backUp', {
        'name': name,
        // In UTC, so the file says nothing about where it was made.
        'created': DateTime.now().toUtc().toIso8601String(),
        // The build's number only: its stamp also has the local time.
        'appBuild': const String.fromEnvironment('BUILD_STAMP')
            .split(' ')
            .first,
      });
    } finally {
      _progress = null;
    }
  }

  @override
  Future<PickedBackup?> chooseBackup() async {
    final m = await _channel.invokeMapMethod<String, Object?>('chooseBackup');
    if (m == null) return null;
    return (
      uri: m['uri']! as String,
      created: DateTime.tryParse(m['created'] as String? ?? '')?.toLocal(),
      bytes: (m['bytes'] as num?)?.toInt() ?? -1,
    );
  }

  @override
  Future<RestoreResult> restore(
    PickedBackup backup, {
    String? password,
    String? recovery,
    void Function(BackupProgress)? progress,
  }) async {
    _listen(progress);
    try {
      final r = await _channel.invokeMethod<String>('restore', {
        'uri': backup.uri,
        'password': ?password,
        'recovery': ?recovery,
      });
      return switch (r) {
        'ready' => RestoreResult.ready,
        'wrong' => RestoreResult.wrongKey,
        _ => RestoreResult.cancelled,
      };
    } finally {
      _progress = null;
    }
  }

  @override
  Future<void> cancel() => _channel.invokeMethod<void>('cancel');

  @override
  Future<void> restart() => _channel.invokeMethod<void>('restart');

  @override
  Future<void> discardRestore() =>
      _channel.invokeMethod<void>('discardRestore');

  @override
  Future<String?> restoreProblem() =>
      _channel.invokeMethod<String>('restoreProblem');

  @override
  Future<String?> chooseFolder() =>
      _channel.invokeMethod<String>('chooseFolder');

  @override
  Future<void> setAuto({required int everyDays, required int keep}) => _channel
      .invokeMethod<void>('setAuto', {'every': everyDays, 'keep': keep});

  @override
  Future<AutoBackupStatus> autoStatus() async {
    final m =
        await _channel.invokeMapMethod<String, Object?>('autoStatus') ??
        const {};
    DateTime? time(Object? v) =>
        v is String ? DateTime.tryParse(v)?.toLocal() : null;
    return (
      folder: m['folder'] as String?,
      everyDays: (m['every'] as num?)?.toInt() ?? 0,
      keep: (m['keep'] as num?)?.toInt() ?? 5,
      lastAt: time(m['at']),
      bytes: (m['bytes'] as num?)?.toInt() ?? 0,
      failedAt: time(m['failedAt']),
      error: m['error'] as String?,
    );
  }

  @override
  Future<bool> backUpToFolder({void Function(BackupProgress)? progress}) async {
    _listen(progress);
    try {
      return await _channel.invokeMethod<bool>('backUpToFolder') ?? false;
    } finally {
      _progress = null;
    }
  }
}
