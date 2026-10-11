# Correction memory and personalisation: design

**Source:** the owner's design document "Handwriting Recognition: Training Pipeline and Correction Memory" (10 Oct 2026), kept unchanged in [`correction-memory-original.md`](correction-memory-original.md). This page records **how it applies to this project**. Where they differ, this page and CLAUDE.md win.

**Status:** adopted as the design for tasks 2.5 (correction store), 2.6 (feedback layer), 2.7 (event logging), Phase 3 (evaluation) and as input to the GATE B decision on Phase 4.

## Adopted as written

- One on-device SQLite log for recognition events, their candidate lists and the user's verdict. It feeds the re-ranker now and any training later.
- Tables in the spirit of the original: `sample` (raw strokes, resampled shape features, left context, recognizer, doc/page), `candidate` (ranked list, optional score), `correction` (predicted → corrected, kind), and the `confusion` and `word_prior` caches. The caches can be rebuilt from `correction` and are updated in the same transaction.
- **Log accepted words too**, not just fixes.
- Re-ranker that blends four signals: the recognizer's preference, similar past strokes ("neighbours"), the user's confusions, and the personal word prior. It needs no training and works from the first correction.
- **Injection:** a word the engine never offered is added only when at least 2 close neighbours agree on it.
- Guard against bad labels: ignore a correction undone within a few seconds, and let old corrections decay.
- **Never block the pen:** show the engine's answer immediately, re-rank off the UI thread, then swap in the result if it differs.
- Tune the weights (`W_*`, `TAU`, `INJECT_DIST`) with **leave-one-out** on the owner's own corrections. This becomes part of the Phase 3 replay harness.
- English only (multiple languages are out of scope for the MVP).

## Adjustments for this project

1. **Pure Dart, not Kotlin** (CLAUDE.md rule 3). The re-ranker, features and caches live in `lib/core/` so Windows can reuse them. Only the database driver differs per platform.
2. **Engine-neutral** (rule 2). The rank-based fallback is the normal case: MyScript Cloud returns no per-candidate scores, and ML Kit's can be missing. `sample.recognizer` stores the engine name. With MyScript, the personal word prior can also be sent as its `customLexicon`.
3. **The owner's learning rule is applied on top** (decided 2026-10-10): re-rank from the first correction, and **auto-replace once the same misread has been corrected to the same word twice**. This is driven by `confusion.n >= 2` for that pair in a similar context, and it's always undoable.
4. **Correction kinds:** `accepted`, `picked_candidate`, `typed` and **`rewritten`** (the owner chose "erase with the pen and rewrite"). For training, typed and rewritten fixes count more than silent acceptances.
5. **Units are words or stroke groups,** which depend on task 2.2 (stroke grouping). The sentence-level labelled samples from task 0.3 (`samples` table) stay as the fixed evaluation set.
6. **Storage format:** strokes are kept as JSON arrays `[x, y, t, pressure]` for now (as in task 0.3). They can switch to a compressed blob later without losing anything. `features` is a fixed-length, resampled and normalised shape vector, compared by brute force (fine for thousands of rows).
7. **Stages 2–3 (learned stroke embedding, own model with a personal adapter) stay behind GATE B.** CLAUDE.md lists custom model training as out of scope for the MVP, and the original Phase 4 was a smaller "candidate re-scoring model". Before going further:
   - **Licences:** IAM-OnDB is for non-commercial research. Check it, and ML Kit's and MyScript's terms, before any commercial use.
   - **Compute:** training needs a computer with a GPU, not the tablet or GitHub's free CI. Any upload of handwriting must be opt-in and encrypted.
   - **Data:** "a few hundred corrected words before an adapter helps" is an assumption to measure.

## Where each part lands in the plan

| Design part | Plan task |
|---|---|
| `sample`, `candidate`, `correction` tables; logging accepted/picked/typed/rewritten | 2.5 Correction store, 2.7 Event logging |
| Features, neighbour search, confusion/word-prior caches, re-ranker, injection, auto-replace rule | 2.6 Feedback layer |
| Leave-one-out tuning, engine-only vs engine + feedback CER/WER | 3.1 Replay harness, 3.3 Analysis |
| Learned embedding, own CTC model, personal adapter, IAM-OnDB | Phase 4, only if GATE B approves |
