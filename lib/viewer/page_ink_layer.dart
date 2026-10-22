import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core/app_settings.dart' show WritingGuide;
import '../core/page_coordinates.dart';
import '../core/page_ink.dart';
import '../core/pen_tap.dart';
import '../core/pen_tools.dart';
import '../core/selection.dart';
import '../core/shapes.dart';
import '../core/stroke_grouping.dart' show InkBox, levelPoint;
import '../core/typed_text.dart' show convertedGroups;
import '../core/writing_guide.dart';
import '../core/ink_prediction.dart';
import '../core/pen_timing.dart';
import '../settings/settings_controller.dart';
import 'dark_pages.dart';
import 'wet_ink.dart';

/// One undoable change: a page's strokes before and after.
class _InkEdit {
  const _InkEdit(this.page, this.before, this.after);
  final int page;
  final List<PageStroke> before;
  final List<PageStroke> after;
}

/// The ink of one open PDF, shared by every page's [PageInkLayer]. Notifies
/// listeners whenever a page's ink changes. Keeps an undo/redo history
/// (one step per stroke or per eraser gesture).
class DocumentInkController extends ChangeNotifier {
  DocumentInkController([DocumentInk? ink]) : ink = ink ?? DocumentInk();

  final DocumentInk ink;

  /// Called after a stroke is added, erased, undone or redone (e.g. to
  /// save, task 1.3).
  void Function(int page)? onChanged;

  /// The pen is on a page (writing, erasing or drawing a loop): other
  /// work (showing what was read) waits until it lifts, so a stroke is
  /// never held up (owner: gaps in the middle of strokes). Each page
  /// holding the pen is counted: it's up only when all have let go.
  final penDown = ValueNotifier<bool>(false);
  int _pens = 0;

  /// Where pen timings are measured (the diagnostics), if anywhere.
  PenTiming? penTiming;

  /// Draws the line under the pen ahead of the app (see WetInk); null:
  /// the app draws it alone.
  WetInk? wetInk;

  /// Where the pages show on the screen (not under the toolbars), in
  /// logical pixels; the platform's line is kept inside it.
  Rect? Function()? wetArea;

  void penOn() => penDown.value = ++_pens > 0;

  void penOff() {
    if (_pens > 0) _pens--;
    if (_pens == 0 && penDown.value) {
      // Not while a page is being taken down (listeners may be going).
      scheduleMicrotask(() {
        if (_pens == 0) penDown.value = false;
      });
    }
  }

  /// The wall-clock time of a pen event's own timestamp (when the pen was
  /// there, not when the app got to it), one clock for every page so
  /// strokes stay in order. The smallest delay seen lines the two clocks
  /// up; a much larger one (the tablet slept, and the event clock paused)
  /// lines them up again.
  int timeOf(Duration timeStamp) {
    final at = timeStamp.inMilliseconds;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (at == 0) return now;
    final lag = now - at;
    final o = _clockOffset;
    if (o == null || lag < o || lag > o + 1000) _clockOffset = lag;
    return _clockOffset! + at;
  }

  int? _clockOffset;

  static const maxHistory = 200;
  final _undo = <_InkEdit>[];
  final _redo = <_InkEdit>[];
  ({int page, List<PageStroke> before})? _gesture;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  void _record(int page, List<PageStroke> before) {
    final after = ink.strokesOn(page);
    if (identical(before, after)) return;
    _undo.add(_InkEdit(page, before, after));
    if (_undo.length > maxHistory) _undo.removeAt(0);
    _redo.clear();
  }

  /// Starts an eraser gesture on [page]: everything it removes until
  /// [endGesture] is undone in one step.
  void beginGesture(int page) {
    _gesture = (page: page, before: ink.strokesOn(page));
  }

  void endGesture() {
    final g = _gesture;
    _gesture = null;
    if (g != null) {
      _record(g.page, g.before);
      notifyListeners(); // undo availability may have changed
    }
  }

  void add(int page, PageStroke stroke) {
    final before = ink.strokesOn(page);
    ink.add(page, stroke);
    if (_gesture == null) _record(page, before);
    notifyListeners();
    onChanged?.call(page);
    onStrokeAdded?.call(page, stroke);
  }

  /// Called after the pen finishes a new stroke (not for edits, undo or
  /// moves), e.g. to learn how the user writes.
  void Function(int page, PageStroke stroke)? onStrokeAdded;

  /// Marks strokes on [page] as not writing (task 2.4c) and saves them.
  /// Not undoable with Undo: [markWriting] reverses it. The undo history
  /// is marked too, so undoing other edits can't bring back an unmarked
  /// copy.
  void markNotWriting(int page, Set<String> strokeIds) =>
      _setNotWriting(page, strokeIds, true);

  /// Reverses [markNotWriting] (task 2.4d): the strokes are read as
  /// writing again. The undo history follows, as above.
  void markWriting(int page, Set<String> strokeIds) =>
      _setNotWriting(page, strokeIds, false);

  void _setNotWriting(int page, Set<String> strokeIds, bool value) {
    final changed = value
        ? ink.markNotWriting(page, strokeIds)
        : ink.markWriting(page, strokeIds);
    if (!changed) return;
    List<PageStroke> mark(List<PageStroke> strokes) => [
      for (final s in strokes)
        s.notWriting != value && s.points.isNotEmpty && strokeIds.contains(s.id)
            ? s.copyWith(notWriting: value)
            : s,
    ];
    for (final history in [_undo, _redo]) {
      for (var i = 0; i < history.length; i++) {
        final e = history[i];
        if (e.page == page) {
          history[i] = _InkEdit(page, mark(e.before), mark(e.after));
        }
      }
    }
    notifyListeners();
    onChanged?.call(page);
  }

  /// Converts words on [page] to typed text (task 2.3b); one undo step.
  /// [words]: each word's stroke ids and its text.
  /// Returns whether anything was converted.
  bool convert(int page, Map<Set<String>, String> words) {
    final before = ink.strokesOn(page);
    if (!ink.convert(page, words)) return false;
    if (_gesture == null) _record(page, before);
    notifyListeners();
    onChanged?.call(page);
    return true;
  }

  /// Moves and resizes the selected strokes (see [DocumentInk.moveScale]);
  /// a drag's many small moves make one undo step inside
  /// [beginGesture]/[endGesture].
  void moveScale(
    int page,
    Set<String> ids, {
    double dx = 0,
    double dy = 0,
    double scale = 1,
    double originX = 0,
    double originY = 0,
  }) => _edit(
    page,
    () => ink.moveScale(
      page,
      ids,
      dx: dx,
      dy: dy,
      scale: scale,
      originX: originX,
      originY: originY,
    ),
  );

  void recolour(int page, Set<String> ids, int argb) =>
      _edit(page, () => ink.recolour(page, ids, argb));

  void scaleWidth(
    int page,
    Set<String> ids,
    double factor,
    (double, double) Function(InkTool tool) limits,
  ) => _edit(page, () => ink.scaleWidth(page, ids, factor, limits));

  void replaceStrokes(int page, List<PageStroke> moved) =>
      _edit(page, () => ink.replace(page, moved));

  void removeStrokes(int page, Set<String> ids) =>
      _edit(page, () => ink.remove(page, ids).isNotEmpty);

  void addStrokes(int page, List<PageStroke> strokes) => _edit(page, () {
    ink.addAll(page, strokes);
    return strokes.isNotEmpty;
  });

  void markOneWord(int page, Set<String> ids) =>
      _edit(page, () => ink.markOneWord(page, ids));

  /// Runs [change] on [page] as one undo step (or part of the gesture
  /// under way), telling listeners if it changed anything.
  void _edit(int page, bool Function() change) {
    final before = ink.strokesOn(page);
    if (!change()) return;
    if (_gesture == null) _record(page, before);
    notifyListeners();
    onChanged?.call(page);
  }

  /// The user edited converted word [group]'s typed text (and that of the
  /// groups in [merge], shown on the same line); one undo step.
  void setTypedText(
    int page,
    String group,
    String text, {
    Set<String> merge = const {},
  }) {
    final before = ink.strokesOn(page);
    if (!ink.setTypedText(page, group, text, merge: merge)) return;
    if (_gesture == null) _record(page, before);
    notifyListeners();
    onChanged?.call(page);
  }

  /// Puts previously saved ink on the pages, under anything written since
  /// the PDF opened (saved ink loads in the background). Not undoable.
  /// Returns the pages that had new ink too, which need saving again.
  Set<int> restore(DocumentInk saved) {
    final mixed = <int>{};
    for (final page in saved.pagesWithInk) {
      final old = saved.strokesOn(page);
      final now = ink.strokesOn(page);
      if (now.isNotEmpty) mixed.add(page);
      ink.setPage(page, [...old, ...now]);
      // Undo and redo of earlier edits on this page keep the saved ink.
      for (final h in [_undo, _redo]) {
        for (var i = 0; i < h.length; i++) {
          final e = h[i];
          if (e.page != page) continue;
          h[i] = _InkEdit(page, [...old, ...e.before], [...old, ...e.after]);
        }
      }
    }
    notifyListeners();
    return mixed;
  }

  /// Pen taps held back by page layers (task 2.4b): drawn before an undo
  /// or redo, so the history stays in the order things were written.
  final _flushers = <VoidCallback>{};
  void addFlusher(VoidCallback f) => _flushers.add(f);
  void removeFlusher(VoidCallback f) => _flushers.remove(f);
  void _flushHeld() {
    for (final f in _flushers.toList()) {
      f();
    }
  }

  void undo() {
    _flushHeld();
    _step(_undo, _redo, (e) => e.before);
  }

  void redo() {
    _flushHeld();
    _step(_redo, _undo, (e) => e.after);
  }

