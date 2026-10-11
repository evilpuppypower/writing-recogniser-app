# Project status

_Snapshot: 11 October 2026. Update this page at the end of each round of work._

Read with: [CLAUDE.md](../CLAUDE.md) (rules and conventions), [PLAN.md](PLAN.md) (tasks and gates), [DECISIONS.md](DECISIONS.md) (every decision with its date and reason), [design/correction-memory.md](design/correction-memory.md) (how corrections will improve recognition).

## Where we are

| Phase / task | State |
|---|---|
| 0.1 Project setup | ✅ Done. Flutter Android app, lean CI with a launch check, APK per PR, signed with the owner's key |
| 0.2 PDF spike | ✅ Done. Owner confirmed smooth zoom/scroll and a locked overlay |
| 0.3 Recognition spike | ✅ Done. Three engines (ML Kit, MyScript Cloud, MyScript offline), sample recorder, GATE A report |
| **GATE A** | ⏸ **Undecided.** Owner runs the GATE A report on the tablet and chooses the engine |
| 1.1 PDF import and viewer | ✅ Done (1.1a viewer with Go to page, 1.1b library cards show where you left off). 1.1c multi-page previews was closed without merging |
| 1.2 Pen layer | ✅ Done (1.2a–1.2g): pen, highlighter, eraser (whole or partial), undo/redo, hold-to-snap lines, arrows, toolbar, favourites, pressure |
| 1.3 Annotation storage | ✅ Done. 1.3a autosaves ink; 1.3b keeps annotated PDFs and keeps ink when a copy is deleted |
| 1.4 Export | 🔄 Partly done. 1.4a exports a new PDF with ink drawn in. Share sheet, searchable text layer and auto-convert wait for GATE A |
| Phase 2 (recognition + learning from corrections) | Not started. Waits for GATE A. Design adopted (correction-memory.md) |
| Phases 3–5 | Not started |

Phase 1 work started before GATE A with the owner's approval, because the viewer, pen and storage don't depend on the engine.

## What the app does today

**Home page**
- **Open a PDF from this tablet** opens Android's picker, then a copy is imported into the app, with a progress bar, time left and Cancel. The original is never changed.
- **Handwriting test**: see below.
- **Pinned** and **Recent** PDFs (unlimited) as cards showing the first page and where you left off. ✓ means a copy is stored and the PDF opens instantly; 📌 means pinned. PDFs you've written on are pinned automatically ("Kept because it has your ink"). Long-press for Pin/Unpin and Remove from Recent.
- The build stamp in the owner's local time, at the bottom.

**PDF viewer**
- Smooth zoom and scroll (pdfrx/PDFium), including very large files. Fingers always scroll and zoom.
- Page number with **Go to page**; each PDF reopens on the page where you left it.
- Scroll tab with the page number (slim see-through bar by default).
- **Writing with the pen** on any page, locked to the page at any zoom:
  - Pen and Highlighter, with colour and size (tap the selected tool again). Tool icons show the current colour.
  - Eraser: whole strokes or only where you rub, with a size and an outline that follows the pen. The pen side button erases too.
  - Undo and Redo (up to 200 steps while the PDF is open).
  - Hold the pen still for 0.5 s to snap a straight line; Arrowheads switch for straight and curved arrows.
  - Pressure changes thickness (strength set in Settings).
  - Toolbar at the top or either side (Settings), plus a floating favourites bar of up to 8 pinned pens.
- **Ink is saved automatically** shortly after each stroke and when leaving or switching apps, and comes back editable when the PDF reopens. The PDF file is never changed.
- **Export**: makes a new PDF with your ink drawn in and asks where to save it.

**Settings**
- App colour: Match system (Material You) or 5 fixed colours, with dark mode. Message colours.
- Scroll tab when idle, and the slim bar's see-through level.
- Pen toolbar position.
- Handwriting: recognition pause (0.3–2 s, default 0.8 s), writing hand and box width, pressure strength.
- MyScript Cloud keys.
- Storage:
  - keep copies of the last 1–10 PDFs, plus pinned ones and ones with ink, with current space used,
  - **Manage stored copies** (pin or delete each, with "Don't ask again"),
  - **Keep my ink when a stored PDF is deleted** (on by default; the delete message has an "Also delete my ink" tick box),
  - **Delete ALL stored copies**, with a warning.

**Handwriting test (task 0.3)**
- **Record labelled samples:** copy prompted sentences or write freely and type what you wrote. Pen hover between strokes is recorded too.
- **Saved samples:** review, delete, and **Back up / Restore** as a `.zip` file saved anywhere.
- **Live recognition:** pen only, side button erases. Shows the best guess, other guesses and a timing breakdown (pause, engine, drawing). Switch between **ML Kit** (on tablet), **MyScript offline** (on tablet) and **MyScript Cloud** (sends strokes only).
- **GATE A report:** runs the samples through each engine and shows character/word error rates, perfect samples, speed, failures, the worst misreadings and per-sample detail, with a **Copy report** button.

## Work so far

- Phase 0.1–0.2: project, CI, app ID, PDF spike, importer, Settings, colours, stored copies, home library
- Task 0.3: writing canvas and samples, ML Kit, MyScript Cloud, GATE A report
- Docs: this status page and the correction-memory design
- Fixes: launch crash, launch diagnostics and the CI launch check, ML Kit model download
- Builds signed with the owner's key so updates keep the app's data
- Task 0.3 extras: backups (later .zip), MyScript offline engine, timing breakdown, per-sample report, writing hand/box/pressure settings, pen hover
- Task 1.1: viewer with Go to page; library shows where you left off
- Task 1.2: pen on PDF, tools and toolbar, partial eraser, undo, lines and arrows, fixes from testing, pressure setting on the PDF pen
- Task 1.3: ink autosave; annotated PDFs kept, ink kept on delete
- Task 1.4a: export a PDF with ink drawn in

**Tests:** 215 automated tests on `main`: unit, widget, real SQLite, and real PDFium for export. CI runs `flutter analyze`, `flutter test`, builds a signed release arm64 APK named with its build number, and runs the launch check.

## Waiting on the owner

1. **Test export on the tablet** (steps are in the export PR).
2. **GATE A:** run the GATE A report on your samples, paste it into the chat, and choose ML Kit, MyScript (offline or Cloud), or more evaluation. This unblocks the rest of 1.4 and all of Phase 2.

## Known limitations and follow-ups

- **Rest of task 1.4** (share sheet, searchable text layer, convert handwriting at export) needs the GATE A engine.
- PDF copies, including annotated ones, live in the app cache, which Android may clear when very low on space. The ink itself is in the database and survives; the PDF would need reopening from the tablet.
- MyScript Cloud keys are stored in app-private preferences, which is fine for testing. Move them to Android's encrypted storage if MyScript Cloud is kept.
- Android limits kept file access to about 512 files, so the very oldest Recent PDFs may need picking again.
- Undo history resets each time a PDF is opened (saved ink stays editable).
- Pen hover is recorded for samples, not yet for PDF ink.
