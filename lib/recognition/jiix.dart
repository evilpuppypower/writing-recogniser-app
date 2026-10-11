import '../core/recognition/recognizer.dart';

/// Turns MyScript's JIIX answer into candidates: the full text first, then
/// alternatives made by swapping in each word's next-best reading.
List<Candidate> jiixToCandidates(Map<String, Object?> jiix, {int max = 5}) {
  final label = (jiix['label'] as String?)?.trim() ?? '';
  if (label.isEmpty) return const [];
  final words = [
    for (final w in (jiix['words'] as List?) ?? const [])
      if (w is Map) w,
  ];
  final labels = [for (final w in words) '${w['label'] ?? ''}'];
  final result = <String>[label];
  for (var i = 0; i < words.length && result.length < max; i++) {
    final cands = [
      for (final c in (words[i]['candidates'] as List?) ?? const []) '$c',
    ];
    for (final c in cands) {
      if (result.length >= max) break;
      if (c == labels[i] || c.trim().isEmpty) continue;
      final alt = [...labels]..[i] = c;
      final text = alt.join().trim();
      if (!result.contains(text)) result.add(text);
    }
  }
  return [for (final t in result) Candidate(t)];
}