  void _step(
    List<_InkEdit> from,
    List<_InkEdit> to,
    List<PageStroke> Function(_InkEdit) pick,
  ) {
    if (from.isEmpty) return;
    final edit = from.removeLast();
    ink.setPage(edit.page, pick(edit));
    to.add(edit);
    notifyListeners();
    onChanged?.call(edit.page);
  }

  bool eraseAt(
    int page,
    double x,
    double y,
    double radius, {
    bool Function(PageStroke s)? protect,
  }) {
    final before = ink.strokesOn(page);
    final removed = ink.eraseAt(page, x, y, radius, protect: protect);
    if (removed.isEmpty) return false;
    if (_gesture == null) _record(page, before);
    notifyListeners();
    onChanged?.call(page);
    return true;
  }

  /// Partial erase (only where the eraser touches).
  bool eraseArea(
    int page,
    double x,
    double y,
    double radius, {
    bool Function(PageStroke s)? protect,
  }) {
    final before = ink.strokesOn(page);
    if (!ink.eraseArea(page, x, y, radius, protect: protect)) return false;
    if (_gesture == null) _record(page, before);
    notifyListeners();
    onChanged?.call(page);
    return true;
  }
}

/// Lets the pen write on one PDF page while fingers keep scrolling and
/// zooming the document. Draws that page's ink.
///
/// Ink is converted to PDF page coordinates as it is written, so it stays
/// locked to the page at any zoom (CLAUDE.md rule 6).
class PageInkLayer extends StatefulWidget {
  const PageInkLayer({
    super.key,
    required this.pageNumber,
    required this.geometry,
    required this.viewWidth,
    required this.controller,
    this.tools,
    this.doubleTapActionAt,
    this.onLasso,
    this.showTyped,
    this.tapActionAt,
    this.onPenHover,
    this.selection,
    this.onClearSelection,
    this.wordsRead,
    this.isRead,
    this.onTextTap,
    this.tidyShape,
    this.onShapeTidied,
  });

  /// Whether a closed shape of this kind, this far off, is tidied (owner:
  /// a switch in Settings, and learning how exact shapes should be). Null:
  /// always.
  final bool Function(ShapeKind kind, double error)? tidyShape;

  /// A tidied shape was written as [stroke].
  final void Function(PageStroke stroke, ShapeKind kind, double error)?
  onShapeTidied;

  /// With the Text tool: the pen tapped here (PDF page coordinates), to
  /// place or edit a text box.
  final void Function(PdfPagePoint at)? onTextTap;

  /// When the writing guide shows (owner, 2026-10-14: not straight away,
  /// so drawing or circling doesn't bring it up): [guideDelay] after the
  /// stroke just written is read as part of a word ([isRead], checked
  /// whenever [wordsRead] changes). Without them, it shows as each stroke
  /// is written.
  final Listenable? wordsRead;
  final bool Function(String strokeId)? isRead;
  static const guideDelay = Duration(milliseconds: 1500);

  /// The Select tool's selection (any page; this layer shows and moves it
  /// when it's on [pageNumber]), and what to call to drop it.
  final ValueListenable<InkSelection?>? selection;
  final VoidCallback? onClearSelection;

  /// Called as the pen hovers over the page (not touching), with where.
  final void Function(Offset at)? onPenHover;

  /// What a single pen tap at a point does (e.g. edit the typed text
  /// there, task 2.3c), or null if a tap there is just a dot.
  final VoidCallback? Function(Offset at)? tapActionAt;

  /// With the lasso tool (task 2.3c): the loop drawn, in PDF page
  /// coordinates, once the pen lifts. Nothing is drawn on the page.
  final void Function(List<PageInkPoint> loop)? onLasso;

  /// While true, the ink of words converted to typed text isn't drawn (the
  /// typed text shows instead, owner's choice 1b).
  final ValueListenable<bool>? showTyped;

  /// What a pen double-tap at a point (in this layer's pixels) does, e.g.
  /// open the correction pop-up for the word label there (task 2.4b), or
  /// null if a double-tap there is just writing. [target] identifies what
  /// was hit (e.g. the word): both taps must hit the same one. A pen tap
  /// that lands on such a spot is held back briefly; if a second tap
  /// follows, both are dropped and the action runs, otherwise the tap is
  /// drawn as usual.
  final ({Object target, VoidCallback action})? Function(Offset at)?
  doubleTapActionAt;

  final int pageNumber;
  final PageGeometry geometry;

  static const tapRules = PenTapRules();

  /// Width of the page as laid out (before zoom), in logical pixels.
  final double viewWidth;
  final DocumentInkController controller;

  /// The current pen, highlighter or eraser (default pen if null).
  final ValueListenable<PenToolsState>? tools;

  @override
  State<PageInkLayer> createState() => _PageInkLayerState();
}

class _PageInkLayerState extends State<PageInkLayer> {
  final _active = ValueNotifier<List<PageInkPoint>>(const []);

  /// Ink drawn ahead of the pen while writing (the pen's guessed path, see
  /// [InkPredictor]): only shown, never part of the stroke.
  final _tip = ValueNotifier<List<PageInkPoint>>(const []);
  final _predictor = InkPredictor();
  Timer? _tipHide;

  /// How far ahead the tip goes for this stroke (see AppSettings.inkLeadMs).
  int _leadMs = 0;

  void _noTip() {
    _tipHide?.cancel();
    _predictor.reset();
    if (_tip.value.isNotEmpty) _tip.value = const [];
  }

  /// The pen-down time of the stroke the platform is drawing (see
  /// [DocumentInkController.wetInk]), or null.
  int? _wetDown;

  /// A pen stroke started: the platform draws it as the pen moves.
  void _startWet(PointerEvent e) {
    _wetDown = null;
    final wet = widget.controller.wetInk;
    // Not the highlighter (blended with the page) or see-through pens
    // (their joins would show darker there).
    if (wet == null ||
        _style.tool != InkTool.pen ||
        (_style.colorArgb >>> 24) != 0xFF) {
      return;
    }
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return;
    final toScreen = box.getTransformTo(null);
    final zoom = toScreen.getMaxScaleOnAxis();
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final pressure = SettingsScope.valueOf(context).pressureResponse;
    var clip = MatrixUtils.transformRect(toScreen, Offset.zero & box.size);
    final area = widget.controller.wetArea?.call();
    if (area != null) clip = clip.intersect(area);
    if (clip.isEmpty) return;
    final down = e.timeStamp.inMicroseconds;
    _wetDown = down;
    wet.start(
      downMicros: down,
      colorArgb: darkPagesOf(context)
          ? nightArgb(_style.colorArgb)
          : _style.colorArgb,
      unitPx: _style.width * _pixelsPerPoint * zoom * dpr,
      spread:
          pressure.strength.clamp(0.0, 1.0) * pressure.range.clamp(0.0, 10.0),
      thinnest: PressureResponse.thinnest,
      clip: clip,
      devicePixelRatio: dpr,
    );
  }

  /// The stroke isn't ink as drawn (straightened, a shape, erasing, a tap):
  /// the platform's copy goes now.
  void _cancelWet() {
    final down = _wetDown;
    _wetDown = null;
    if (down != null) widget.controller.wetInk?.cancel(down);
  }

  /// The stroke is in the page's ink: the platform's copy goes once the
  /// app's drawing of it is on the screen (the frame after next, so the
  /// line never blinks).
  void _releaseWet() {
    final down = _wetDown;
    final wet = widget.controller.wetInk;
    _wetDown = null;
    if (down == null || wet == null) return;
    final frames = SchedulerBinding.instance;
    frames.addPostFrameCallback((_) {
      frames.addPostFrameCallback(
        (_) => Timer(const Duration(milliseconds: 20), () => wet.release(down)),
      );
      frames.scheduleFrame();
    });
    frames.scheduleFrame();
  }

  /// A real pen point [e] was added to the stroke: guesses the tip again.
  void _guessAhead(PointerEvent e) {
    _predictor.add(
      e.localPosition.dx,
      e.localPosition.dy,
      e.timeStamp.inMicroseconds,
    );
    if (_leadMs <= 0 || _active.value.isEmpty) return;
    final guess = _predictor.predict(_leadMs * 1000);
    final last = _active.value.last;
    _tip.value = [
      for (final (x, y) in guess)
        () {
          final p = widget.geometry.toPdf(ViewPoint(x, y), widget.viewWidth);
          return PageInkPoint(p.x, p.y, last.t, last.pressure);
        }(),
    ];
    _tipHide?.cancel();
    // The pen stopped sending points (held still): the guess goes.
    if (guess.isNotEmpty) {
      _tipHide = Timer(
        Duration(milliseconds: _leadMs + 30),
        () => _tip.value = const [],
      );
    }
  }

  final _picture = _InkPicture();
  bool _erasing = false;

  /// Drawing a lasso loop (task 2.3c) rather than ink.
  bool _lassoing = false;
  static const _lassoStyle = PenStyle(
    tool: InkTool.pen,
    colorArgb: 0xFF1E88E5,
    width: 0.8,
  );

  /// Where to draw the eraser outline (the area it will clear), while the
  /// pen hovers or erases in eraser mode or with the side button held.
  /// Null when hidden.
  final _eraserAt = ValueNotifier<Offset?>(null);
  Timer? _eraserHide;

  void _showEraser(Offset at) {
    _eraserAt.value = at;
    // Hidden as soon as the pen leaves hover range (onExit below); as a
    // backstop, Android doesn't always say so, also hide it shortly after
    // the pen stops reporting.
    _eraserHide?.cancel();
    _eraserHide = Timer(const Duration(milliseconds: 200), _hideEraser);
  }

