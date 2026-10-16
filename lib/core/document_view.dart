/// How each document was last shown (owner: each document remembers its
/// zoom and place, last pen and colour, two-page view, labels, and typed
/// or handwritten view; a new document starts from Settings). Pure Dart.
library;

import 'dart:convert';

import 'pen_tools.dart';

class DocumentView {
  const DocumentView({
    this.page,
    this.pageX,
    this.pageY,
    this.zoomToFit,
    this.mode,
    this.pen,
    this.highlighter,
    this.twoPages,
    this.textLabels,
    this.textPanel,
    this.showTyped,
  });

  /// The page in the middle of the screen, and where on it the middle of
  /// the screen was (0..1 across and down), so it comes back the same
  /// whatever the screen's size.
  final int? page;
  final double? pageX, pageY;

  /// The zoom, as a share of the zoom that fills the screen (so turning
  /// the tablet doesn't change what it means).
  final double? zoomToFit;

  final PenMode? mode;
  final PenStyle? pen, highlighter;

  final bool? twoPages;

  /// Names of the settings' values (TextLabelPlace, TextPanelPlace).
  final String? textLabels, textPanel;

  final bool? showTyped;

  DocumentView copyWith({
    int? page,
    double? pageX,
    double? pageY,
    double? zoomToFit,
    PenMode? mode,
    PenStyle? pen,
    PenStyle? highlighter,
    bool? twoPages,
    String? textLabels,
    String? textPanel,
    bool? showTyped,
  }) => DocumentView(
    page: page ?? this.page,
    pageX: pageX ?? this.pageX,
    pageY: pageY ?? this.pageY,
    zoomToFit: zoomToFit ?? this.zoomToFit,
    mode: mode ?? this.mode,
    pen: pen ?? this.pen,
    highlighter: highlighter ?? this.highlighter,
    twoPages: twoPages ?? this.twoPages,
    textLabels: textLabels ?? this.textLabels,
    textPanel: textPanel ?? this.textPanel,
    showTyped: showTyped ?? this.showTyped,
  );

  /// [tools] with this document's own pen, highlighter and tool.
  PenToolsState applyTo(PenToolsState tools) => PenToolsState(
    mode: mode ?? tools.mode,
    pen: pen ?? tools.pen,
    highlighter: highlighter ?? tools.highlighter,
    dock: tools.dock,
    favourites: tools.favourites,
    favouritesX: tools.favouritesX,
    favouritesY: tools.favouritesY,
    eraser: tools.eraser,
    eraserSize: tools.eraserSize,
  );

  String toJson() => jsonEncode({
    if (page != null) 'p': page,
    if (pageX != null) 'x': pageX,
    if (pageY != null) 'y': pageY,
    if (zoomToFit != null) 'z': zoomToFit,
    if (mode != null) 'm': mode!.name,
    if (pen != null) 'pen': pen!.toJson(),
    if (highlighter != null) 'hi': highlighter!.toJson(),
    if (twoPages != null) 'two': twoPages,
    if (textLabels != null) 'labels': textLabels,
    if (textPanel != null) 'panel': textPanel,
    if (showTyped != null) 'typed': showTyped,
  });

  /// [json] from [toJson]; anything missing or unreadable is left unset
  /// (Settings decides).
  static DocumentView fromJson(String? json) {
    if (json == null) return const DocumentView();
    try {
      final j = jsonDecode(json) as Map<String, Object?>;
      double? d(String k) {
        final v = j[k];
        return v is num && v.isFinite ? v.toDouble() : null;
      }

      final m = j['m'] as String?;
      return DocumentView(
        page: j['p'] is int ? j['p']! as int : null,
        pageX: d('x')?.clamp(0.0, 1.0),
        pageY: d('y')?.clamp(0.0, 1.0),
        zoomToFit: d('z')?.clamp(0.1, 20.0),
        mode: PenMode.values.where((v) => v.name == m).firstOrNull,
        pen: PenStyle.fromJson(j['pen']),
        highlighter: PenStyle.fromJson(j['hi']),
        twoPages: j['two'] is bool ? j['two']! as bool : null,
        textLabels: j['labels'] as String?,
        textPanel: j['panel'] as String?,
        showTyped: j['typed'] is bool ? j['typed']! as bool : null,
      );
    } catch (_) {
      return const DocumentView();
    }
  }
}

/// Where each document's [DocumentView] is kept.
abstract class DocumentViewStore {
  Future<DocumentView> load(String documentId);
  Future<void> save(String documentId, DocumentView view);
}

/// A [DocumentViewStore] in memory (tests, or when the database can't
/// open).
class MemoryDocumentViewStore implements DocumentViewStore {
  final _views = <String, String>{};

  @override
  Future<DocumentView> load(String documentId) async =>
      DocumentView.fromJson(_views[documentId]);

  @override
  Future<void> save(String documentId, DocumentView view) async =>
      _views[documentId] = view.toJson();
}
