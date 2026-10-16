/// A PDF of empty pages (owner: blank pages to write on). The viewer shows
/// its pages between the PDF's own; nothing is drawn on them (paper lines
/// are drawn by the app, and written into exports). Pure Dart.
library;

import 'dart:convert';
import 'dart:typed_data';

/// A PDF with one empty page per entry of [sizes] (width, height in
/// points).
Uint8List blankPdf(List<(double, double)> sizes) {
  if (sizes.isEmpty) throw ArgumentError('no pages');
  final out = BytesBuilder(copy: false);
  final offsets = <int>[];
  var length = 0;
  void write(String s) {
    final b = latin1.encode(s);
    out.add(b);
    length += b.length;
  }

  String n(double v) => v.toStringAsFixed(2);
  write('%PDF-1.4\n');
  // 1: catalog, 2: page tree, 3...: pages.
  final kids = [for (var i = 0; i < sizes.length; i++) '${i + 3} 0 R'];
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [${kids.join(' ')}] /Count ${sizes.length} >>',
    for (final (w, h) in sizes)
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${n(w)} ${n(h)}] '
          '/Resources << >> >>',
  ];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(length);
    write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = length;
  write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final o in offsets) {
    write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
    'startxref\n$xref\n%%EOF\n',
  );
  return out.toBytes();
}