  void _hideEraser() {
    _eraserHide?.cancel();
    _eraserAt.value = null;
  }

  void _hover(PointerEvent e) {
    if (e.kind != PointerDeviceKind.stylus &&
        e.kind != PointerDeviceKind.invertedStylus) {
      return;
    }
    // The outline shows only while erasing (owner: the tablet's own hover
    // circle already shows where the pen is), so hovering hides it.
    if (_eraserAt.value != null) _hideEraser();
    widget.onPenHover?.call(e.localPosition);
    // Back at the end of the line just written (e.g. after scrolling to
    // see more of the page): its guide shows again.
    final guide = _guide.value;
    if (guide != null && !_guideShown.value) {
      final p = widget.geometry.toPdf(
        ViewPoint(e.localPosition.dx, e.localPosition.dy),
        widget.viewWidth,
      );
      if (nearLineEnd(guide, p.x, p.y)) {
        _guideShown.value = true;
        _guideHide?.cancel();
        _guideHide = Timer(_guideFor, () => _guideShown.value = false);
      }
    }
  }

  /// Where and when the pen touched down, and how far it has moved since
  /// (pixels), to tell a tap from writing.
  Offset _downAt = Offset.zero;
  int _downMs = 0;
  double _moved = 0;

  /// A pen tap on a double-tap spot, held back in case a second tap
  /// follows; drawn when [_held] times out.
  ({PenTap tap, PageStroke stroke, Object target, VoidCallback action})? _held;
  Timer? _holdTimer;

  void _drawHeld() {
    _holdTimer?.cancel();
    final held = _held;
    _held = null;
    if (held != null) widget.controller.add(widget.pageNumber, held.stroke);
  }

  /// Style of the stroke being written (fixed when the pen touches down).
  PenStyle _style = PenStyle.defaultPen;

  /// Hold to snap: where the pen last came to rest, the countdown to
  /// straighten the stroke, and whether it has been straightened.
  Offset? _stillAt;
  Timer? _snapTimer;
  bool _snapped = false;

  /// The tidy shape the stroke snapped to (it stays put until the pen
  /// lifts), or null.
  List<PageInkPoint>? _shape;
  (ShapeKind, double)? _shapeKind;

  void _restartSnapTimer(Offset at) {
    _stillAt = at;
    _snapTimer?.cancel();
    _snapTimer = Timer(snapHoldTime, _snap);
  }

  void _snap() {
    final pts = _active.value;
    if (_erasing || _snapped || pts.length < 2) return;
    // A closed shape held still at its end: tidied into the circle,
    // ellipse, rectangle or triangle it's closest to (pen only).
    if (_style.tool == InkTool.pen) {
      final shape = tidyShape(pts);
      if (shape != null &&
          (widget.tidyShape?.call(shape.kind, shape.error) ?? true)) {
        _snapped = true;
        _noTip();
        _cancelWet();
        _shape = shape.points;
        _shapeKind = (shape.kind, shape.error);
        _active.value = shape.points;
        HapticFeedback.selectionClick();
        return;
      }
    }
    final dx = (pts.last.x - pts.first.x) * _pixelsPerPoint;
    final dy = (pts.last.y - pts.first.y) * _pixelsPerPoint;
    if (math.sqrt(dx * dx + dy * dy) < snapMinLengthPixels) return;
    _snapped = true;
    _noTip();
    _cancelWet();
    _active.value = straightLine(pts.first, pts.last);
    widget.controller.penTiming?.straightened();
    HapticFeedback.selectionClick();
  }

  PenToolsState get _tools => widget.tools?.value ?? const PenToolsState();

  double get _pixelsPerPoint => widget.viewWidth / widget.geometry.displayWidth;

  PageInkPoint _pointOf(PointerEvent e) {
    final p = widget.geometry.toPdf(
      ViewPoint(e.localPosition.dx, e.localPosition.dy),
      widget.viewWidth,
    );
    final range = e.pressureMax - e.pressureMin;
    final pressure = range <= 0
        ? 0.5
        : ((e.pressure - e.pressureMin) / range).clamp(0.0, 1.0);
    widget.controller.penTiming?.point(e.timeStamp.inMicroseconds);
    return PageInkPoint(
      p.x,
      p.y,
      widget.controller.timeOf(e.timeStamp),
      pressure.toDouble(),
    );
  }

  /// This page has the pen (see [DocumentInkController.penDown]).
  var _hasPen = false;

  void _penOff() {
    if (!_hasPen) return;
    _hasPen = false;
    widget.controller.penOff();
  }

  /// Side button held (stylus primary or secondary), or the eraser end.
  static bool _isEraser(PointerEvent e) =>
      e.kind == PointerDeviceKind.invertedStylus ||
      e.buttons & (kPrimaryStylusButton | kSecondaryStylusButton) != 0;

  /// Where the eraser was at the previous event, so a fast movement erases
  /// everything along its path, not just where events landed.
  PageInkPoint? _lastErase;

  void _erase(PointerEvent e) {
    _showEraser(e.localPosition);
    final p = _pointOf(e);
    final tools = _tools;
    final radius = tools.eraserSize / _pixelsPerPoint;
    final from = _lastErase ?? p;
    _lastErase = p;
    // Ink hidden behind typed text can't be seen, so it isn't erased.
    final hidden = (widget.showTyped?.value ?? false)
        ? convertedGroups(widget.controller.ink.strokesOn(widget.pageNumber))
        : const <String>{};
    bool protect(PageStroke s) => hidden.contains(s.typedGroup);
    final dx = p.x - from.x, dy = p.y - from.y;
    final steps = (math.sqrt(dx * dx + dy * dy) / (radius / 2)).ceil();
    for (var i = 0; i <= steps; i++) {
      final f = steps == 0 ? 1.0 : i / steps;
      final x = from.x + dx * f, y = from.y + dy * f;
      if (tools.eraser == EraserKind.area) {
        widget.controller.eraseArea(
          widget.pageNumber,
          x,
          y,
          radius,
          protect: protect,
        );
      } else {
        widget.controller.eraseAt(
          widget.pageNumber,
          x,
          y,
          radius,
          protect: protect,
        );
      }
    }
  }

  /// The selection on this page, as a box in this layer's pixels.
  Rect? _selectionRect() {
    final sel = widget.selection?.value;
    if (sel == null || sel.page != widget.pageNumber) return null;
    return selectionRect(
      widget.controller.ink.strokesOn(widget.pageNumber),
      sel.ids,
      widget.geometry,
      widget.viewWidth,
    );
  }

  /// Dragging the selection (move), its bottom-right handle (resize) or
  /// its bottom-left handle (rotate, about its middle).
  bool _dragging = false, _resizing = false, _rotating = false;
  List<PageStroke> _rotateFrom = const [];
  PdfPagePoint _rotateAbout = const PdfPagePoint(0, 0);
  double _rotateStart = 0, _rotateApplied = 0;
  Offset _dragLast = Offset.zero;
  double _scaleSoFar = 1;
  PdfPagePoint? _scaleOrigin;
  double _scaleStartDistance = 1;

  static const handleRadius = 14.0;

  void _down(PointerEvent e) {
    if (!_hasPen) {
      _hasPen = true;
      widget.controller.penOn();
    }
    _lastErase = null;
    _downAt = e.localPosition;
    _downMs = DateTime.now().millisecondsSinceEpoch;
    _moved = 0;
    if (_tools.mode == PenMode.text && !_isEraser(e)) {
      _textTap = true; // a text box goes where the pen lifts (if a tap)
      return;
    }
    if (_tools.mode == PenMode.lasso && !_isEraser(e)) {
      final rect = _selectionRect();
      final at = e.localPosition;
      final handles = rect == null ? null : selectionHandles(rect);
      if (rect != null &&
          handles != null &&
          (at - handles.resize).distance <= handleRadius) {
        // The corner handle: resize, keeping the top-left corner in place.
        _resizing = true;
        _scaleSoFar = 1;
        _scaleStartDistance = math.max((at - rect.topLeft).distance, 1);
        _scaleOrigin = widget.geometry.toPdf(
          ViewPoint(rect.left, rect.top),
          widget.viewWidth,
        );
        widget.controller.beginGesture(widget.pageNumber);
        return;
      }
      if (rect != null &&
          handles != null &&
          (at - handles.rotate).distance <= handleRadius) {
        // The rotate handle: turn about the middle, from the strokes as
        // they were (so many small steps don't add up errors).
        final sel = widget.selection!.value!;
        _rotating = true;
        _rotateFrom = [
          for (final s in widget.controller.ink.strokesOn(widget.pageNumber))
            if (sel.ids.contains(s.id)) s,
        ];
        final c = rect.center;
        _rotateAbout = widget.geometry.toPdf(
          ViewPoint(c.dx, c.dy),
          widget.viewWidth,
        );
        _rotateStart = math.atan2(at.dy - c.dy, at.dx - c.dx);
        _rotateApplied = 0;
        widget.controller.beginGesture(widget.pageNumber);
        return;
      }
      if (rect != null && rect.inflate(12).contains(at)) {
        _dragging = true;
        _dragLast = at;
        widget.controller.beginGesture(widget.pageNumber);
        return;
      }
      // Elsewhere: the selection goes and a new loop starts.
      if (widget.selection?.value != null) widget.onClearSelection?.call();
    }
    if (_tools.mode == PenMode.lasso && !_isEraser(e)) {
      _lassoing = true;
      _erasing = false;
      _style = _lassoStyle;
      _active.value = [_pointOf(e)];
      return;
    }
    final current = _tools.current;
    _erasing = current == null || _isEraser(e);
    if (current != null) _style = current;
    if (_erasing) _drawHeld(); // so the eraser can reach a held dot
    if (_erasing) widget.controller.beginGesture(widget.pageNumber);
    if (_erasing) {
      _erase(e);
    } else {
      _guideHide?.cancel(); // stays while writing
      _active.value = [_pointOf(e)];
      _noTip();
      _leadMs = SettingsScope.valueOf(context).inkLeadMs;
      _predictor.onError = widget.controller.penTiming?.guessed;
      _startWet(e);
      _predictor.add(
        e.localPosition.dx,
        e.localPosition.dy,
        e.timeStamp.inMicroseconds,
      );
      _snapped = false;
      _shape = null;
      _shapeKind = null;
      _restartSnapTimer(e.localPosition);
    }
  }

