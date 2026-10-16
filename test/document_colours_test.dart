import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:writing_recogniser/core/app_settings.dart';
import 'package:writing_recogniser/core/document_colours.dart';
import 'package:writing_recogniser/core/night_colours.dart';
import 'package:writing_recogniser/storage/app_database.dart';
import 'package:writing_recogniser/storage/sqlite_document_colours_store.dart';
import 'package:writing_recogniser/storage/sqlite_ink_store.dart';

void main() {
  test('each PDF keeps its own page colours, and they go with it', () async {
    final db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(db.close);
    final store = SqliteDocumentColoursStore(db);
    expect(await store.get('a'), isNull); // Settings decides
    await store.set('a', PageColours.dark);
    await store.set('b', PageColours.light);
    expect(await store.get('a'), PageColours.dark);
    await store.set('a', PageColours.light);
    expect(await store.get('a'), PageColours.light);
    await store.set('a', null);
    expect(await store.get('a'), isNull);
    await store.set('a', PageColours.dark);
    await SqliteInkStore(db).deleteDocument('a');
    expect(await store.get('a'), isNull);
    expect(await store.get('b'), PageColours.light);
  });

  test('the in-memory store works the same', () async {
    final store = MemoryDocumentColoursStore();
    await store.set('a', PageColours.dark);
    expect(await store.get('a'), PageColours.dark);
    await store.set('a', null);
    expect(await store.get('a'), isNull);
  });

  test('night colours (also used by the export) match the screen\'s', () {
    final rng = math.Random(3);
    for (var i = 0; i < 500; i++) {
      final argb = 0xFF000000 | rng.nextInt(0x1000000);
      final hsl = HSLColor.fromColor(Color(argb));
      final want = hsl.withLightness(1 - hsl.lightness).toColor().toARGB32();
      final got = nightArgb(argb);
      for (final shift in [16, 8, 0]) {
        expect(
          ((got >> shift & 0xFF) - (want >> shift & 0xFF)).abs(),
          lessThanOrEqualTo(1),
        );
      }
    }
    // Transparency is kept.
    expect(nightArgb(0x66000000) >> 24, 0x66);
  });
}
