/// Pen tools for writing on PDFs (task 1.2b): pen and highlighter styles,
/// the eraser, where the toolbar is docked, and pinned favourite pens.
/// Pure Dart so it can be tested and reused on Windows.
library;

import 'page_ink.dart';
import 'pressure_response.dart';

export 'pressure_response.dart';

/// What the pen tip does.
enum PenMode {
  pen,
  highlighter,
  eraser,

  /// Draw a loop around handwriting to select it (task 2.3c).
  lasso,

  /// Tap the page to place a typed text box, or tap one to edit it
  /// (owner's choice, 2026-10-15).
  text,
}

/// How the eraser works (owner: both, switchable).
enum EraserKind {
  stroke('Erase whole strokes'),
  area('Erase only where I rub');

  const EraserKind(this.label);
  final String label;
}

/// Where the fixed toolbar sits (owner: like common note apps, movable between
/// the top and the sides).
enum ToolbarDock {
  top('Top'),
  left('Left side'),
  right('Right side');

  const ToolbarDock(this.label);
  final String label;
}

/// One pen: tool, colour and width (in PDF points at normal pressure).
class PenStyle {
  const PenStyle({
    required this.tool,
    required this.colorArgb,
    required this.width,
    this.arrow = false,
  });

  final InkTool tool;
  final int colorArgb;
  final double width;

  /// Pen strokes end with an arrowhead (pen only).
  final bool arrow;

  static const minPenWidth = 0.3;
  static const maxPenWidth = 6.0;
  static const minHighlighterWidth = 4.0;
  static const maxHighlighterWidth = 24.0;

  static const defaultPen = PenStyle(
    tool: InkTool.pen,
    colorArgb: 0xFF1A1A1A,
    width: 1.2,
  );
  static const defaultHighlighter = PenStyle(
    tool: InkTool.highlighter,
    colorArgb: 0xFFFFEB3B,
    width: 10,
  );

  double get minWidth =>
      tool == InkTool.pen ? minPenWidth : minHighlighterWidth;
  double get maxWidth =>
      tool == InkTool.pen ? maxPenWidth : maxHighlighterWidth;

  PenStyle copyWith({int? colorArgb, double? width, bool? arrow}) => PenStyle(
    tool: tool,
    colorArgb: colorArgb ?? this.colorArgb,
    width: (width ?? this.width).clamp(minWidth, maxWidth),
    arrow: tool == InkTool.pen && (arrow ?? this.arrow),
  );

  Map<String, Object?> toJson() => {
    'tool': tool.name,
    'color': colorArgb,
    'width': width,
    if (arrow) 'arrow': true,
  };

  static PenStyle? fromJson(Object? j) {
    if (j is! Map) return null;
    final tool = InkTool.values.asNameMap()[j['tool']];
    final color = j['color'];
    final width = j['width'];
    if (tool == null || color is! num || width is! num) return null;
    return PenStyle(
      tool: tool,
      colorArgb: color.toInt(),
      width: width.toDouble(),
      arrow: j['arrow'] == true,
    ).copyWith(); // clamps the width
  }

  @override
  bool operator ==(Object other) =>
      other is PenStyle &&
      other.tool == tool &&
      other.colorArgb == colorArgb &&
      other.width == width &&
      other.arrow == arrow;

  @override
  int get hashCode => Object.hash(tool, colorArgb, width, arrow);
}

/// Colours offered in the pen settings (note-app basics).
const penColours = <int>[
  0xFF1A1A1A, // black
  0xFF5F6368, // grey
  0xFF1565C0, // blue
  0xFF0097A7, // teal
  0xFF2E7D32, // green
  0xFFC62828, // red
  0xFFEF6C00, // orange
  0xFF6A1B9A, // purple
];

const highlighterColours = <int>[
  0xFFFFEB3B, // yellow
  0xFF76FF03, // green
  0xFF40C4FF, // blue
  0xFFFF80AB, // pink
  0xFFFFAB40, // orange
];

/// Everything the toolbar remembers between sessions.
class PenToolsState {
  const PenToolsState({
    this.mode = PenMode.pen,
    this.pen = PenStyle.defaultPen,
    this.highlighter = PenStyle.defaultHighlighter,
    this.dock = ToolbarDock.top,
    this.favourites = const [],
    this.favouritesX = 0.5,
    this.favouritesY = 0.85,
    this.eraser = EraserKind.stroke,
    this.eraserSize = 8,
  });

  final PenMode mode;
  final PenStyle pen;
  final PenStyle highlighter;
  final ToolbarDock dock;

  /// Pens pinned to the floating favourites bar, in order.
  final List<PenStyle> favourites;

  /// Where the favourites bar floats, as fractions of the viewer (0..1).
  final double favouritesX;
  final double favouritesY;

  /// Whole strokes or only where the eraser touches.
  final EraserKind eraser;

