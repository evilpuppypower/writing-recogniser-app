import 'dart:convert';
import 'dart:io' show gzip;

import 'package:archive/archive.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/ink.dart';
import 'package:writing_recogniser/core/labeled_sample.dart';
import 'package:writing_recogniser/core/sample_backup.dart';
import 'package:writing_recogniser/core/sample_store.dart';
import 'package:writing_recogniser/handwriting/saved_samples_screen.dart';

class MemoryStore implements SampleStore {
  final samples = <LabeledSample>[];

  @override
  Future<int> add(LabeledSample s) async {
    samples.add(s);
    return samples.length;
  }

  @override
  Future<List<LabeledSample>> all() async => List.of(samples);

  @override
  Future<int> count() async => samples.length;

  @override
  Future<void> delete(int id) async {}
}

LabeledSample sample(String text, int minute) => LabeledSample(
  text: text,
  createdAt: DateTime.utc(2026, 1, 1, 12, minute),
  canvasWidth: 800,
  canvasHeight: 300,
  strokes: const [
    InkStroke([InkPoint(1.25, 2.5, 1000, 0.4), InkPoint(3, 4, 1016, 0.6)]),
    InkStroke([InkPoint(10, 20, 1200)]),
  ],
);

void main() {
  final when = DateTime(2026, 1, 1, 12, 0);

  group('backup file', () {
    test('round trip keeps text, time, canvas size and every point', () {
      final bytes = encodeSampleBackup([
        sample('hello', 1),
        sample('world', 2),
      ], exportedAt: when);
      expect(bytes.take(4), [0x50, 0x4b, 0x03, 0x04]); // zip
      final back = decodeSampleBackup(bytes);
      expect(back.map((s) => s.text), ['hello', 'world']);
      final s = back.first;
      expect(s.createdAt, DateTime.utc(2026, 1, 1, 12, 1));
      expect(s.canvasWidth, 800);
      expect(s.strokes, hasLength(2));
      final p = s.strokes.first.points.first;
      expect([p.x, p.y, p.t, p.pressure], [1.25, 2.5, 1000, 0.4]);
      expect(s.id, isNull);
    });

    test('pen hover survives a backup; older backups have none', () {
      final s = LabeledSample(
        text: 'h',
        strokes: sample('h', 1).strokes,
        createdAt: DateTime.utc(2026),
        hover: const [InkPoint(1, 2, 3, 0)],
      );
      final back = decodeSampleBackup(encodeSampleBackup([s], exportedAt: when))
          .single;
      expect(back.hover.single.x, 1);
      expect(back.hover.single.t, 3);
      expect(
        decodeSampleBackup(
          encodeSampleBackup([sample('a', 1)], exportedAt: when),
        ).single.hover,
        isEmpty,
      );
    });

    test('describes itself and its units', () {
      final doc = jsonDecode(
        utf8.decode(
          ZipDecoder()
              .decodeBytes(
                encodeSampleBackup(
                  [sample('a', 1)],
                  exportedAt: when,
                  appBuild: '2026-01-01 12:00',
                ),
              )
              .findFile(sampleBackupEntry)!
              .content,
        ),
      ) as Map;
      expect(doc['format'], sampleBackupFormat);
      expect(doc['version'], 1);
      expect(doc['appBuild'], '2026-01-01 12:00');
      expect((doc['units'] as Map).keys, contains('t'));
    });

    test('plain JSON and older .json.gz backups are accepted too', () {
      final json = ZipDecoder()
          .decodeBytes(encodeSampleBackup([sample('a', 1)], exportedAt: when))
          .findFile(sampleBackupEntry)!
          .content;
      expect(decodeSampleBackup(json).single.text, 'a');
      expect(decodeSampleBackup(gzip.encode(json)).single.text, 'a');
    });

    test('a zip without samples.json is rejected', () {
      final zip = ZipEncoder().encodeBytes(
        Archive()..add(ArchiveFile.string('notes.txt', 'hi')),
      );
      expect(
        () => decodeSampleBackup(zip),
        throwsA(isA<SampleBackupException>()),
      );
    });

    test('other files are rejected in plain language', () {
      expect(
        () => decodeSampleBackup(utf8.encode('%PDF-1.7')),
        throwsA(isA<SampleBackupException>()),
      );
      expect(
        () => decodeSampleBackup(utf8.encode('{"format":"something-else"}')),
        throwsA(isA<SampleBackupException>()),
      );
    });

    test('a backup from a newer app version is refused', () {
      final newer = utf8.encode(
        jsonEncode({
          'format': sampleBackupFormat,
          'version': 99,
          'samples': [],
        }),
      );
      expect(
        () => decodeSampleBackup(newer),
        throwsA(
          isA<SampleBackupException>().having(
            (e) => e.message,
            'message',
            contains('newer version'),
          ),
        ),
      );
    });

    test('restoring twice does not duplicate samples', () {
      final existing = [sample('hello', 1)];
      final incoming = [sample('hello', 1), sample('world', 2)];
      expect(newSamplesOnly(existing, incoming).map((s) => s.text), ['world']);
    });

    test('file name uses the date and time', () {
      expect(
        sampleBackupFileName(when),
        'handwriting-samples-20260101-1200.zip',
      );
    });
  });

  group('Saved samples screen', () {
    late MemoryStore store;
    List<int>? saved;
    String? savedName;
    List<int>? toOpen;

    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SavedSamplesScreen(
            store: store,
            now: () => when,
            saveFileAs: (name, mime, bytes) async {
              savedName = name;
              saved = bytes;
              return true;
            },
            openFile: (mimes) async => toOpen,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    setUp(() {
      store = MemoryStore();
      saved = null;
      savedName = null;
      toOpen = null;
    });

    testWidgets('back up writes every sample to the chosen file', (
      tester,
    ) async {
      store.samples.addAll([sample('hello', 1), sample('world', 2)]);
      await pump(tester);
      await tester.tap(find.byTooltip('Back up samples to a file'));
      await tester.pumpAndSettle();
      expect(savedName, 'handwriting-samples-20260101-1200.zip');
      expect(decodeSampleBackup(saved!).map((s) => s.text), ['hello', 'world']);
      expect(find.textContaining('Backed up 2 samples'), findsOneWidget);
    });

    testWidgets('back up with no samples says so', (tester) async {
      await pump(tester);
      await tester.tap(find.byTooltip('Back up samples to a file'));
      await tester.pumpAndSettle();
      expect(saved, isNull);
      expect(find.text('There are no samples to back up yet.'), findsOneWidget);
    });

    testWidgets('restore adds only new samples and lists them', (tester) async {
      store.samples.add(sample('hello', 1));
      toOpen = encodeSampleBackup([
        sample('hello', 1),
        sample('world', 2),
      ], exportedAt: when);
      await pump(tester);
      await tester.tap(find.byTooltip('Restore samples from a backup file'));
      await tester.pumpAndSettle();
      expect(store.samples.map((s) => s.text), ['hello', 'world']);
      expect(find.text('world'), findsOneWidget);
      expect(
        find.text('Restored 1 samples (1 were already here).'),
        findsOneWidget,
      );
    });

    testWidgets('restoring a wrong file explains the problem', (tester) async {
      toOpen = utf8.encode('not a backup');
      await pump(tester);
      await tester.tap(find.byTooltip('Restore samples from a backup file'));
      await tester.pumpAndSettle();
      expect(
        find.text("This file isn't a handwriting samples backup."),
        findsOneWidget,
      );
      expect(store.samples, isEmpty);
    });
  });

  group('size limits (a huge or booby-trapped file is refused)', () {
    Matcher tooBig() => throwsA(
      isA<SampleBackupException>().having(
        (e) => e.message,
        'message',
        contains('too big'),
      ),
    );

    test('a file over the size limit', () {
      expect(
        () => decodeSampleBackup(List.filled(2000, 32), maxFileBytes: 1000),
        tooBig(),
      );
    });

    test('a gzip that unpacks to more than the limit (zip bomb)', () {
      final bomb = gzip.encode(List.filled(100000, 32));
      expect(bomb.length, lessThan(1000));
      expect(() => decodeSampleBackup(bomb, maxJsonBytes: 50000), tooBig());
    });

    test('a zip that lies about its size is still stopped at the limit', () {
      final archive = Archive()
        ..addFile(ArchiveFile.bytes('samples.json', List.filled(100000, 32)));
      final zip = ZipEncoder().encodeBytes(archive);
      // Rewrite the declared (uncompressed) size in both headers to 10 bytes.
      final lied = List<int>.of(zip);
      void setSize(int at) {
        lied[at] = 10;
        lied[at + 1] = lied[at + 2] = lied[at + 3] = 0;
      }

      for (var i = 0; i + 4 < lied.length; i++) {
        if (lied[i] == 0x50 && lied[i + 1] == 0x4b) {
          if (lied[i + 2] == 3 && lied[i + 3] == 4) setSize(i + 22);
          if (lied[i + 2] == 1 && lied[i + 3] == 2) setSize(i + 24);
        }
      }
      expect(() => decodeSampleBackup(lied, maxJsonBytes: 50000), tooBig());
    });

    test('a zip whose samples.json unpacks to more than the limit', () {
      final archive = Archive()
        ..addFile(ArchiveFile.bytes('samples.json', List.filled(100000, 32)));
      final zip = ZipEncoder().encodeBytes(archive);
      expect(() => decodeSampleBackup(zip, maxJsonBytes: 50000), tooBig());
    });
  });
}
