/// Battery saver (owner, 2026-10-17: a switch, and on by itself while
/// Android's own battery saver is on). Pure Dart.
library;

/// Whether the app saves battery now: switched on, or following
/// Android's battery saver while that's on.
bool batterySaverOn({
  required bool switchedOn,
  required bool withSystem,
  required bool systemSaving,
}) => switchedOn || (withSystem && systemSaving);

/// How long the pen must pause before writing is read: at least
/// [savingPauseMs] while saving battery (fewer reads while writing).
int readPauseMs(int usualMs, {required bool saving}) =>
    saving && usualMs < savingPauseMs ? savingPauseMs : usualMs;

const savingPauseMs = 2000;