  void _move(PointerEvent e) {
    _moved = math.max(_moved, (e.localPosition - _downAt).distance);
    if (_textTap) return;
    final sel = widget.selection?.value;
    if (_rotating && sel != null) {
      final c = widget.geometry.toView(_rotateAbout, widget.viewWidth);
      final at = e.localPosition;
      // The pen's turn about the middle, clockwise on screen (y down); a
      // clockwise turn on the page (y up) is what levelPoint does with a
      // positive angle, and a page shown turned doesn't change that.
      final turned = snapTurn(
        math.atan2(at.dy - c.y, at.dx - c.x) - _rotateStart,
      );
      // Only when the turn changes (a tap that jitters a pixel isn't an
      // edit); back to none: the strokes as they were.
      if (turned == _rotateApplied) return;
      _rotateApplied = turned;
      widget.controller.replaceStrokes(widget.pageNumber, [
        for (final s in _rotateFrom)
          turned == 0
              ? s
              : s.isTextBox
              // Text stays upright: its box moves with its corner.
              ? () {
                  final c = levelPoint(
                    s.points.first,
                    turned,
                    _rotateAbout.x,
                    _rotateAbout.y,
                  );
                  final dx = c.x - s.points.first.x;
                  final dy = c.y - s.points.first.y;
                  return s.copyWith(
                    points: [
                      for (final p in s.points)
                        PageInkPoint(p.x + dx, p.y + dy, p.t, p.pressure),
                    ],
                  );
                }()
              : s.copyWith(
                  points: [
                    for (final p in s.points)
                      levelPoint(p, turned, _rotateAbout.x, _rotateAbout.y),
                  ],
                ),
      ]);
      return;
    }
    if ((_dragging || _resizing) && sel != null) {
      if (_dragging) {
        final from = widget.geometry.toPdf(
          ViewPoint(_dragLast.dx, _dragLast.dy),
          widget.viewWidth,
        );
        final to = widget.geometry.toPdf(
          ViewPoint(e.localPosition.dx, e.localPosition.dy),
          widget.viewWidth,
        );
        _dragLast = e.localPosition;
        widget.controller.moveScale(
          widget.pageNumber,
          sel.ids,
          dx: to.x - from.x,
          dy: to.y - from.y,
        );
      } else {
        final origin = _scaleOrigin!;
        final o = widget.geometry.toView(origin, widget.viewWidth);
        final wanted =
            ((e.localPosition - Offset(o.x, o.y)).distance /
                    _scaleStartDistance)
                .clamp(0.2, 8.0);
        final step = wanted / _scaleSoFar;
        _scaleSoFar = wanted;
        widget.controller.moveScale(
          widget.pageNumber,
          sel.ids,
          scale: step,
          originX: origin.x,
          originY: origin.y,
        );
      }
      return;
    }
    if (_lassoing) {
      _active.value = [..._active.value, _pointOf(e)];
      return;
    }
    if (!_erasing && _isEraser(e)) {
      _drawHeld();
      _lastErase = null;
      widget.controller.beginGesture(widget.pageNumber);
      _active.value = const []; // button pressed mid-stroke: erase instead
      _noTip();
      _cancelWet();
      _snapTimer?.cancel();
      _erasing = true;
    }
    if (_erasing) {
      _erase(e);
    } else if (_shape != null) {
      // A tidied shape stays as it is until the pen lifts.
    } else if (_snapped) {
      // Straightened: the end follows the pen until it lifts.
      _active.value = straightLine(_active.value.first, _pointOf(e));
    } else {
      _active.value = [..._active.value, _pointOf(e)];
      _guessAhead(e);
      final still = _stillAt;
      if (still == null ||
          (e.localPosition - still).distance > snapStillPixels) {
        _restartSnapTimer(e.localPosition);
      }
    }
  }

  void _up(PointerEvent e) {
    _penOff();
    if (_textTap) {
      _textTap = false;
      if (_moved <= _textTapReach) {
        widget.onTextTap?.call(
          widget.geometry.toPdf(
            ViewPoint(e.localPosition.dx, e.localPosition.dy),
            widget.viewWidth,
          ),
        );
      }
      return;
    }
    if (_endSelectionDrag()) return;
    _finishStroke(e);
    _fadeGuideLater();
  }

  /// Ends moving or resizing the selection (one undo step); false if the
  /// pen wasn't doing that.
  bool _endSelectionDrag() {
    if (!_dragging && !_resizing && !_rotating) return false;
    _dragging = _resizing = _rotating = false;
    _rotateFrom = const [];
    widget.controller.endGesture();
    return true;
  }

  /// However the pen lifted (a stroke, a tap, the lasso, the highlighter),
  /// a guide still showing fades [_guideFor] later.
  void _fadeGuideLater() {
    if (!_guideShown.value || (_guideHide?.isActive ?? false)) return;
    _guideHide = Timer(_guideFor, () => _guideShown.value = false);
  }

  void _finishStroke(PointerEvent e) {
    _snapTimer?.cancel();
    _noTip();
    if (_lassoing) {
      final loop = [..._active.value, _pointOf(e)];
      _lassoing = false;
      _active.value = const [];
      widget.onLasso?.call(loop);
      return;
    }
    if (_erasing) {
      _erasing = false;
      widget.controller.endGesture();
      _hideEraser();
      return;
    }
    final shape = _shape;
    _shape = null;
    var points =
        shape ??
        (_snapped
            ? straightLine(_active.value.first, _pointOf(e))
            : [..._active.value, _pointOf(e)]);
    // The pen's own samples (not a straightened line or tidied shape), for
    // the diagnostics' count of missing samples.
    final sampled = shape == null && !_snapped
        ? [for (final p in points) p.t]
        : null;
    if (_style.arrow && !_snapped) {
      // Drop the flick as the pen lifts, so the head points along the line.
      points = trimLiftHook(
        points,
        arrowheadSize(_style.width) * 1.5,
        withinMs: SettingsScope.valueOf(context).arrowHookMs,
      );
    }
    final wasSnapped = _snapped;
    _active.value = const [];
    _snapped = false;
    _shape = null;
    final stroke = PageStroke(
      points: points,
      colorArgb: _style.colorArgb,
      width: _style.width,
      tool: _style.tool,
      // No arrowhead on a closed shape.
      arrow: _style.arrow && shape == null,
      // A tidied shape is a drawing: never read as a letter ("O", "D").
      notWriting: shape != null,
    );
    // A pen tap on a label: maybe the first half of a double-tap.
    final now = DateTime.now().millisecondsSinceEpoch;
    final isTap =
        !wasSnapped && PageInkLayer.tapRules.isTap(_moved, now - _downMs);
    final single = isTap ? widget.tapActionAt?.call(_downAt) : null;
    if (single != null) {
      _cancelWet(); // a tap on a label, not ink
      _drawHeld();
      single();
      return;
    }
    final hit =
        !wasSnapped && PageInkLayer.tapRules.isTap(_moved, now - _downMs)
        ? widget.doubleTapActionAt?.call(_downAt)
        : null;
    if (hit != null) {
      // Held back in case it's half of a double-tap: not shown yet.
      _cancelWet();
      final tap = PenTap(_downAt.dx, _downAt.dy, _downMs, now);
      final held = _held;
      if (held != null &&
          held.target == hit.target &&
          PageInkLayer.tapRules.isDouble(held.tap, tap)) {
        _holdTimer?.cancel();
        _held = null;
        held.action();
        return;
      }
      _drawHeld();
      _held = (
        tap: tap,
        stroke: stroke,
        target: hit.target,
        action: hit.action,
      );
      _holdTimer = Timer(PageInkLayer.tapRules.holdFor, _drawHeld);
      return;
    }
    _drawHeld(); // keep the order the strokes were written in
    _releaseWet();
    if (sampled != null) widget.controller.penTiming?.stroke(sampled);
    widget.controller.add(widget.pageNumber, stroke);
    final tidied = _shapeKind;
    _shapeKind = null;
    if (shape != null && tidied != null) {
      widget.onShapeTidied?.call(stroke, tidied.$1, tidied.$2);
    }
    if (widget.isRead == null) {
      _showGuide(stroke);
    } else if (stroke.tool == InkTool.pen) {
      _waitingToRead = stroke;
    }
  }

  /// The last pen stroke written, until it's read as part of a word.
  PageStroke? _waitingToRead;
  Timer? _guideLater;

  void _wordsRead() {
    final stroke = _waitingToRead;
    if (stroke == null || !(widget.isRead?.call(stroke.id) ?? false)) return;
    _waitingToRead = null;
    _guideLater?.cancel();
    _guideLater = Timer(PageInkLayer.guideDelay, () {
      if (!mounted) return;
      // Still on the page (not erased or moved away).
      final ink = widget.controller.ink.strokesOn(widget.pageNumber);
      if (ink.any((s) => s.id == stroke.id)) _showGuide(stroke);
    });
  }

