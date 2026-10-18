/// The text-reading models for scanned PDFs (owner, 2026-10-17: download
/// whichever you want, with a quick button for the recommended one), from
/// assets/ocr_models.txt. Pure Dart.
library;

class OcrModelFile {
  const OcrModelFile(this.name, this.url, this.sha256);

  final String name, url;

  /// Pinned fingerprint; null if not pinned yet.
  final String? sha256;
}

class OcrModel {
  const OcrModel(this.id, this.name, this.files);

  final String id, name;
  final List<OcrModelFile> files;

  /// Every file's fingerprint is pinned, so it can be downloaded.
  bool get ready => files.isNotEmpty && files.every((f) => f.sha256 != null);
}

/// The model the quick button downloads.
const recommendedOcrModel = 'en-small';

/// [text] (lines "model | name | file | address | SHA-256", # comments) as
/// models, in the order they first appear. Lines that don't fit are left
/// out; only https addresses are kept.
List<OcrModel> parseOcrModels(String text) {
  final names = <String, String>{};
  final files = <String, List<OcrModelFile>>{};
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final p = line.split('|').map((s) => s.trim()).toList();
    if (p.length != 5) continue;
    final [id, name, file, url, sha] = p;
    if (id.isEmpty || file.isEmpty || !url.startsWith('https://')) continue;
    names.putIfAbsent(id, () => name);
    (files[id] ??= []).add(
      OcrModelFile(
        file,
        url,
        RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha) ? sha.toLowerCase() : null,
      ),
    );
  }
  return [for (final id in names.keys) OcrModel(id, names[id]!, files[id]!)];
}
