/// Backup file for labelled handwriting samples: a .zip holding one
/// samples.json that keeps everything (text, strokes with time and pressure,
/// canvas size), so it can restore the samples on a tablet or be used later
/// to evaluate or train recognisers. A zip opens straight away on Windows
/// and Android (owner, 2026-10-11). Older .json.gz backups still restore.
/// Pure Dart.
library;

import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'ink.dart';
import 'labeled_sample.dart';

const sampleBackupFormat = 'writing-recogniser-samples';
const sampleBackupVersion = 1;

/// The JSON file inside the zip.
const sampleBackupEntry = 'samples.json';

/// Suggested file name, e.g. "handwriting-samples-20260101-1200.zip".
String sampleBackupFileName(DateTime now) {
  String two(int v) => v.toString().padLeft(2, '0');
  return 'handwriting-samples-${now.year}${two(now.month)}${two(now.day)}'
      '-${two(now.hour)}${two(now.minute)}.zip';
}

List<int> encodeSampleBackup(
  List<LabeledSample> samples, {
  required DateTime exportedAt,
  String appBuild = '',
}) {
  final doc = {
    'format': sampleBackupFormat,
    'version': sampleBackupVersion,
    'exportedAt': exportedAt.toIso8601String(),
    'appBuild': appBuild,
    // So the file explains itself to whoever uses it later.
    'units': {
      'x, y':
          'logical pixels from the top-left of the writing area '
          '(about 160 per inch)',
      't': 'milliseconds since 1970-01-01 UTC',
      'pressure': '0..1 (0.5 if the pen did not report it)',
      'stroke': 'list of [x, y, t, pressure] points, pen-down to pen-up',
      'hover':
          'list of [x, y, t] points where the pen hovered over the box '
          'without touching (may be empty)',
    },
    'samples': [
      for (final s in samples)
        {
          'text': s.text,
          'createdAt': s.createdAt.toIso8601String(),
          'canvasWidth': s.canvasWidth,
          'canvasHeight': s.canvasHeight,
          'strokes': strokesToJson(s.strokes),
          'hover': hoverToJson(s.hover),
        },
    ],
  };
  final json = utf8.encode(const JsonEncoder.withIndent(' ').convert(doc));
  return ZipEncoder().encodeBytes(
    Archive()..add(ArchiveFile.bytes(sampleBackupEntry, json)),
  );
}

class SampleBackupException implements Exception {
  const SampleBackupException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Largest backup file accepted, and the most its contents may unpack to,
/// so a huge or booby-trapped file (a "zip bomb") is refused instead of
/// using up the tablet's memory.
const maxBackupBytes = 200 * 1024 * 1024;
const maxBackupJsonBytes = 400 * 1024 * 1024;

const _tooBig = SampleBackupException('This backup is too big to open.');

/// The JSON text of a backup: inside a zip, gzip-compressed (older
/// backups), or plain.
List<int> _jsonBytes(List<int> bytes, int maxFile, int maxJson) {
  if (bytes.length > maxFile) throw _tooBig;
  final isZip =
      bytes.length > 3 &&
      bytes[0] == 0x50 &&
      bytes[1] == 0x4b &&
      bytes[2] == 0x03 &&
      bytes[3] == 0x04;
  if (isZip) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final entry =
        archive.findFile(sampleBackupEntry) ??
        archive.files
            .where((f) => f.isFile && f.name.endsWith('.json'))
            .firstOrNull;
    if (entry == null) throw const FormatException('no samples.json');
    // The size a zip declares can be a lie, so the unpacking itself stops
    // at the limit.
    if (entry.size > maxJson) throw _tooBig;
    final out = _CappedOutput(maxJson);
    entry.writeContent(out);
    return out.getBytes();
  }
  final isGzip = bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;
  return isGzip ? _gunzipCapped(bytes, maxJson) : bytes;
}

/// Unpacks gzip data, stopping as soon as it passes [limit] bytes.
List<int> _gunzipCapped(List<int> bytes, int limit) {
  final sink = _CappedSink(limit);
  gzip.decoder.startChunkedConversion(sink)
    ..add(bytes)
    ..close();
  return sink.bytes.takeBytes();
}

class _CappedOutput extends OutputMemoryStream {
  _CappedOutput(this.limit);

  final int limit;

  void _check(int more) {
    if (length + more > limit) throw _tooBig;
  }

  @override
  void writeByte(int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _check(stream.length);
    super.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _check(count);
    super.writeBackReference(distance, count);
  }
}

class _CappedSink implements Sink<List<int>> {
  _CappedSink(this.limit);

  final int limit;
  final bytes = BytesBuilder(copy: false);

  @override
  void add(List<int> chunk) {
    if (bytes.length + chunk.length > limit) throw _tooBig;
    bytes.add(chunk);
  }

  @override
  void close() {}
}

/// Reads a backup file (.zip, older .json.gz, or plain JSON). Samples come
/// back without database ids.
List<LabeledSample> decodeSampleBackup(
  List<int> bytes, {
  int maxFileBytes = maxBackupBytes,
  int maxJsonBytes = maxBackupJsonBytes,
}) {
  Object? doc;
  try {
    doc = jsonDecode(
      utf8.decode(_jsonBytes(bytes, maxFileBytes, maxJsonBytes)),
    );
  } on SampleBackupException {
    rethrow;
  } on Exception {
    throw const SampleBackupException(
      "This file isn't a handwriting samples backup.",
    );
  }
  if (doc is! Map || doc['format'] != sampleBackupFormat) {
    throw const SampleBackupException(
      "This file isn't a handwriting samples backup.",
    );
  }
  final version = doc['version'];
  if (version is! int || version > sampleBackupVersion) {
    throw const SampleBackupException(
      'This backup was made by a newer version of the app. Update the app '
      'first.',
    );
  }
  try {
    return [
      for (final s in (doc['samples'] as List))
        LabeledSample(
          text: (s as Map)['text'] as String,
          createdAt: DateTime.parse(s['createdAt'] as String),
          canvasWidth: (s['canvasWidth'] as num?)?.toDouble(),
          canvasHeight: (s['canvasHeight'] as num?)?.toDouble(),
          strokes: strokesFromJson(s['strokes'] as List),
          hover: s['hover'] is List
              ? hoverFromJson(s['hover'] as List)
              : const [],
        ),
    ];
  } catch (_) {
    throw const SampleBackupException('This backup file is damaged.');
  }
}

/// Samples from [incoming] that aren't already in [existing] (same text and
/// time), so restoring the same backup twice doesn't duplicate anything.
List<LabeledSample> newSamplesOnly(
  List<LabeledSample> existing,
  List<LabeledSample> incoming,
) {
  String key(LabeledSample s) =>
      '${s.createdAt.toUtc().microsecondsSinceEpoch}|${s.text}';
  final seen = {for (final s in existing) key(s)};
  return [
    for (final s in incoming)
      if (seen.add(key(s))) s,
  ];
}
