import 'package:flutter/material.dart';

import '../core/app_settings.dart';
import '../settings/settings_controller.dart';

/// Places the handwriting box away from the writing hand's side (owner: a
/// right hand writing near the right edge gets less legible). Right hand:
/// the box sits on the left; left hand: on the right. Its width is a
/// percentage of the space, set in Settings.
class HandedWritingBox extends StatelessWidget {
  const HandedWritingBox({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final s = SettingsScope.of(context).value;
    return Align(
      alignment: s.writingHand == WritingHand.right
          ? Alignment.centerLeft
          : Alignment.centerRight,
      child: FractionallySizedBox(
        widthFactor: s.writingBoxPercent / 100,
        heightFactor: 1,
        child: child,
      ),
    );
  }
}
