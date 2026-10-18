/// One stroke as compact bytes, for saving stroke by stroke (owner,
/// 2026-10-18: a busy page was saved as several MB of text after every
/// stroke). Keeps exactly what the JSON form keeps: positions to 0.01 pt,
/// pressure to 0.001, times to the millisecond, and every other field.
/// Pure Dart.
///
/// Layout (little-endian): format (1 byte, 1), time width (1 byte, 4 or
/// 8), the other fields as UTF-8 JSON (length, 4 bytes, then the text),
/// the point count (4 bytes), the first point's time (8 bytes, if any
/// points), then per point: x and y in hundredths of a point (4 bytes
/// each), time after the first point (4 or 8 bytes), pressure in
/// thousandths (2 bytes).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'page_ink.dart';

const _format = 1;

Uint8List encodeStroke(PageStroke s) {
  final meta = utf8.encode(jsonEncode(s.toJson()..remove('points')));
  final pts = s.points;
  final t0 = pts.isEmpty ? 0 : pts.first.t;
  var wide = false;
  for (final p in pts) {
    final d = p.t - t0;
    if (d < -0x80000000 || d > 0x7FFFFFFF) {
      wide = true;
      break;
    }
  }
  final tw = wide ? 8 : 4;
  final size =
      2 + 4 + meta.length + 4 + (pts.isEmpty ? 0 : 8) + pts.length * (10 + tw);
  final b = ByteData(size);
  var o = 0;
  b.setUint8(o++, _format);
  b.setUint8(o++, tw);
  b.setUint32(o, meta.length, Endian.little);
  o += 4;
  final bytes = b.buffer.asUint8List();
  bytes.setRange(o, o + meta.length, meta);
  o += meta.length;
  b.setUint32(o, pts.length, Endian.little);
  o += 4;
  if (pts.isNotEmpty) {
    b.setInt64(o, t0, Endian.little);
    o += 8;
  }
  for (final p in pts) {
    b.setInt32(o, (p.x * 100).round(), Endian.little);
    b.setInt32(o + 4, (p.y * 100).round(), Endian.little);
    o += 8;
    if (wide) {
      b.setInt64(o, p.t - t0, Endian.little);
    } else {
      b.setInt32(o, p.t - t0, Endian.little);
    }
    o += tw;
    b.setUint16(o, (p.pressure.clamp(0.0, 1.0) * 1000).round(), Endian.little);
    o += 2;
  }
  return bytes;
}

/// The stroke [encodeStroke] made; throws [FormatException] if [bytes]
/// aren't one.
PageStroke decodeStroke(Uint8List bytes) {
  final b = ByteData.sublistView(bytes);
  if (bytes.length < 10 || b.getUint8(0) != _format) {
    throw const FormatException('not a saved stroke');
  }
  final tw = b.getUint8(1);
  if (tw != 4 && tw != 8) throw const FormatException('not a saved stroke');
  var o = 2;
  final metaLength = b.getUint32(o, Endian.little);
  o += 4;
  if (o + metaLength + 4 > bytes.length) {
    throw const FormatException('saved stroke cut short');
  }
  final meta = (jsonDecode(
    utf8.decode(bytes.sublist(o, o + metaLength)),
  ) as Map).cast<String, Object?>();
  o += metaLength;
  final n = b.getUint32(o, Endian.little);
  o += 4;
  if (n > 0 && o + 8 + n * (10 + tw) > bytes.length) {
    throw const FormatException('saved stroke cut short');
  }
  final points = <PageInkPoint>[];
  if (n > 0) {
    final t0 = b.getInt64(o, Endian.little);
    o += 8;
    for (var i = 0; i < n; i++) {
      final x = b.getInt32(o, Endian.little) / 100;
      final y = b.getInt32(o + 4, Endian.little) / 100;
      o += 8;
      final dt = tw == 8
          ? b.getInt64(o, Endian.little)
          : b.getInt32(o, Endian.little);
      o += tw;
      final pressure = b.getUint16(o, Endian.little) / 1000;
      o += 2;
      points.add(PageInkPoint(x, y, t0 + dt, pressure));
    }
  }
  return PageStroke.fromJson({...meta, 'points': const []})
      .copyWith(points: points);
}
