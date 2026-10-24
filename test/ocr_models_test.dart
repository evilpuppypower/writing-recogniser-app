import 'dart:io' show File;
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/ocr_models.dart';
import 'package:writing_recogniser/platform/ocr_channel.dart';
import 'package:writing_recogniser/settings/ocr_models_screen.dart';

final _sha = 'A' * 64;

class _FakeReader implements TextReaderService {
  final installedIds = <String>{};
  final sums = <String, Map<String, String>>{};
  final downloads = <String>[];
  Completer<void>? pending;
  void Function(int, int)? progress;
  bool cancelled = false;

  @override
  Future<Set<String>> installed() async => {...installedIds};

  @override
  Future<Map<String, Map<String, String>>> fingerprints() async => {...sums};

  @override
  Future<void> download(
    OcrModel model, {
    void Function(int done, int total)? progress,
  }) async {
    downloads.add(model.id);
    this.progress = progress;
    final c = pending = Completer<void>();
    await c.future;
    installedIds.add(model.id);
    sums[model.id] = {for (final f in model.files) f.name: f.sha256!};
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
    pending?.completeError(Exception('stopped'));
  }

  @override
  Future<void> remove(String id) async => installedIds.remove(id);

  @override
  Future<List<OcrLine>> read(String id, int w, int h, Uint8List rgba) async =>
      const [];
}