  /// The writing guide (owner's choice F2): under the line [stroke] is on,
  /// fading in while writing and out [_guideFor] after the pen last lifts.
  final _guide = ValueNotifier<GuideLine?>(null);
  final _guideShown = ValueNotifier<bool>(false);
  Timer? _guideHide;
  static const _guideFor = Duration(seconds: 3);

  void _showGuide(PageStroke stroke) {
    final setting = SettingsScope.valueOf(context).writingGuide;
    // Lines are found along the page's own rows, which run up and down the
    // screen on a page turned sideways: no guide there.
    if (setting == WritingGuide.off ||
        stroke.tool != InkTool.pen ||
        widget.geometry.quarterTurns != 0) {
      return;
    }
    final guide = guideFor(
      widget.controller.ink.strokesOn(widget.pageNumber),
      stroke.id,
    );
    if (guide == null) return;
    _guide.value = guide;
    _guideShown.value = true;
    _guideHide?.cancel();
    // While the pen is writing it stays; it fades after the pen lifts.
    if (_active.value.isEmpty) {
      _guideHide = Timer(_guideFor, () => _guideShown.value = false);
    }
  }

  /// The Text tool: the pen is down for a tap (see [PageInkLayer.onTextTap]).
  bool _textTap = false;
  static const _textTapReach = 12.0;

  void _cancel() {
    _penOff();
    _textTap = false;
    if (_endSelectionDrag()) return;
    _fadeGuideLater();
    _snapTimer?.cancel();
    _noTip();
    _cancelWet();
    _snapped = false;
    _shape = null;
    _shapeKind = null;
    _lassoing = false;
    if (_erasing) widget.controller.endGesture();
    _erasing = false;
    _active.value = const [];
    _hideEraser();
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addFlusher(_drawHeld);
    widget.wordsRead?.addListener(_wordsRead);
  }

  @override
  void didUpdateWidget(PageInkLayer old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeFlusher(_drawHeld);
      widget.controller.addFlusher(_drawHeld);
    }
    if (old.wordsRead != widget.wordsRead) {
      old.wordsRead?.removeListener(_wordsRead);
      widget.wordsRead?.addListener(_wordsRead);
    }
  }

  @override
  void dispose() {
    _penOff();
    widget.controller.removeFlusher(_drawHeld);
    widget.wordsRead?.removeListener(_wordsRead);
    _guideLater?.cancel();
    // A held tap is drawn now rather than lost (the page scrolled away or
    // the PDF is closing). Done just after this frame, as other widgets
    // can't be told about it while the page is being taken down.
    _holdTimer?.cancel();
    final held = _held;
    _held = null;
    if (held != null) {
      final controller = widget.controller, page = widget.pageNumber;
      scheduleMicrotask(() {
        try {
          controller.add(page, held.stroke);
        } catch (_) {
          // The PDF has closed already: the dot goes with it.
        }
      });
    }
    _snapTimer?.cancel();
    _eraserHide?.cancel();
    _cancelWet();
    _active.dispose();
    _tipHide?.cancel();
    _tip.dispose();
    _eraserAt.dispose();
    _picture.close();
    _guideHide?.cancel();
    _guide.dispose();
    _guideShown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pressure = SettingsScope.valueOf(context).pressureResponse;
    final dark = darkPagesOf(context);
    final layer = RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: {
        StylusInkRecognizer:
            GestureRecognizerFactoryWithHandlers<StylusInkRecognizer>(
              () => StylusInkRecognizer(debugOwner: this),
              (r) => r
                ..onDown = _down
                ..onMove = _move
                ..onUp = _up
                ..onCancel = _cancel,
            ),
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: CustomPaint(
              painter: _PageInkPainter(
                controller: widget.controller,
                pageNumber: widget.pageNumber,
                geometry: widget.geometry,
                viewWidth: widget.viewWidth,
                pressure: pressure,
                cache: _picture,
                showTyped: widget.showTyped,
                dark: dark,
                devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
              ),
            ),
          ),
          ValueListenableBuilder(
            valueListenable: _guideShown,
            builder: (context, shown, child) => AnimatedOpacity(
              opacity: shown ? 1 : 0,
              duration: Duration(milliseconds: shown ? 250 : 800),
              child: child,
            ),
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _GuidePainter(
                  guide: _guide,
                  geometry: widget.geometry,
                  viewWidth: widget.viewWidth,
                  colorArgb: () {
                    final c = SettingsScope.valueOf(context)
                        .writingGuide
                        .colorArgb;
                    // On a dark page, a faint light line instead.
                    return dark && c != 0 ? nightArgb(c) : c;
                  }(),
                ),
              ),
            ),
          ),
          if (widget.selection != null)
            RepaintBoundary(
              child: CustomPaint(
                painter: _SelectionPainter(
                  controller: widget.controller,
                  selection: widget.selection!,
                  pageNumber: widget.pageNumber,
                  geometry: widget.geometry,
                  viewWidth: widget.viewWidth,
                ),
              ),
            ),
          RepaintBoundary(
            child: CustomPaint(
              painter: _ActiveInkPainter(
                active: _active,
                tip: _tip,
                geometry: widget.geometry,
                viewWidth: widget.viewWidth,
                activeStyle: () => _style,
                pressure: pressure,
                dark: dark,
                eraserAt: _eraserAt,
                eraserRadius: () => _tools.eraserSize,
                lassoing: () => _lassoing,
              ),
            ),
          ),
        ],
      ),
    );
    // Hover events from the pen (it reports its position before touching).
    return MouseRegion(
      opaque: false,
      hitTestBehavior: HitTestBehavior.translucent,
      onExit: (_) => _hideEraser(),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerHover: _hover,
        child: layer,
      ),
    );
  }
}

/// The dashes of a dotted line along [path] (screen pixels): [dash] long
/// with [gap] between them, carried smoothly round corners.
List<(Offset, Offset)> dashes(
  List<Offset> path, {
  double dash = 6,
  double gap = 4,
}) {
  final out = <(Offset, Offset)>[];
  var drawing = true;
  var left = dash; // of the current dash or gap
  for (var i = 1; i < path.length; i++) {
    var a = path[i - 1];
    final b = path[i];
    var length = (b - a).distance;
    while (length > 0) {
      final step = math.min(left, length);
      final end = Offset.lerp(a, b, step / length)!;
      // A dash that turns a corner is drawn as two pieces.
      if (drawing) out.add((a, end));
      left -= step;
      length -= step;
      a = end;
      if (left <= 0) {
        drawing = !drawing;
        left = drawing ? dash : gap;
      }
    }
  }
  return out;
}

/// Claims stylus pointers the moment they touch, so the pen writes instead
/// of scrolling the PDF. Fingers are not accepted and keep scrolling and
/// zooming as usual.
class StylusInkRecognizer extends OneSequenceGestureRecognizer {
  StylusInkRecognizer({super.debugOwner})
    : super(
        supportedDevices: const {
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
        },
      );

  void Function(PointerEvent event)? onDown;
  void Function(PointerEvent event)? onMove;
  void Function(PointerEvent event)? onUp;
  VoidCallback? onCancel;

