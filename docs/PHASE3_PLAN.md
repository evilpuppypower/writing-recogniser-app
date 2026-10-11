# Phase 3 plan: does it learn? (draft for owner review, 2026-10-11)

Goal: find out, with numbers, whether the app gets better at reading the
owner's handwriting the more it is corrected, and decide at **GATE B**
what to do next. Nothing leaves the tablet (CLAUDE.md rule 7).

## What's already in place (skeleton, branch task/3.0-feedback-replay-skeleton)

| Piece | File | Status |
|---|---|---|
| Correction record (rule 4: recognised text, corrected text, previous word, raw strokes, count, time, scope) | `lib/core/feedback/correction.dart` | written |
| Feedback layer interface, the "engine only" baseline, and the owner's rule (prefer after 1 correction, swap after 2, previous word counts double, one-PDF scope) | `lib/core/feedback/feedback_layer.dart` | written, tested |
| Replay harness: replays words in order through engine only and engine + feedback, teaching corrections as it goes; CER/WER, repeated vs new words, corrections per 100 words over time | `lib/core/replay.dart` | written, tested |

Still to build in Phase 2 (they feed Phase 3): the correction store in
SQLite (2.5), the correction pop-up (2.4), event logging of corrections
and accepts (2.7).

## 3.1 Replay harness, in the app (10-18 h)

- **Data:** every corrected or accepted word from real use (2.5 stores the
  strokes), plus the GATE A samples split into words.
- **Screen:** Settings → "How well is it learning?":
  - engine alone vs with your corrections: word and character error rates
  - new words vs words written before
  - corrections per 100 words, week by week (should fall)
  - pen-lift-to-text time
  - export as CSV, like the opening times
- **Fair test:** the replay only learns from words *before* the one being
  read, exactly as in real use, so it can't cheat.

## 3.2 Real use (owner, 2-3 weeks)

- Use the app daily for real reading and note-taking, correcting wrong
  words as they appear.
- **Weekly check (5 minutes):** open the learning screen, send a
  screenshot or the CSV. I look for problems (wrong swaps, slow text,
  drawings read as words) and fix them between weeks.
- Logging stays on; everything stays on the tablet.

## 3.3 Analysis (6-10 h)

A short report:
1. Error rates: engine alone vs with feedback, for new and repeated words.
2. Corrections per 100 words over the weeks.
3. How often automatic swaps were right, and how often they were undone.
4. Speed: pen lift to text, engine time.
5. Writing vs drawing sorting: how often it had to be flipped by hand.
6. Battery and app size checks.

## GATE B (owner decides)

- **Keep** the simple feedback layer if repeated words improve clearly
  (target: at least a third fewer corrections on repeated words), or
- **Phase 4:** a small personal model trained on the stored strokes
  (`docs/design/correction-memory.md`), if the simple layer plateaus, or
- **Change engine** if MyScript's errors don't come down.

## Owner decisions (2026-10-11) and reminders

- **GATE B target:** "at least a third fewer corrections on repeated
  words" is fine for now. **Reminder: ask the owner to review the target
  when the learning screen is built.**
- **Weekly check:** once a week: a screenshot or the CSV.
- **Automatic swap:** from the second time (right after the first
  correction), set by `CorrectionMemory.autoReplaceAfter = 1`.
  **Reminder: ask the owner to review this once the correction pop-up is
  testable on the tablet.**
