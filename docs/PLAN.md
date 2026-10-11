Work top to bottom. One task per branch/PR. Stop at each GATE and report to the owner.

Hour figures are rough estimates for planning, not deadlines.

Phase 0: Spikes (de-risk first)

0.1 Project setup (6-10 h)

Create the Flutter project (Android), CI workflow that runs analyze + test and builds a debug APK as a downloadable artifact.
Done when: CI is green on main; the APK installs and launches on the owner's tablet.

0.2 PDF spike (8-14 h)

Render a sample PDF with pdfrx. Overlay a simple widget on a page that stays aligned while zooming and scrolling.
Done when: owner confirms scrolling/zooming a large PDF feels smooth and the overlay stays locked to the page.

0.3 Recognition spike (10-16 h)

Blank canvas that captures stylus strokes; send to ML Kit after a short pause; show the top candidates and latency.
Include a screen that lets the owner record a labeled sample set (write a prompted sentence, store strokes + intended text).
Done when: owner can write sentences and see results; at least 25 labeled samples can be saved.

GATE A. Report: PDF overlay verdict, ML Kit baseline error rate on the owner's samples, typical latency. Owner decides: continue with ML Kit, or evaluate MyScript iink first.

Phase 1: Core app

1.1 PDF import and viewer (12-20 h): pick a file, open, page navigation. Includes a PDF library that keeps track of imported and edited PDFs (owner request); it replaces the spike's import cache and keeps the user-set storage limit and warning from Settings. 1.2 Pen layer (36-55 h): fixed pen toolbar movable between top and side, plus a floating favourites bar of pinned pens (type, colour, width); stroke capture with pressure, eraser (whole-stroke and partial, switchable; pen button = eraser), undo/redo, pen colours and thickness, highlighter, straight-line snapping (hold the pen still ~0.5 s at the end of a stroke), arrows (straight and curved), correct coordinate mapping at any zoom. pen writes; fingers scroll/zoom. 1.3 Annotation storage (14-24 h): save/reload strokes per PDF and page in PDF page coordinates; autosave after every stroke; annotated PDFs kept as a permanent copy in the library; ink from earlier sessions stays editable. 1.4 Export (14-26 h): written with PDFium (owner decision 2026-10-11); flattened PDF with annotations burned in, plus a searchable layer of recognised text; share sheet and save-to-folder; option to auto-convert unconverted handwriting to text at export.

Done when (phase): owner can import a PDF, annotate it, close and reopen the app with annotations intact, and export a PDF that shows them.
Phase 2: Recognition and feedback loop

2.1 Recognizer interface + ML Kit implementation (8-14 h) 2.2 Stroke grouping (20-34 h): group strokes into words/lines by position and timing; pass preceding text as context; pause-based triggering. 2.3 Live recognition display (12-22 h): small label under the ink; side panel of recognised text per page; later, convert ink to typed text at similar size. 2.4 Correction UI (14-24 h): tap a recognized word for a pop-up of alternatives; rewrite with the pen, or tap a button to type (keyboard opens). 2.5 Correction store (16-26 h): schema per CLAUDE.md rule 4, including raw strokes; tables and logging per docs/design/correction-memory.md. 2.6 Feedback layer (16-28 h): candidate re-ranking, substitution rules, context-aware matching (previous word). Re-rank after 1 correction; auto-replace after the same correction twice (undoable). 2.7 Event logging (6-10 h)

Done when (phase): owner writes on a PDF, sees live text, corrects a word, and the same word written later is recognized correctly more often. Unit tests cover the feedback layer.
Phase 3: Evaluation

3.1 Replay harness (10-18 h): replay saved strokes through (a) engine only, (b) engine + feedback layer; output word and character error rates. 3.2 Real use (owner): 2-3 weeks of daily use with logging on. 3.3 Analysis (6-10 h): report with held-out vs repeated-vocabulary results, corrections per 100 words over time, latency.

GATE B. Owner decides based on the report: keep the simple layer, consider MyScript, or proceed to Phase 4.

Phase 4: Personalization model (only if Gate B passes). Options are described in docs/design/correction-memory.md (stages 2-3: learned stroke embedding; own model with a personal adapter), including licence and compute caveats.

4.1 Export/clean dataset. 4.2 Train a small candidate re-scoring model offline. 4.3 TFLite on-device second stage. 4.4 Re-run evaluation against the Phase 3 baseline.

Phase 5: Windows (later)

Reuse the UI, PDF viewer, and storage. Provide a different Recognizer implementation for Windows (ML Kit does not run there). Plan separately.