void main() {
  group('parseOcrModels', () {
    test('groups files by model, in order, and pins fingerprints', () {
      final models = parseOcrModels('''
# a comment
a|Model A|det.onnx|https://x/det|$_sha
a|Model A|rec.onnx|https://x/rec|$_sha
b|Model B|det.onnx|https://x/det2|
''');
      expect(models.map((m) => m.id), ['a', 'b']);
      expect(models[0].name, 'Model A');
      expect(models[0].files.map((f) => f.name), ['det.onnx', 'rec.onnx']);
      expect(models[0].files.first.sha256, 'a' * 64);
      expect(models[0].ready, isTrue);
      expect(models[1].files.single.sha256, isNull);
      expect(models[1].ready, isFalse);
    });

    test('leaves out lines that do not fit, and non-https addresses', () {
      final models = parseOcrModels('''
a|A|det.onnx|http://x/det|$_sha
b|B|det.onnx|https://x/det
c|C|det.onnx|https://x/det|not-a-hash
|D|det.onnx|https://x/det|$_sha
''');
      expect(models.map((m) => m.id), ['c']);
      expect(models.single.ready, isFalse);
    });

    test('the bundled list parses and has the recommended model', () async {
      // Read as a file: the list is checked, not only the parser.
      final text = await _bundled();
      final models = parseOcrModels(text);
      expect(models.map((m) => m.id), contains(recommendedOcrModel));
      for (final m in models) {
        expect(m.files.map((f) => f.name).toSet(), {
          'det.onnx',
          'rec.onnx',
          'dict.txt',
        });
        // From this repo's own release (owner, 2026-10-23).
        for (final f in m.files) {
          expect(
            f.url,
            startsWith(
              'https://github.com/evilpuppypower/writing-recogniser-app/'
              'releases/download/ocr-models-1/',
            ),
          );
        }
        // Every file's fingerprint is pinned, so each model can be
        // downloaded.
        expect(m.ready, isTrue, reason: m.id);
      }
    });
  });

  test('the smaller model uses the mobile text finder, the larger the '
      'server one, with the same reader', () async {
    final models = {for (final m in parseOcrModels(await _bundled())) m.id: m};
    String url(String id, String file) =>
        models[id]!.files.firstWhere((f) => f.name == file).url;
    expect(
      url('en-small', 'det.onnx'),
      endsWith('/det-PP-OCRv5_mobile_det.onnx'),
    );
    expect(
      url('en-best', 'det.onnx'),
      endsWith('/det-PP-OCRv5_server_det.onnx'),
    );
    for (final file in ['rec.onnx', 'dict.txt']) {
      expect(url('en-small', file), url('en-best', file));
    }
  });

  group('OcrModel.matches', () {
    final m = OcrModel('a', 'A', [
      OcrModelFile('det.onnx', 'https://x/det', 'a' * 64),
      OcrModelFile('rec.onnx', 'https://x/rec', 'b' * 64),
    ]);
    test('the same files and fingerprints match, in any case', () {
      expect(m.matches({'det.onnx': 'A' * 64, 'rec.onnx': 'b' * 64}), isTrue);
    });
    test('a different, missing or extra file does not', () {
      expect(m.matches({'det.onnx': 'c' * 64, 'rec.onnx': 'b' * 64}), isFalse);
      expect(m.matches({'det.onnx': 'a' * 64}), isFalse);
      expect(
        m.matches({
          'det.onnx': 'a' * 64,
          'rec.onnx': 'b' * 64,
          'x.txt': 'd' * 64,
        }),
        isFalse,
      );
    });
    test('an unpinned model matches nothing', () {
      const u = OcrModel('u', 'U', [
        OcrModelFile('det.onnx', 'https://x', null),
      ]);
      expect(u.matches({'det.onnx': 'a' * 64}), isFalse);
    });
  });

  group('OcrModelsScreen', () {
    late _FakeReader reader;
    String? saved;

    Widget screen(List<OcrModel> models, {String? choice}) => MaterialApp(
      home: OcrModelsScreen(
        reader: reader,
        catalogue: () async => models,
        loadChoice: () async => choice,
        saveChoice: (id) async => saved = id,
      ),
    );

    setUp(() {
      reader = _FakeReader();
      saved = null;
    });

    final ready = OcrModel(recommendedOcrModel, 'Small', [
      OcrModelFile('det.onnx', 'https://x/det', 'a' * 64),
    ]);
    const unpinned = OcrModel('big', 'Big', [
      OcrModelFile('det.onnx', 'https://x/det2', null),
    ]);

    testWidgets('quick button downloads the recommended model and uses it', (
      tester,
    ) async {
      await tester.pumpWidget(screen([ready, unpinned]));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download Small'));
      await tester.pump();
      expect(reader.downloads, [recommendedOcrModel]);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      reader.progress!(50, 100);
      await tester.pump();
      reader.pending!.complete();
      await tester.pumpAndSettle();
      expect(saved, recommendedOcrModel);
      expect(find.text('Downloaded · in use'), findsOneWidget);
      expect(find.text('Download Small'), findsNothing);
    });

    testWidgets('an unpinned model cannot be downloaded', (tester) async {
      await tester.pumpWidget(screen([ready, unpinned]));
      await tester.pumpAndSettle();
      expect(
        find.text('Not available yet (its files are still being checked)'),
        findsOneWidget,
      );
      final button = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.download).last,
      );
      expect(button.tooltip, 'Download Big');
      expect(button.onPressed, isNull);
    });

    testWidgets('Stop cancels a download quietly', (tester) async {
      await tester.pumpWidget(screen([ready]));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download Small'));
      await tester.pump();
      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();
      expect(reader.cancelled, isTrue);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('Download Small'), findsOneWidget);
      expect(saved, isNull);
    });

    testWidgets('leaving the screen stops a download', (tester) async {
      await tester.pumpWidget(screen([ready]));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download Small'));
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpAndSettle();
      expect(reader.cancelled, isTrue);
    });

    testWidgets('only models in the list count as downloaded', (tester) async {
      reader.installedIds.add('something-else');
      await tester.pumpWidget(screen([ready]));
      await tester.pumpAndSettle();
      expect(find.text('Not downloaded'), findsOneWidget);
      expect(find.text('Download Small'), findsOneWidget);
    });

    testWidgets('a downloaded model with older files can be updated', (
      tester,
    ) async {
      reader.installedIds.add(recommendedOcrModel);
      reader.sums[recommendedOcrModel] = {'det.onnx': 'f' * 64};
      await tester.pumpWidget(screen([ready], choice: recommendedOcrModel));
      await tester.pumpAndSettle();
      expect(
        find.text('Downloaded · in use · a newer copy is available'),
        findsOneWidget,
      );
      expect(find.byTooltip('Update Small'), findsOneWidget);
      await tester.tap(find.text('Update Small'));
      await tester.pump();
      expect(reader.downloads, [recommendedOcrModel]);
      reader.pending!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Small is updated.'), findsOneWidget);
      expect(find.text('Downloaded · in use'), findsOneWidget);
      expect(find.text('Update Small'), findsNothing);
    });

    testWidgets('a model whose files are not known is not offered an update', (
      tester,
    ) async {
      reader.installedIds.add(recommendedOcrModel);
      await tester.pumpWidget(screen([ready], choice: recommendedOcrModel));
      await tester.pumpAndSettle();
      expect(find.text('Downloaded · in use'), findsOneWidget);
      expect(find.byTooltip('Update Small'), findsNothing);
    });

    testWidgets('removing the model in use clears the choice', (tester) async {
      reader.installedIds.add(recommendedOcrModel);
      await tester.pumpWidget(screen([ready], choice: recommendedOcrModel));
      await tester.pumpAndSettle();
      expect(find.text('Downloaded · in use'), findsOneWidget);
      await tester.tap(find.byTooltip('Remove Small'));
      await tester.pumpAndSettle();
      expect(reader.installedIds, isEmpty);
      expect(saved, isNull);
      expect(find.text('Not downloaded'), findsOneWidget);
    });
  });
}

Future<String> _bundled() => File('assets/ocr_models.txt').readAsString();