  /// Eraser radius in screen pixels at normal zoom.
  final double eraserSize;

  static const minEraserSize = 4.0;
  static const maxEraserSize = 40.0;

  static const maxFavourites = 8;

  /// The style the pen tip draws with now (null while erasing).
  PenStyle? get current => switch (mode) {
    PenMode.pen => pen,
    PenMode.highlighter => highlighter,
    PenMode.eraser || PenMode.lasso || PenMode.text => null,
  };

  PenToolsState copyWith({
    PenMode? mode,
    PenStyle? pen,
    PenStyle? highlighter,
    ToolbarDock? dock,
    List<PenStyle>? favourites,
    double? favouritesX,
    double? favouritesY,
    EraserKind? eraser,
    double? eraserSize,
  }) => PenToolsState(
    mode: mode ?? this.mode,
    pen: pen ?? this.pen,
    highlighter: highlighter ?? this.highlighter,
    dock: dock ?? this.dock,
    favourites: favourites ?? this.favourites,
    favouritesX: (favouritesX ?? this.favouritesX).clamp(0.0, 1.0),
    favouritesY: (favouritesY ?? this.favouritesY).clamp(0.0, 1.0),
    eraser: eraser ?? this.eraser,
    eraserSize: (eraserSize ?? this.eraserSize).clamp(
      minEraserSize,
      maxEraserSize,
    ),
  );

  /// Changes the current pen or highlighter (not the eraser).
  PenToolsState withCurrent(PenStyle style) => style.tool == InkTool.pen
      ? copyWith(pen: style, mode: PenMode.pen)
      : copyWith(highlighter: style, mode: PenMode.highlighter);

  bool isFavourite(PenStyle style) => favourites.contains(style);

  /// Pins [style] to the favourites bar (no duplicates, up to
  /// [maxFavourites]; the oldest pin makes room).
  PenToolsState pin(PenStyle style) {
    if (isFavourite(style)) return this;
    final list = [...favourites, style];
    return copyWith(
      favourites: list.length > maxFavourites
          ? list.sublist(list.length - maxFavourites)
          : list,
    );
  }

  PenToolsState unpin(PenStyle style) =>
      copyWith(favourites: [...favourites]..remove(style));

  Map<String, Object?> toJson() => {
    // The lasso is for one job at a time: reopen with the pen.
    'mode': (mode == PenMode.lasso || mode == PenMode.text ? PenMode.pen : mode)
        .name,
    'pen': pen.toJson(),
    'highlighter': highlighter.toJson(),
    'dock': dock.name,
    'favourites': [for (final f in favourites) f.toJson()],
    'favouritesX': favouritesX,
    'favouritesY': favouritesY,
    'eraser': eraser.name,
    'eraserSize': eraserSize,
  };

  /// Reads [toJson] output; anything missing or unreadable falls back to
  /// the defaults.
  factory PenToolsState.fromJson(Object? j) {
    if (j is! Map) return const PenToolsState();
    final pen = PenStyle.fromJson(j['pen']);
    final hi = PenStyle.fromJson(j['highlighter']);
    return PenToolsState(
      mode: PenMode.values.asNameMap()[j['mode']] ?? PenMode.pen,
      pen: pen?.tool == InkTool.pen ? pen! : PenStyle.defaultPen,
      highlighter: hi?.tool == InkTool.highlighter
          ? hi!
          : PenStyle.defaultHighlighter,
      dock: ToolbarDock.values.asNameMap()[j['dock']] ?? ToolbarDock.top,
      favourites: [
        for (final f in (j['favourites'] as List?) ?? const [])
          ?PenStyle.fromJson(f),
      ],
      favouritesX: (j['favouritesX'] as num?)?.toDouble() ?? 0.5,
      favouritesY: (j['favouritesY'] as num?)?.toDouble() ?? 0.85,
      eraser: EraserKind.values.asNameMap()[j['eraser']] ?? EraserKind.stroke,
      eraserSize: (j['eraserSize'] as num?)?.toDouble() ?? 8,
    ).copyWith();
  }
}

/// How long the pen must stay still at the end of a stroke to straighten it
/// (owner: hold to snap, like common note apps).
const snapHoldTime = Duration(milliseconds: 500);

/// Movement (screen pixels) still counted as "holding still".
const snapStillPixels = 4.0;

/// A stroke shorter than this (screen pixels) never snaps (e.g. dots).
const snapMinLengthPixels = 20.0;

/// Stroke width in PDF points for a pen at [pressure] (0..1), following
/// the Settings [response] (by default 60% of the set width when pressing
/// lightly to 140% when pressing hard). The highlighter ignores pressure.
double widthAtPressure(
  PenStyle style,
  double pressure, [
  PressureResponse response = const PressureResponse(),
]) => style.tool == InkTool.highlighter
    ? style.width
    : style.width * response.factor(pressure);