  int? _pointer;

  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      _pointer == null && super.isPointerAllowed(event);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _pointer = event.pointer;
    resolve(GestureDisposition.accepted);
    onDown?.call(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _pointer) return;
    if (event is PointerMoveEvent) {
      onMove?.call(event);
    } else if (event is PointerUpEvent) {
      onUp?.call(event);
      _finish(event.pointer);
    } else if (event is PointerCancelEvent) {
      onCancel?.call();
      _finish(event.pointer);
    }
  }

  void _finish(int pointer) {
    _pointer = null;
    stopTrackingPointer(pointer);
  }

  @override
  void rejectGesture(int pointer) {
    if (pointer == _pointer) {
      onCancel?.call();
      _pointer = null;
    }
    super.rejectGesture(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'stylus ink';
}

/// A piece of a page's finished ink: up to [_InkPicture.chunkSize] strokes
/// in writing order, recorded once.
class _InkChunk {
  _InkChunk(this.id, this.strokes, this.pen, this.marker, this.bounds);

  /// New for every recording, so a ready-made image knows which pieces it
  /// holds.
  final int id;
  final List<PageStroke> strokes;
  final ui.Picture pen;

  /// The highlighter strokes, always drawn straight onto the page; null
  /// when there are none.
  final ui.Picture? marker;

  /// The area its pen ink covers (pixels at [_InkPicture.width]).
  final Rect bounds;

  void dispose() {
    pen.dispose();
    marker?.dispose();
  }
}

/// A page's finished ink, recorded in pieces ([chunks], at [width] pixels
/// wide) and, once the zoom has settled, drawn into a ready-made [image]
/// of just the inked area: scrolling then costs one image draw however
/// much ink there is (owner: scrolling got laggy with a lot of writing).
/// Only the pieces whose strokes changed are recorded again, so writing
/// one more stroke on a full page doesn't redraw the whole page (owner:
/// pages hold up to about 300 words).
class _InkPicture {
  final chunks = <_InkChunk>[];
  double width = 0;

  /// What, besides the strokes, the [chunks] were recorded for.
  Object? key;

  /// The stroke list last drawn (a page's list is replaced whenever its
  /// ink changes).
  List<PageStroke>? strokes;

  /// Strokes per piece.
  static const chunkSize = 64;

  int _nextId = 0;
  int newId() => _nextId++;

  /// The inked area, in pixels at [width].
  Rect get bounds {
    Rect? r;
    for (final c in chunks) {
      if (c.bounds.isEmpty) continue;
      r = r == null ? c.bounds : r.expandToInclude(c.bounds);
    }
    return r ?? Rect.zero;
  }

  ui.Image? image;

  /// The page width and pixel ratio the [image] was made for, the inked
  /// area there, and the pieces it holds.
  double imageWidth = 0;
  double imageRatio = 0;
  Rect imageBounds = Rect.zero;
  Set<int> imageChunks = const {};

  /// Page widths this close count as the same: moving a zoomed page
  /// changes its width in the last decimal places.
  static bool sameWidth(double a, double b) => (a - b).abs() < 0.5;

  /// Whether the image (or the decision not to make one) is for this
  /// width and pixel ratio, and still shows all the ink.
  bool imageFits(double viewWidth, double ratio) =>
      imageWidth != 0 &&
      sameWidth(imageWidth, viewWidth) &&
      imageRatio == ratio &&
      // Exactly the pieces showing: ink added since, or a whole piece
      // erased, means a new image (ids are never reused).
      imageChunks.length == chunks.length &&
      chunks.every((c) => imageChunks.contains(c.id));

  /// Whether the image shows only ink that is still there (pieces added
  /// since are drawn over it).
  bool get imageCurrent {
    if (image == null) return false;
    final ids = {for (final c in chunks) c.id};
    return imageChunks.every(ids.contains);
  }

  /// The page width an image is wanted for, once it has stayed the same
  /// for [_settle] (no image is made mid-zoom), and whether that time has
  /// passed.
  double _wanted = 0;
  bool _settled = false;
  Timer? _timer;
  static const _settle = Duration(milliseconds: 200);

  /// Ticks when an image can be made (the painter repaints on it).
  final ready = ValueNotifier<int>(0);

  /// Images bigger than this (pixels, 32 MB) are made smaller and drawn
  /// stretched (only when zoomed in a long way on a heavily inked page);
  /// past [minImageScale] none is made and the ink is drawn as it is.
  static const maxPixels = 8000000;
  static const minImageScale = 0.6;

  void want(double viewWidth) {
    if (sameWidth(viewWidth, _wanted) &&
        (_settled || (_timer?.isActive ?? false))) {
      return;
    }
    _wanted = viewWidth;
    _settled = false;
    _timer?.cancel();
    _timer = Timer(_settle, () {
      _settled = true;
      ready.value++;
    });
  }

  bool settledAt(double viewWidth) => _settled && sameWidth(_wanted, viewWidth);

  /// Waits again before making an image (the ink just changed).
  void restartWait(double viewWidth) {
    _settled = false;
    _wanted = double.nan;
    want(viewWidth);
  }

  void dropImage() {
    image?.dispose();
    image = null;
    imageWidth = 0;
    imageRatio = 0;
    imageChunks = const {};
  }

  void dispose() {
    for (final c in chunks) {
      c.dispose();
    }
    chunks.clear();
    key = null;
    strokes = null;
    dropImage();
  }

  void close() {
    dispose();
    _timer?.cancel();
    ready.dispose();
  }
}

/// The page's finished ink (cached in an [_InkPicture]).
class _PageInkPainter extends CustomPainter {
  _PageInkPainter({
    required this.controller,
    required this.pageNumber,
    required this.geometry,
    required this.viewWidth,
    required this.pressure,
    required this.cache,
    this.showTyped,
    this.devicePixelRatio = 1,
    this.dark = false,
  }) : super(repaint: Listenable.merge([controller, ?showTyped, cache.ready]));

  final double devicePixelRatio;

  /// Shown on a dark page (see darkPagesOf): colours turned round.
  final bool dark;

  final ValueListenable<bool>? showTyped;
  final DocumentInkController controller;
  final int pageNumber;
  final PageGeometry geometry;
  final double viewWidth;
  final PressureResponse pressure;
  final _InkPicture cache;

  @override
  void paint(Canvas canvas, Size size) {
    if (viewWidth <= 0) return;
    final strokes = controller.ink.strokesOn(pageNumber);
    if (strokes.isEmpty) return;
    final typedShown = showTyped?.value ?? false;
    final key = (
      typedShown,
      dark,
      pressure,
      geometry.width,
      geometry.height,
      geometry.quarterTurns,
    );
    if (cache.key != key) {
      cache
        ..dispose()
        ..key = key
        ..width = viewWidth;
    }
    if (!identical(cache.strokes, strokes)) {
      _update(strokes, typedShown);
      // The ink changed: a new image once it has stayed the same a
      // moment (not on every move of the eraser).
      cache.restartWait(viewWidth);
    }
    final zoom = viewWidth / cache.width;
    canvas.save();
    canvas.scale(zoom, zoom);
    for (final c in cache.chunks) {
      if (c.marker != null) canvas.drawPicture(c.marker!);
    }
    canvas.restore();
    if (!cache.imageFits(viewWidth, devicePixelRatio)) {
      if (cache.settledAt(viewWidth)) {
        _makeImage();
      } else {
        cache.want(viewWidth);
      }
    }
    final image = cache.image;
    if (image != null && cache.imageCurrent) {
      // Mid-zoom the image made for the last zoom is stretched until the
      // zoom settles (a moment slightly soft rather than every stroke
      // drawn on every frame).
      final stretch = viewWidth / cache.imageWidth;
      canvas.save();
      canvas.scale(stretch, stretch);
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        cache.imageBounds,
        Paint()..filterQuality = FilterQuality.medium,
      );
      canvas.restore();
      // Ink written since the image was made, drawn over it.
      canvas.save();
      canvas.scale(zoom, zoom);
      for (final c in cache.chunks) {
        if (!cache.imageChunks.contains(c.id)) canvas.drawPicture(c.pen);
      }
      canvas.restore();
      return;
    }
    canvas.save();
    canvas.scale(zoom, zoom);
    for (final c in cache.chunks) {
      canvas.drawPicture(c.pen);
    }
    canvas.restore();
  }

  /// Brings the cache's pieces up to date with [strokes]: pieces whose
  /// strokes are all still there, in the same order, are kept; a piece
  /// that lost strokes (erased) is recorded again with the rest; from the
  /// first piece that doesn't match (strokes changed or moved), and for
  /// new strokes, new pieces are recorded.
  void _update(List<PageStroke> strokes, bool typedShown) {
    cache.strokes = strokes;
    // Typed text shown instead of the ink of converted words.
    final typed = typedShown ? convertedGroups(strokes) : const <String>{};
    final shown = [
      for (final s in strokes)
        if (!typed.contains(s.typedGroup) &&
            !s.isTextBox &&
            s.points.isNotEmpty)
          s,
    ];
    final there = Set<PageStroke>.identity()..addAll(shown);
    final kept = <_InkChunk>[];
    var at = 0;
    var k = 0;
    for (; k < cache.chunks.length; k++) {
      final c = cache.chunks[k];
      final left = [
        for (final s in c.strokes)
          if (there.contains(s)) s,
      ];
      var same = at + left.length <= shown.length;
      for (var j = 0; same && j < left.length; j++) {
        same = identical(shown[at + j], left[j]);
      }
      if (!same) break;
      at += left.length;
      if (left.length == c.strokes.length) {
        kept.add(c);
      } else {
        c.dispose();
        if (left.isNotEmpty) kept.add(_record(left));
      }
    }
    for (; k < cache.chunks.length; k++) {
      cache.chunks[k].dispose();
    }
    for (var i = at; i < shown.length; i += _InkPicture.chunkSize) {
      kept.add(
        _record(
          shown.sublist(i, math.min(shown.length, i + _InkPicture.chunkSize)),
        ),
      );
    }
    cache.chunks
      ..clear()
      ..addAll(kept);
  }

  _InkChunk _record(List<PageStroke> strokes) {
    // Pen ink, and highlighter apart: it's multiplied over the page so
    // printed text stays readable, which only works drawn straight onto
    // the page (never in the ready-made image).
    final pen = ui.PictureRecorder(), marker = ui.PictureRecorder();
    final penCanvas = Canvas(pen), markerCanvas = Canvas(marker);
    final ink = _InkDrawer(geometry, cache.width, pressure, dark: dark);
    var markers = false;
    for (final s in strokes) {
      final highlight = s.tool == InkTool.highlighter;
      markers |= highlight;
      ink.draw(
        highlight ? markerCanvas : penCanvas,
        s.points,
        PenStyle(
          tool: s.tool,
          colorArgb: s.colorArgb,
          width: s.width,
          arrow: s.arrow,
        ),
      );
    }
    final markerPicture = marker.endRecording();
    if (!markers) markerPicture.dispose();
    return _InkChunk(
      cache.newId(),
      strokes,
      pen.endRecording(),
      markers ? markerPicture : null,
      ink.bounds([
        for (final s in strokes)
          if (s.tool != InkTool.highlighter) s,
      ]),
    );
  }

  /// Joins runs of small pieces (one per stroke while writing) back into
  /// full ones, so a page doesn't end up as hundreds of pieces.
  void _compact() {
    final chunks = cache.chunks;
    if (chunks.length <= 1) return;
    final out = <_InkChunk>[];
    var run = <_InkChunk>[];
    void flush() {
      if (run.length <= 1) {
        out.addAll(run);
      } else {
        final strokes = [for (final c in run) ...c.strokes];
        for (final c in run) {
          c.dispose();
        }
        for (var i = 0; i < strokes.length; i += _InkPicture.chunkSize) {
          out.add(
            _record(
              strokes.sublist(
                i,
                math.min(strokes.length, i + _InkPicture.chunkSize),
              ),
            ),
          );
        }
      }
      run = [];
    }

    for (final c in chunks) {
      if (c.strokes.length < _InkPicture.chunkSize ~/ 2) {
        run.add(c);
      } else {
        flush();
        out.add(c);
      }
    }
    flush();
    chunks
      ..clear()
      ..addAll(out);
  }

  /// The ready-made image of the inked area at this zoom (see
  /// [_InkPicture]); smaller and stretched if it would be too big, none
  /// if it would be far too big.
  void _makeImage() {
    _compact();
    final zoom = viewWidth / cache.width;
    final bounds = cache.bounds;
    final b = Rect.fromLTRB(
      (bounds.left * zoom).floorToDouble(),
      (bounds.top * zoom).floorToDouble(),
      (bounds.right * zoom).ceilToDouble(),
      (bounds.bottom * zoom).ceilToDouble(),
    );
    cache.dropImage();
    cache
      ..imageWidth = viewWidth
      ..imageRatio = devicePixelRatio
      ..imageChunks = {for (final c in cache.chunks) c.id};
    var ratio = devicePixelRatio;
    final full = b.width * b.height * ratio * ratio;
    if (full > _InkPicture.maxPixels) {
      final shrink = math.sqrt(_InkPicture.maxPixels / full);
      if (shrink < _InkPicture.minImageScale) return;
      ratio *= shrink;
    }
    final w = (b.width * ratio).ceil();
    final h = (b.height * ratio).ceil();
    if (w <= 0 || h <= 0) return;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..scale(ratio)
      ..translate(-b.left, -b.top)
      ..scale(zoom);
    for (final c in cache.chunks) {
      canvas.drawPicture(c.pen);
    }
    final picture = recorder.endRecording();
    try {
      cache
        ..image = picture.toImageSync(w, h)
        // Exactly the image's own size, so the ink isn't squeezed.
        ..imageBounds = Rect.fromLTWH(b.left, b.top, w / ratio, h / ratio);
    } finally {
      picture.dispose();
    }
  }

  // Never claim a touch: pdfrx stacks this layer on top of its scroll/zoom
  // view, so claiming would stop fingers reaching it. The pen still gets
  // here through the (translucent) gesture detector around the painting.
  @override
  bool hitTest(Offset position) => false;

  @override
  bool shouldRepaint(_PageInkPainter old) =>
      old.pageNumber != pageNumber ||
      old.viewWidth != viewWidth ||
      old.pressure != pressure ||
      old.controller != controller ||
      old.cache != cache ||
      old.devicePixelRatio != devicePixelRatio ||
      old.dark != dark;
}

