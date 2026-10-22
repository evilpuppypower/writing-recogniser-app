/// The line under the pen drawn by the platform, ahead of the app's own
/// drawing (see WetInk.kt). The page ink layer says which pen strokes are
/// ink; the platform layer draws them as the pen moves and forgets each
/// once the app has drawn it. Nothing is saved there.
library;

import 'dart:ui' show Rect;

abstract class WetInk {
  /// The pen stroke that went down at [downMicros] (its pen-down event's
  /// time) is ink: draw it in [colorArgb], [unitPx] wide at normal
  /// pressure (physical pixels), within [clip] (logical pixels, in the
  /// app's coordinates).
  void start({
    required int downMicros,
    required int colorArgb,
    required double unitPx,
    required double spread,
    required double thinnest,
    required Rect clip,
    required double devicePixelRatio,
  });

  /// The stroke isn't ink after all (straightened, a shape, the eraser, a
  /// tap): it goes at once.
  void cancel(int downMicros);

  /// The app has drawn the stroke: the platform's copy goes.
  void release(int downMicros);
}
