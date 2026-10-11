import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/event_log.dart';
import 'package:writing_recogniser/core/open_timing.dart';
import 'package:writing_recogniser/settings/open_times_screen.dart';

class _MemoryLog implements EventLog {
  final events = <LoggedEvent>[];

  @override
  Future<void> log(LoggedEvent event) async => events.add(event);

  @override
  Future<List<LoggedEvent>> ofType(String type) async =>
      events.where((e) => e.type == type).toList();
}

void main() {
  final big = OpenTiming(
    name: 'Textbook.pdf',
    at: DateTime(2026, 1, 1, 12, 0),
    shownMs: 4210,
    readyMs: 120,
    importMs: 2500,
    fileBytes: 400 * 1024 * 1024,
    pages: 812,
    page: 37,
  );

  test('describes the tap-to-first-page time', () {
    expect(
      big.describe(),
      'First page shown 4.21 s after tapping (import 2.50 s)',
    );
    expect(
      OpenTiming(
        at: DateTime(2026),
        shownMs: 640,
        readyMs: 90,
        pages: 1,
        page: 1,
      ).describe(),
      'First page shown 640 ms after tapping',
    );
    expect(big.details(), contains('812 pages'));
    expect(big.details(), contains('file open 120 ms'));
    expect(big.details(), contains('at page 37'));
  });

  test('round-trips through the event log', () {
    final e = big.toEvent('id-1');
    expect(e.type, OpenTiming.eventType);
    expect(e.latencyMs, 4210);
    expect(e.data['document'], 'id-1');
    final back = OpenTiming.fromEvent(e)!;
    expect(back.name, 'Textbook.pdf');
    expect(back.shownMs, 4210);
    expect(back.readyMs, 120);
    expect(back.importMs, 2500);
    expect(back.fileBytes, big.fileBytes);
    expect(back.pages, 812);
    expect(back.page, 37);
  });

  test('ignores other or damaged events', () {
    expect(
      OpenTiming.fromEvent(LoggedEvent(type: 'recognition', at: DateTime(0))),
      isNull,
    );
    expect(
      OpenTiming.fromEvent(
        LoggedEvent(
          type: OpenTiming.eventType,
          at: DateTime(0),
          data: const {'shownMs': 'soon'},
        ),
      ),
      isNull,
    );
  });

  testWidgets('opening times screen lists the newest first', (tester) async {
    final log = _MemoryLog();
    await log.log(
      OpenTiming(
        name: 'Small.pdf',
        at: DateTime(2026, 10, 11, 9),
        shownMs: 300,
        readyMs: 50,
        pages: 2,
        page: 1,
      ).toEvent('a'),
    );
    await log.log(big.toEvent('b'));
    await tester.pumpWidget(
      MaterialApp(home: OpenTimesScreen(openEventLog: () async => log)),
    );
    await tester.pumpAndSettle();
    expect(find.text('4.21 s'), findsOneWidget);
    expect(find.text('300 ms'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Textbook.pdf')).dy,
      lessThan(tester.getTopLeft(find.text('Small.pdf')).dy),
    );
  });

  testWidgets('says so when nothing has been opened', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: OpenTimesScreen(openEventLog: () async => _MemoryLog()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('No PDFs opened yet'), findsOneWidget);
  });

  test('exports as a CSV spreadsheet', () {
    final csv = OpenTiming.toCsv([
      big,
      OpenTiming(
        name: 'Notes, week 1.pdf',
        at: DateTime(2026, 1, 1, 10, 0, 7),
        shownMs: 300,
        readyMs: 50,
        pages: 2,
        page: 1,
      ),
    ]);
    final lines = csv.trim().split('\n');
    expect(lines, hasLength(3));
    expect(lines[0], startsWith('opened at,pdf,'));
    expect(
      lines[1],
      '2026-01-01 12:00:00,Textbook.pdf,${400 * 1024 * 1024},812,37,'
      '4210,120,2500',
    );
    expect(lines[2], '2026-01-01 10:00:07,"Notes, week 1.pdf",,2,1,300,50,');
  });

  testWidgets('the list can be saved as a spreadsheet', (tester) async {
    final log = _MemoryLog();
    await log.log(big.toEvent('b'));
    String? savedName;
    List<int>? savedBytes;
    await tester.pumpWidget(
      MaterialApp(
        home: OpenTimesScreen(
          openEventLog: () async => log,
          saveFile: (name, mime, bytes) async {
            savedName = name;
            savedBytes = bytes;
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Save the list as a spreadsheet (CSV)'));
    await tester.pumpAndSettle();
    expect(savedName, endsWith('.csv'));
    expect(utf8.decode(savedBytes!), contains('Textbook.pdf'));
  });
}
