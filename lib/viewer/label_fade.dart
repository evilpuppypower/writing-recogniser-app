import 'dart:async';

import 'package:flutter/foundation.dart';

/// Whether the recognised-text labels are showing (owner's choice C1 + C4,
/// 2026-10-13): they fade [after] the last time they were woken (writing,
/// the pen hovering near them, a tap, or the labels button), so they
/// don't clutter the page.
class LabelFade extends ValueNotifier<bool> {
  LabelFade({this.after = defaultAfter}) : super(true) {
    _restart();
  }

  static const defaultAfter = Duration(seconds: 5);

  final Duration after;
  Timer? _timer;

  /// Shows the labels, and fades them again [after] from now.
  void wake() {
    value = true;
    _restart();
  }

  void _restart() {
    _timer?.cancel();
    _timer = Timer(after, () => value = false);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
