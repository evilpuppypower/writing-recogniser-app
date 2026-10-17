import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/platform/backup_channel.dart';
import 'package:writing_recogniser/settings/backup_screen.dart';

class FakeBackups implements BackupService {
  bool setUpDone = false;
  String? password;
  final calls = <String>[];

  @override
  Future<bool> isSetUp() async => setUpDone;

  @override
  Future<String> setUp(String password) async {
    this.password = password;
    setUpDone = true;
    return 'ABCD-EFGH-JKMN-PQRS-TVWX-YZ01-2345-6789';
  }

  @override
  Future<int?> backUp(
    String name, {
    void Function(BackupProgress)? progress,
  }) async {
    calls.add('backUp $name');
    progress?.call((phase: 'backup', done: 50, total: 100));
    progress?.call((phase: 'check', done: 100, total: 100));
    return 3 * 1024 * 1024;
  }

  @override
  Future<PickedBackup?> chooseBackup() async =>
      (uri: 'content://x', created: DateTime(2026, 10, 1, 9, 30), bytes: 2048);

  @override
  Future<RestoreResult> restore(
    PickedBackup backup, {
    String? password,
    String? recovery,
    void Function(BackupProgress)? progress,
  }) async {
    calls.add('restore ${password ?? 'recovery:$recovery'}');
    if (password != null && password != 'right one') {
      return RestoreResult.wrongKey;
    }
    return RestoreResult.ready;
  }

  @override
  Future<void> cancel() async => calls.add('cancel');

  @override
  Future<void> restart() async => calls.add('restart');

  @override
  Future<void> discardRestore() async => calls.add('discard');

  @override
  Future<String?> restoreProblem() async => null;
}

void main() {
  testWidgets('set up: password twice, then the recovery key', (tester) async {
    final f = FakeBackups();
    BackupRecord? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: BackupScreen(
          service: f,
          loadRecord: () async => const BackupRecord(),
          saveRecord: (r) async => saved = r,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set up backups'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'short');
    await tester.enterText(
      find.widgetWithText(TextField, 'The same again'),
      'short',
    );
    await tester.tap(find.text('Next'));
    await tester.pump();
    expect(find.text('Use at least 8 characters.'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Password'),
      'long enough',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'The same again'),
      'long enougH',
    );
    await tester.tap(find.text('Next'));
    await tester.pump();
    expect(find.text("The two passwords aren't the same."), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'The same again'),
      'long enough',
    );
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(f.password, 'long enough');
    expect(
      find.text('ABCD-EFGH-JKMN-PQRS-TVWX-YZ01-2345-6789'),
      findsOneWidget,
    );
    // Done only once it's written down.
    final done = find.widgetWithText(FilledButton, 'Done');
    expect(tester.widget<FilledButton>(done).onPressed, isNull);
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(done);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Back up now'));
    await tester.pumpAndSettle();
    expect(f.calls.single, startsWith('backUp writing-recogniser-backup-'));
    expect(f.calls.single, endsWith('.wrbackup'));
    expect(saved!.bytes, 3 * 1024 * 1024);
    expect(find.textContaining('Backup saved and checked'), findsOneWidget);
    expect(find.textContaining('Last backup:'), findsOneWidget);
  });

  testWidgets('restore: a wrong password asks again, then restart', (
    tester,
  ) async {
    final f = FakeBackups()..setUpDone = true;
    await tester.pumpWidget(
      MaterialApp(
        home: BackupScreen(
          service: f,
          loadRecord: () async => const BackupRecord(),
          saveRecord: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore from a backup'));
    await tester.pumpAndSettle();
    expect(find.textContaining('replaced'), findsWidgets);
    await tester.enterText(find.byKey(const Key('restore-key')), 'wrong');
    await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
    await tester.pumpAndSettle();
    expect(
      find.text("That password doesn't open this backup."),
      findsOneWidget,
    );
    await tester.tap(find.text('Forgot the password? Use the recovery key'));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('restore-key')), 'abcd efgh');
    await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
    await tester.pumpAndSettle();
    expect(f.calls, ['restore wrong', 'restore recovery:abcd efgh']);
    // Leaving asks first: never left waiting.
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(nav.maybePop());
    await tester.pumpAndSettle();
    expect(find.text('Finish restoring?'), findsOneWidget);
    await tester.tap(find.text("Don't restore").last);
    await tester.pumpAndSettle();
    expect(f.calls.last, 'discard');
  });

  testWidgets('restore ready: restart puts it in place', (tester) async {
    final f = FakeBackups()..setUpDone = true;
    await tester.pumpWidget(
      MaterialApp(
        home: BackupScreen(
          service: f,
          loadRecord: () async => const BackupRecord(),
          saveRecord: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore from a backup'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('restore-key')), 'right one');
    await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restart the app now'));
    expect(f.calls.last, 'restart');
  });

  test('file names by date', () {
    expect(
      backupFileName(DateTime(2026, 3, 4, 5, 6)),
      'writing-recogniser-backup-20260304-0506.wrbackup',
    );
  });
}
