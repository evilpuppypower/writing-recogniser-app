# Roadmap: Phase 2 onwards (draft for owner review, 2026-10-11)

This expands `docs/PLAN.md` from Phase 2 onwards with the owner's decisions
so far. **Bold questions** still need the owner. Hours are rough.

## Where things stand

- Phase 1 (import, viewer, pen, saving, export) is in final testing.
- GATE A passed: MyScript offline is the main engine; ML Kit and MyScript
  Cloud stay available.
- Started on branches (no PR until Phase 1 is done): 2.2 grouping strokes
  into lines and words, 2.3 recognised text labels.

## Phase 2: recognition and feedback loop

| Task | What | Owner decisions | Est. |
|---|---|---|---|
| 2.2 | Group strokes into words and lines; send only new or changed words, with the text before them as context | Done on a branch | done |
| 2.2b | Tell writing apart from drawings (underlines, arrows, diagrams) without dropping long cursive strokes | **Try MyScript's own text/drawing sorting ("Raw Content") first, with a shape check as backup for other engines; when unsure, treat as writing; let the user flip a group?** | 12-20 h |
| 2.3 | Show recognised text | Labels **above** words by default (or below, or off). A text panel docked top/bottom/left/right **or** floating, movable and resizable. Labels and panel together or either alone | 16-26 h |
| 2.4 | Correct a word | **Double-tap** a label (finger or pen) opens a pop-up: alternatives, "Type it" (keyboard; its microphone gives voice input), "Rewrite" (write in a box) | 14-24 h |
| 2.5 | Correction store | Keeps recognised text, corrected text, previous word, raw strokes, count, time (CLAUDE.md rule 4) | 16-26 h |
| 2.6 | Feedback layer | Prefer the user's word after 1 correction; swap automatically after the same correction twice (undoable), **underlined** so swaps are visible. Corrections are global and apply from now on (not to earlier text). Later: limit a correction to one PDF or a group of PDFs | 16-28 h |
| 2.7 | Event logging | Recognitions, corrections, accepts, latency (local only) | 6-10 h |
| 2.8 | Export with text (rest of 1.4) | Invisible searchable text layer **on** by default; option to convert all ink, or chosen pages, to typed text | 12-20 h |
| 2.9 | Convert ink to typed text in the app | Late Phase 2 | 16-26 h |

**Phase 2 is done when** the owner writes on a PDF, sees live text,
corrects a word, and the same word written later is recognised correctly
more often. Unit tests cover the feedback layer.

## Phase 3: evaluation (2-3 weeks of real use)

1. **Replay harness** (10-18 h): re-run saved strokes through (a) the engine
   alone and (b) the engine plus the feedback layer; report word and
   character error rates. Uses the samples and the corrections already
   stored, so nothing new has to be written.
2. **Real use** (owner, 2-3 weeks): daily use with logging on. A weekly
   one-tap "progress report" screen (corrections per 100 words, how often
   the automatic swaps were right, latency) so the owner can see whether
   it is learning.
3. **Analysis** (6-10 h): held-out versus repeated vocabulary, corrections
   per 100 words over time, latency, engine time.
4. **Checks along the way:** battery use while writing; app size; opening
   times of big PDFs (already logged).

**GATE B:** owner decides from the report: keep the simple feedback layer,
move on to Phase 4, or change engine.

## Phase 4: personal model (only if GATE B says so)

As in `docs/design/correction-memory.md` (stages 2-3): export a clean
dataset, train a small re-scoring model off the tablet, run it on the
tablet as a second stage after the engine, re-run the Phase 3 evaluation.
**Licence and cost** of MyScript for anything beyond personal use must be
checked before this or any release.

## Phase 5: Windows

Reuse the UI, viewer, storage and feedback layer (all pure Dart where it
matters). Needs a Windows recogniser (MyScript has a Windows SDK; ML Kit
does not run there), a pen input check on Windows tablets, and CI for a
Windows build. Plan separately.

## Smaller items noted for later

- Icon outline width for accessibility (owner, 2026-10-11).
- Corrections limited to a PDF or group of PDFs (owner, future).
- Home-page picture: redraw on more events (e.g. after export) if useful.
