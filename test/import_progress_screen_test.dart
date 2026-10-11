import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/import/import_progress_screen.dart';
import 'package:writing_recogniser/import/pdf_import_channel.dart';

const mb = 1024 * 1024;

const pdf = PickedPdf(
  uri: 'content://test/doc.pdf',
  name: 'Lecture 3.pdf',
  size: 400 * mb,
  modified: 0,
  cacheId: '419430400_0_Lecture 3.pdf',
);

void main() {
  testWidgets('shows progress, then hands over the copied file', (
    tester,
  ) async {
    final done = Completer<String>();
    late void Function(int, int) report;
    String? openedPath;

    await tester.pumpWidget(
      MaterialApp(
        home: ImportProgressScreen(
          pdf: pdf,
          keep: 3,
          copy: (pdf, {required keep, required onProgress}) {
            report = onProgress;
            return done.future;
          },
          cancel: () async {},
          onDone: (context, path, took) => openedPath = path,
        ),
      ),
    );

    expect(find.text('Lecture 3.pdf'), findsOneWidget);
    expect(find.text('Estimating time left…'), findsOneWidget);

    report(100 * mb, 400 * mb);
    await tester.pump();
    expect(find.text('100 MB of 400 MB'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, closeTo(0.25, 1e-9));

    done.complete('/cache/imports/doc.pdf');
    await tester.pump();
    expect(openedPath, '/cache/imports/doc.pdf');
  });

  testWidgets('cancel asks the copier to stop and leaves the screen', (
    tester,
  ) async {
    final done = Completer<String>();
    var cancelCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ImportProgressScreen(
                  pdf: pdf,
                  keep: 3,
                  copy: (pdf, {required keep, required onProgress}) =>
                      done.future,
                  cancel: () async {
                    cancelCalls++;
                    done.completeError(const ImportCancelled());
                  },
                  onDone: (context, path, took) {},
                ),
              ),
            ),
            child: const Text('start'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('start'));
    await tester.pumpAndSettle();
    expect(find.text('Importing PDF'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(cancelCalls, 1);
    expect(find.text('Importing PDF'), findsNothing);
  });
}