/// What's being drawn right now: the stroke under the pen, the lasso, the
/// eraser outline. Kept apart from the finished ink, so moving the pen
/// doesn't redraw the whole page.
class _ActiveInkPainter extends CustomPainter {
  _ActiveInkPainter({
    required this.active,
    this.tip,
    required this.geometry,
    required this.viewWidth,
    required this.activeStyle,
    required this.pressure,
    required this.eraserAt,
    required this.eraserRadius,
    this.lassoing,
    this.dark = false,
  }) : super(repaint: Listenable.merge([active, eraserAt, tip]));

  final bool dark;

  final ValueNotifier<List<PageInkPoint>> active;

  /// Drawn on from the end of [active]: where the pen is guessed to be.
  final ValueListenable<List<PageInkPoint>>? tip;
  final PageGeometry geometry;
  final double viewWidth;
  final PenStyle Function() activeStyle;
  final PressureResponse pressure;
  final ValueListenable<Offset?> eraserAt;
  final double Function() eraserRadius;

  /// Whether [active] is a lasso loop being drawn (drawn dotted, closed by a
  /// straight dotted line back to where it started).
  final bool Function()? lassoing;

  @override
  void paint(Canvas canvas, Size size) {
    final ink = _InkDrawer(geometry, viewWidth, pressure, dark: dark);
    if (lassoing?.call() ?? false) {
      ink.drawLasso(canvas, active.value);
    } else {
      final ahead = tip?.value ?? const [];
      ink.draw(
        canvas,
        ahead.isEmpty ? active.value : [...active.value, ...ahead],
        activeStyle(),
      );
    }
    final at = eraserAt.value;
    if (at != null) {
      // Dark ring inside a light one, so it shows on any page colour.
      final r = eraserRadius();
      canvas.drawCircle(
        at,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = const Color(0xCCFFFFFF),
      );
      canvas.drawCircle(
        at,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = const Color(0xCC333333),
      );
    }
  }

  @override
  bool hitTest(Offset position) => false;

  @override
  bool shouldRepaint(_ActiveInkPainter old) =>
      old.viewWidth != viewWidth || old.pressure != pressure;
}

/// The selection's box in a page laid out [viewWidth] wide, from the
/// strokes [ids] (with a little room); null when none of them are left.
Rect? selectionRect(
  List<PageStroke> strokes,
  Set<String> ids,
  PageGeometry geometry,
  double viewWidth,
) {
  InkBox? box;
  for (final s in strokes) {
    if (s.points.isEmpty || !ids.contains(s.id)) continue;
    final b = InkBox.of(s);
    box = box == null ? b : box.union(b);
  }
  if (box == null) return null;
  final r = geometry.rectToView(
    PdfPageRect(
      left: box.left,
      bottom: box.bottom,
      right: box.right,
      top: box.top,
    ),
    viewWidth,
  );
  return Rect.fromLTWH(r.left, r.top, r.width, r.height).inflate(6);
}

/// Where the selection's handles go: resize at the bottom-right corner,
/// turn at the bottom-left; just outside the corners when the box is
/// small, so the box itself can still be dragged.
({Offset resize, Offset rotate}) selectionHandles(Rect rect) {
  const r = _PageInkLayerState.handleRadius;
  if (rect.shortestSide >= r * 3) {
    return (resize: rect.bottomRight, rotate: rect.bottomLeft);
  }
  return (
    resize: rect.bottomRight + const Offset(r, r),
    rotate: rect.bottomLeft + const Offset(-r, r),
  );
}

/// A turn of the selection (radians, clockwise on screen), snapped to
/// none or a quarter turn when within 4 degrees of one, so it's easy to
/// put back or turn exactly.
double snapTurn(double turned) {
  const quarter = math.pi / 2, near = 4 * math.pi / 180;
  final nearest = (turned / quarter).round() * quarter;
  return (turned - nearest).abs() <= near ? nearest : turned;
}

/// The selection: a dotted box round it, a handle at its bottom-right
/// corner to resize it and one at its bottom-left to turn it.
class _SelectionPainter extends CustomPainter {
  _SelectionPainter({
    required this.controller,
    required this.selection,
    required this.pageNumber,
    required this.geometry,
    required this.viewWidth,
  }) : super(repaint: Listenable.merge([controller, selection]));

  final DocumentInkController controller;
  final ValueListenable<InkSelection?> selection;
  final int pageNumber;
  final PageGeometry geometry;
  final double viewWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final sel = selection.value;
    if (sel == null || sel.page != pageNumber) return;
    final rect = selectionRect(
      controller.ink.strokesOn(pageNumber),
      sel.ids,
      geometry,
      viewWidth,
    );
    if (rect == null) return;
    canvas.drawRect(rect, Paint()..color = const Color(0x141E88E5));
    // The selected writing traced round: each selected stroke drawn again,
    // wider, in pale blue under the ink (owner's request). Only the
    // selected strokes, so it stays cheap.
    final scale = viewWidth / geometry.displayWidth;
    final halo = Paint()
      ..color = const Color(0x661E88E5)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final s in controller.ink.strokesOn(pageNumber)) {
      if (s.points.isEmpty || !sel.ids.contains(s.id)) continue;
      if (s.isTextBox) {
        // A text box: its box, outlined.
        final b = InkBox.of(s);
        final r = geometry.rectToView(
          PdfPageRect(
            left: b.left,
            bottom: b.bottom,
            right: b.right,
            top: b.top,
          ),
          viewWidth,
        );
        canvas.drawRect(
          Rect.fromLTWH(r.left, r.top, r.width, r.height).inflate(2),
          Paint()
            ..color = const Color(0x661E88E5)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3,
        );
        continue;
      }
      final path = Path();
      for (final (i, p) in s.points.indexed) {
        final v = geometry.toView(PdfPagePoint(p.x, p.y), viewWidth);
        if (i == 0) {
          path.moveTo(v.x, v.y);
        } else {
          path.lineTo(v.x, v.y);
        }
      }
      if (s.points.length == 1) path.relativeLineTo(0.1, 0);
      canvas.drawPath(path, halo..strokeWidth = s.width * scale + 6);
    }
    final path = [
      rect.topLeft,
      rect.topRight,
      rect.bottomRight,
      rect.bottomLeft,
      rect.topLeft,
    ];
    final line = Paint()
      ..color = const Color(0xFF1E88E5)
      ..strokeWidth = 1.4;
    for (final (a, b) in dashes(path)) {
      canvas.drawLine(a, b, line);
    }
    final handles = selectionHandles(rect);
    canvas.drawCircle(
      handles.resize,
      _PageInkLayerState.handleRadius * 0.6,
      Paint()..color = const Color(0xFF1E88E5),
    );
    canvas.drawCircle(
      handles.resize,
      _PageInkLayerState.handleRadius * 0.6,
      Paint()
        ..color = const Color(0xFFFFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    // The rotate handle: a ring with an arrow round it.
    final r = _PageInkLayerState.handleRadius * 0.6;
    canvas.drawCircle(
      handles.rotate,
      r,
      Paint()..color = const Color(0xFF1E88E5),
    );
    final arrow = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    final inner = Rect.fromCircle(center: handles.rotate, radius: r * 0.55);
    canvas.drawArc(inner, -math.pi / 2, math.pi * 1.5, false, arrow);
    final tip = handles.rotate + Offset(0, -r * 0.55);
    canvas.drawLine(tip, tip + Offset(-r * 0.35, -r * 0.3), arrow);
    canvas.drawLine(tip, tip + Offset(-r * 0.35, r * 0.3), arrow);
  }

  @override
  bool hitTest(Offset position) => false;

  @override
  bool shouldRepaint(_SelectionPainter old) =>
      old.viewWidth != viewWidth || old.pageNumber != pageNumber;
}

