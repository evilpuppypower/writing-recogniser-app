/// How long a PDF took to open, from the tap to its first page being drawn,
/// so opening speed can be tracked for small and large PDFs (owner
/// request). Pure Dart; logged locally like every other event (CLAUDE.md
/// rule 5).
library;

import 'event_log.dart';
import 'latency.dart' show formatMs;
import 'transfer_estimate.dart' show formatBytes;

class OpenTiming {
  const OpenTiming({
    required this.at,
    required this.shownMs,
    required this.readyMs,
    required this.pages,
    required this.page,
    this.name = '',
    this.importMs,
    this.fileBytes,
  });

  /// Event type in the log.
  static const eventType = 'pdf_open';

  /// The PDF's file name.
  final String name;

  /// When the PDF was tapped.
  final DateTime at;

  /// Tap until the page it opened at was drawn and every page's size was
  /// read (the PDF is fully usable).
  final int shownMs;

  /// Tap until the PDF file was open (pages may still be loading).
  final int readyMs;

  /// Copying the file into the app first, when it was just imported
  /// (included in the other times).
  final int? importMs;

  final int? fileBytes;
  final int pages;

  /// The page it opened at.
  final int page;

  /// One line for the screen, e.g. "First page shown 2.31 s after tapping
  /// (import 1.20 s)".
  String describe() =>
      'First page shown ${formatMs(shownMs)} after tapping'
      '${importMs == null ? '' : ' (import ${formatMs(importMs!)})'}';

  /// One line for the list of past openings.
  String details() => [
    if (fileBytes != null) formatBytes(fileBytes!),
    '$pages ${pages == 1 ? 'page' : 'pages'}',
    'file open ${formatMs(readyMs)}',
    if (importMs != null) 'import ${formatMs(importMs!)}',
    if (page > 1) 'at page $page',
  ].join(' · ');

  LoggedEvent toEvent(String documentId) => LoggedEvent(
    type: eventType,
    at: at,
    latencyMs: shownMs,
    data: {
      'document': documentId,
      'name': name,
      'shownMs': shownMs,
      'readyMs': readyMs,
      'importMs': importMs,
      'fileBytes': fileBytes,
      'pages': pages,
      'page': page,
    },
  );

  /// Reads a logged opening back; null if it isn't one.
  static OpenTiming? fromEvent(LoggedEvent e) {
    final d = e.data;
    final shown = d['shownMs'], ready = d['readyMs'], pages = d['pages'];
    if (e.type != eventType || shown is! int || ready is! int) return null;
    if (pages is! int) return null;
    final page = d['page'], import = d['importMs'], bytes = d['fileBytes'];
    final name = d['name'];
    return OpenTiming(
      at: e.at,
      shownMs: shown,
      readyMs: ready,
      pages: pages,
      page: page is int ? page : 1,
      name: name is String ? name : '',
      importMs: import is int ? import : null,
      fileBytes: bytes is int ? bytes : null,
    );
  }

  /// [times] as a CSV spreadsheet (opens in Excel or Google Sheets), one
  /// row per opening, times in milliseconds.
  static String toCsv(List<OpenTiming> times) {
    String cell(Object? v) {
      final t = v?.toString() ?? '';
      return t.contains(RegExp('[",\n]')) ? '"${t.replaceAll('"', '""')}"' : t;
    }

    String two(int n) => n.toString().padLeft(2, '0');
    final rows = [
      'opened at,pdf,size (bytes),pages,opened at page,'
          'first page shown (ms),file open (ms),import (ms)',
      for (final t in times)
        [
          '${t.at.year}-${two(t.at.month)}-${two(t.at.day)} '
              '${two(t.at.hour)}:${two(t.at.minute)}:${two(t.at.second)}',
          t.name,
          t.fileBytes,
          t.pages,
          t.page,
          t.shownMs,
          t.readyMs,
          t.importMs,
        ].map(cell).join(','),
    ];
    return '${rows.join('\n')}\n';
  }
}
