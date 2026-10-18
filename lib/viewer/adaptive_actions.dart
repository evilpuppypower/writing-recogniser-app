import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// One toolbar button (or group), and what it offers in the "More" menu
/// when there isn't room for it on the bar.
class BarItem {
  const BarItem({required this.bar, required this.menu});

  final Widget bar;

  /// Its menu entries; each entry's value is what to do when chosen.
  final List<PopupMenuEntry<VoidCallback>> Function() menu;
}

/// A title bar's buttons that fit the screen (owner, 2026-10-18: in
/// portrait the buttons covered the back button and the title): [items]
/// in order of importance, as many as fit (each measured as it is, so
/// any text size works) after the back button and room for the title;
/// the rest in a "More" menu, with their names.
class AdaptiveActions extends StatefulWidget {
  const AdaptiveActions({super.key, required this.items, this.minTitle = 160});

  final List<BarItem> items;

  /// Room always kept for the title.
  final double minTitle;

  /// The back button and the space after it.
  static const leading = 72.0;

  /// How many of [widths] fit in [room]: all, or as many as fit with
  /// [more] (the "More" button's width) too.
  static int fitting(List<double> widths, double more, double room) {
    final all = widths.fold(0.0, (a, w) => a + w);
    if (all <= room) return widths.length;
    var used = more;
    var n = 0;
    while (n < widths.length && used + widths[n] <= room) {
      used += widths[n];
      n++;
    }
    return n;
  }

  @override
  State<AdaptiveActions> createState() => _AdaptiveActionsState();
}

class _AdaptiveActionsState extends State<AdaptiveActions> {
  /// How many items were on the bar at the last layout.
  int _shown = 0;

  /// The same, as last built: the hidden ones can't be reached with a
  /// keyboard either.
  int _focusable = 1 << 30;

  void _laidOut(int n) {
    _shown = n;
    if (n == _focusable) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _shown != _focusable) {
        setState(() => _focusable = _shown);
      }
    });
  }

  @override
  Widget build(BuildContext context) => _FitRow(
    // The back button, room for the title, the bar's own edges (and the
    // screen's, e.g. a camera cut-out in landscape).
    reserve:
        AdaptiveActions.leading +
        widget.minTitle +
        8 +
        MediaQuery.paddingOf(context).horizontal,
    // A title bar lets its buttons be as wide as they like: the screen's
    // width is what there is.
    screenWidth: MediaQuery.sizeOf(context).width,
    onShown: _laidOut,
    children: [
      for (final (n, i) in widget.items.indexed)
        n < _focusable ? i.bar : ExcludeFocus(child: i.bar),
      PopupMenuButton<VoidCallback>(
        tooltip: 'More',
        icon: const Icon(Icons.more_vert),
        onSelected: (act) => act(),
        itemBuilder: (_) => [
          for (final i in widget.items.skip(_shown)) ...i.menu(),
        ],
      ),
    ],
  );
}

/// Lays its children out in a row as they fit; the last child (the
/// "More" button) shows only when some don't.
class _FitRow extends MultiChildRenderObjectWidget {
  const _FitRow({
    required this.reserve,
    required this.screenWidth,
    required this.onShown,
    required super.children,
  });

  final double reserve, screenWidth;
  final ValueChanged<int> onShown;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFitRow(reserve, screenWidth, onShown);

  @override
  void updateRenderObject(BuildContext context, _RenderFitRow r) => r
    ..reserve = reserve
    ..screenWidth = screenWidth
    ..onShown = onShown;
}

class _FitParentData extends ContainerBoxParentData<RenderBox> {
  bool shown = false;
}

class _RenderFitRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _FitParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _FitParentData> {
  _RenderFitRow(this._reserve, this._screenWidth, this.onShown);

  double _screenWidth;
  set screenWidth(double v) {
    if (v == _screenWidth) return;
    _screenWidth = v;
    markNeedsLayout();
  }

  double _reserve;
  set reserve(double v) {
    if (v == _reserve) return;
    _reserve = v;
    markNeedsLayout();
  }

  ValueChanged<int> onShown;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _FitParentData) {
      child.parentData = _FitParentData();
    }
  }

  @override
  void performLayout() {
    final kids = <RenderBox>[];
    var c = firstChild;
    while (c != null) {
      kids.add(c);
      c = childAfter(c);
    }
    final loose = BoxConstraints(maxHeight: constraints.maxHeight);
    for (final k in kids) {
      k.layout(loose, parentUsesSize: true);
    }
    final items = kids.sublist(0, kids.length - 1);
    final more = kids.last;
    final width = math.min(
      constraints.hasBoundedWidth ? constraints.maxWidth : _screenWidth,
      _screenWidth,
    );
    final room = math.max(0.0, width - _reserve);
    final shown = AdaptiveActions.fitting(
      [for (final k in items) k.size.width],
      more.size.width,
      room,
    );
    var x = 0.0, height = 0.0;
    void place(RenderBox k, bool on) {
      final d = k.parentData! as _FitParentData;
      d.shown = on;
      if (!on) return;
      height = math.max(height, k.size.height);
    }

    for (var i = 0; i < items.length; i++) {
      place(items[i], i < shown);
    }
    place(more, shown < items.length);
    for (final k in kids) {
      final d = k.parentData! as _FitParentData;
      if (!d.shown) continue;
      d.offset = Offset(x, (height - k.size.height) / 2);
      x += k.size.width;
    }
    size = constraints.constrain(Size(x, height));
    onShown(shown);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    var c = firstChild;
    while (c != null) {
      final d = c.parentData! as _FitParentData;
      if (d.shown) context.paintChild(c, d.offset + offset);
      c = d.nextSibling;
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    var c = lastChild;
    while (c != null) {
      final d = c.parentData! as _FitParentData;
      if (d.shown) {
        final hit = result.addWithPaintOffset(
          offset: d.offset,
          position: position,
          hitTest: (r, p) => c!.hitTest(r, position: p),
        );
        if (hit) return true;
      }
      c = d.previousSibling;
    }
    return false;
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    var c = firstChild;
    while (c != null) {
      final d = c.parentData! as _FitParentData;
      if (d.shown) visitor(c);
      c = d.nextSibling;
    }
  }
}

/// A "More" menu entry: [icon], [label], and [onTap] (greyed out if null).
PopupMenuEntry<VoidCallback> barMenuItem(
  IconData icon,
  String label,
  VoidCallback? onTap,
) => PopupMenuItem<VoidCallback>(
  value: onTap,
  enabled: onTap != null,
  child: ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon),
    title: Text(label),
  ),
);