/// The writing guide line (see [guideFor]).
class _GuidePainter extends CustomPainter {
  _GuidePainter({
    required this.guide,
    required this.geometry,
    required this.viewWidth,
    required this.colorArgb,
  }) : super(repaint: guide);

  final ValueListenable<GuideLine?> guide;
  final PageGeometry geometry;
  final double viewWidth;
  final int colorArgb;

  @override
  void paint(Canvas canvas, Size size) {
    final g = guide.value;
    if (g == null || colorArgb == 0) return;
    final (start, end) = ends(g);
    final a = geometry.toView(PdfPagePoint(start.x, start.y), viewWidth);
    final b = geometry.toView(PdfPagePoint(end.x, end.y), viewWidth);
    canvas.drawLine(
      Offset(a.x, a.y),
      Offset(b.x, b.y),
      Paint()
        ..color = Color(colorArgb)
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool hitTest(Offset position) => false;

  @override
  bool shouldRepaint(_GuidePainter old) =>
      old.viewWidth != viewWidth ||
      old.colorArgb != colorArgb ||
      old.geometry != geometry;
}

/// A picture of [strokes] (PNG bytes) on white, [pxPerPt] pixels per PDF
/// point with a little margin, upright as the page shows ([geometry]), for
/// the Select tool's "Share as image"; at most [maxSide] pixels across.
/// Null if there's no ink.
Future<Uint8List?> inkImage(
  List<PageStroke> strokes,
  PageGeometry geometry, {
  PressureResponse pressure = const PressureResponse(),
  double pxPerPt = 4,
  double maxSide = 4096,
}) async {
  final ink = [
    for (final s in strokes)
      if (s.points.isNotEmpty && !s.isTextBox) s,
  ];
  if (ink.isEmpty) return null;
  var box = InkBox.of(ink.first);
  for (final s in ink.skip(1)) {
    box = box.union(InkBox.of(s));
  }
  final widest = ink.map((s) => s.width).reduce(math.max);
  final margin = widest + 6;
  final r = geometry.rectToView(
    PdfPageRect(
      left: box.left - margin,
      bottom: box.bottom - margin,
      right: box.right + margin,
      top: box.top + margin,
    ),
    geometry.displayWidth,
  );
  final scale = math.min(pxPerPt, maxSide / math.max(r.width, r.height));
  final w = (r.width * scale).ceil(), h = (r.height * scale).ceil();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..drawRect(
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..color = const Color(0xFFFFFFFF),
    )
    ..translate(-r.left * scale, -r.top * scale);
  final drawer = _InkDrawer(geometry, geometry.displayWidth * scale, pressure);
  for (final s in ink) {
    drawer.draw(
      canvas,
      s.points,
      PenStyle(
        tool: s.tool,
        colorArgb: s.colorArgb,
        width: s.width,
        arrow: s.arrow,
      ),
    );
  }
  final image = await recorder.endRecording().toImage(w, h);
  try {
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    return png?.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

/// A pen line width (pixels) rounded to steps of 6% of itself, so a
/// stroke's pressure changes give a few runs of one width, not one per
/// segment, and the steps look the same at any zoom.
double widthStep(double w) {
  if (w <= 0.05) return 0.05;
  final n = (math.log(w) / _widthStepLog).round();
  return math.pow(1.06, n).toDouble();
}

final _widthStepLog = math.log(1.06);

/// Draws strokes on a page laid out [viewWidth] pixels wide.
class _InkDrawer {
  _InkDrawer(this.geometry, this.viewWidth, this.pressure, {this.dark = false})
    : scale = viewWidth / geometry.displayWidth;

  /// Drawing on a dark page: ink colours turned round (see nightArgb).
  final bool dark;

  final PageGeometry geometry;
  final double viewWidth;
  final PressureResponse pressure;
  final double scale;

  /// The lasso: a dotted loop, with a straight dotted line from the pen back
  /// to the start, so it's clear what's inside. Blue dashes on white, so
  /// it shows on any page.
  void drawLasso(Canvas canvas, List<PageInkPoint> points) {
    if (points.length < 2) return;
    final path = [
      for (final p in points)
        geometry.toView(PdfPagePoint(p.x, p.y), viewWidth),
    ].map((v) => Offset(v.x, v.y)).toList();
    final loop = [...path, path.first];
    final segments = dashes(loop);
    final under = Paint()
      ..color = const Color(0xCCFFFFFF)
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;
    final over = Paint()
      ..color = const Color(0xFF1E88E5)
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    for (final paint in [under, over]) {
      for (final (a, b) in segments) {
        canvas.drawLine(a, b, paint);
      }
    }
  }

  /// The area [strokes] cover (pixels), with room for line widths and
  /// arrowheads; strokes of groups in [skip] left out.
  Rect bounds(List<PageStroke> strokes, {Set<String> skip = const {}}) {
    Rect? r;
    for (final s in strokes) {
      if (s.points.isEmpty || s.isTextBox || skip.contains(s.typedGroup)) {
        continue;
      }
      final b = InkBox.of(s);
      final v = geometry.rectToView(
        PdfPageRect(left: b.left, bottom: b.bottom, right: b.right, top: b.top),
        viewWidth,
      );
      final room =
          (s.width * 2 + (s.arrow ? arrowheadSize(s.width) : 0)) * scale + 2;
      final box = Rect.fromLTWH(v.left, v.top, v.width, v.height).inflate(room);
      r = r == null ? box : r.expandToInclude(box);
    }
    return r ?? Rect.zero;
  }

  void draw(Canvas canvas, List<PageInkPoint> points, PenStyle style) {
    // Text boxes aren't ink: they're shown as typed text.
    if (points.isEmpty || style.tool == InkTool.text) return;
    Offset at(PageInkPoint p) {
      final v = geometry.toView(PdfPagePoint(p.x, p.y), viewWidth);
      return Offset(v.x, v.y);
    }

    if (style.tool == InkTool.highlighter) {
      // See-through, flat-ended, and multiplied so printed text stays
      // readable underneath.
      final paint = Paint()
        ..color = Color(style.colorArgb).withValues(alpha: 0.4)
        // On a dark page, lightened instead (multiplied, it wouldn't show).
        ..blendMode = dark ? BlendMode.screen : BlendMode.multiply
        ..strokeWidth = style.width * scale
        ..strokeCap = StrokeCap.butt
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      final path = Path()..moveTo(at(points.first).dx, at(points.first).dy);
      for (final p in points.skip(1)) {
        final o = at(p);
        path.lineTo(o.dx, o.dy);
      }
      if (points.length == 1) {
        path.lineTo(at(points.first).dx + 0.1, at(points.first).dy);
      }
      canvas.drawPath(path, paint);
      return;
    }

    // Pen: each segment's width follows the pen pressure.
    final paint = Paint()
      ..color = Color(dark ? nightArgb(style.colorArgb) : style.colorArgb)
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;
    if (points.length == 1) {
      final w = widthAtPressure(style, points.first.pressure, pressure) * scale;
      canvas.drawCircle(
        at(points.first),
        w / 2,
        paint..style = PaintingStyle.fill,
      );
      return;
    }
    // One path per run of segments of (about) the same width, rather than
    // one line per segment: far fewer things for the screen to draw.
    paint.strokeJoin = StrokeJoin.round;
    var run = Path();
    double? runWidth;
    for (var i = 1; i < points.length; i++) {
      final a = points[i - 1], b = points[i];
      final w = widthStep(
        widthAtPressure(style, (a.pressure + b.pressure) / 2, pressure) * scale,
      );
      if (w != runWidth) {
        if (runWidth != null) {
          canvas.drawPath(run, paint..strokeWidth = runWidth);
        }
        run = Path()..moveTo(at(a).dx, at(a).dy);
        runWidth = w;
      }
      final o = at(b);
      run.lineTo(o.dx, o.dy);
    }
    if (runWidth != null) canvas.drawPath(run, paint..strokeWidth = runWidth);
    if (style.arrow) {
      final size = arrowheadSize(style.width);
      paint.strokeWidth = style.width * scale;
      final tip = at(points.last);
      for (final (x, y) in arrowheadPoints(points, size)) {
        canvas.drawLine(tip, at(PageInkPoint(x, y, 0)), paint);
      }
    }
  }
}

/// A page's ink, small (page thumbnails): drawn to fill the widget, upright
/// as the page shows ([geometry]). Text boxes aren't drawn.
class PageInkPreview extends StatelessWidget {
  const PageInkPreview({
    super.key,
    required this.strokes,
    required this.geometry,
    this.dark = false,
  });

  final List<PageStroke> strokes;
  final PageGeometry geometry;
  final bool dark;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      painter: _PreviewPainter(strokes, geometry, dark),
      size: Size.infinite,
    ),
  );
}

class _PreviewPainter extends CustomPainter {
  _PreviewPainter(this.strokes, this.geometry, this.dark);

  final List<PageStroke> strokes;
  final PageGeometry geometry;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0) return;
    final drawer = _InkDrawer(
      geometry,
      size.width,
      const PressureResponse(),
      dark: dark,
    );
    for (final s in strokes) {
      if (s.points.isEmpty || s.isTextBox) continue;
      drawer.draw(
        canvas,
        s.points,
        PenStyle(
          tool: s.tool,
          colorArgb: s.colorArgb,
          width: s.width,
          arrow: s.arrow,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(_PreviewPainter old) =>
      !identical(old.strokes, strokes) ||
      old.geometry != geometry ||
      old.dark != dark;
}
