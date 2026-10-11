/// A user's correction of a recognised word (CLAUDE.md rule 4): what the
/// engine said, what the user meant, the word before it, and the raw
/// strokes, so future models can be trained from it. Pure Dart.
library;

import '../ink.dart';

/// Where a correction applies (owner: global by default; one PDF or a
/// group of PDFs later).
enum CorrectionScope { global, document }

class CorrectionRecord {
  const CorrectionRecord({
    required this.recognized,
    required this.corrected,
    required this.at,
    this.previousWord = '',
    this.strokes = const [],
    this.count = 1,
    this.scope = CorrectionScope.global,
    this.documentId,
  });

  /// What the engine read (before the feedback layer changed anything).
  final String recognized;

  /// What the user says it is.
  final String corrected;

  /// The word written just before, for context-aware matching.
  final String previousWord;

  /// The raw ink of the word (points with times and pressure).
  final List<InkStroke> strokes;

  /// How many times this same correction has been made.
  final int count;
  final DateTime at;
  final CorrectionScope scope;

  /// The PDF it was made in (and is limited to, for [CorrectionScope.document]).
  final String? documentId;
}
