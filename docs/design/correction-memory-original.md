# Handwriting Recognition: Training Pipeline and Correction Memory

## Architecture overview

ML Kit and a re-ranker handle recognition first; every correction lands in one SQLite log that later trains a personal model.

Strokes go to ML Kit, the re-ranker reorders its candidates using past fixes from SQLite, and each new correction is written back. In the later stage the same log tunes a personal model that replaces ML Kit.

## Training pipeline for your own model

Train a stroke-sequence CTC model first: it is the smallest model that recognises text straight from pen input, and it exports to a tablet-friendly runtime. Everything below uses public data and open tooling, so there is no dependency on MyScript.

1. **Data.** Use IAM-OnDB for English online handwriting (registration required; check its licence before any commercial use). Add CROHME later if you want math. Your own corrected samples from the app become the third source.
2. **Preprocessing.** Resample each stroke at a fixed arc-length, normalise line height and slant, and encode every point as (dx, dy, pen-up). Keep timing out of the first version; add pressure and velocity if the tablet supplies them.
3. **Augmentation.** Random slant, scale, point jitter, stroke dropout and stroke merging. This matters more than model size when the training set has only a few hundred writers.
4. **Model.** A small 1D-conv front end into 3 to 4 bidirectional LSTM layers (or a small Conformer), then a character-level CTC head. Aim for a few million parameters so inference stays interactive on a tablet.
5. **Training.** CTC loss, AdamW, length-bucketed batches. Split by writer, not by line, so the metric reflects unseen handwriting. Track character error rate (CER) and word error rate (WER).
6. **Decoding.** Greedy decoding for speed, then beam search with a character n-gram or word language model. Keep the N-best list: the re-ranker in the correction-memory sections needs it.
7. **Export.** PyTorch to ONNX, run with ONNX Runtime Mobile (or convert to TFLite), then int8 quantise and measure latency on the actual tablet.

Open question: do you need handwriting beyond English? That changes the character set and the dataset list.

## SQLite correction memory

Store every recognition event, its candidate list and the user's verdict. That one log feeds the re-ranker now and the fine-tuning set later, so log more than you think you need: raw strokes are the part you cannot recreate.

```sql
CREATE TABLE sample (
  id            INTEGER PRIMARY KEY,
  created_at    INTEGER NOT NULL,          -- unix ms
  doc_id        TEXT,
  page          INTEGER,
  strokes       BLOB NOT NULL,             -- compressed (x, y, t, pressure) points
  features      BLOB NOT NULL,             -- fixed-length resampled shape vector
  left_context  TEXT,                      -- previous recognised words
  recognizer    TEXT NOT NULL              -- e.g. 'mlkit-digitalink-en'
);

CREATE TABLE candidate (
  sample_id  INTEGER NOT NULL REFERENCES sample(id) ON DELETE CASCADE,
  rank       INTEGER NOT NULL,
  text       TEXT NOT NULL,
  score      REAL,                         -- NULL when the recognizer gives none
  PRIMARY KEY (sample_id, rank)
);

CREATE TABLE correction (
  id         INTEGER PRIMARY KEY,
  sample_id  INTEGER NOT NULL REFERENCES sample(id) ON DELETE CASCADE,
  predicted  TEXT NOT NULL,                -- what was shown
  corrected  TEXT NOT NULL,                -- what the user says it is
  kind       TEXT NOT NULL CHECK (kind IN ('accepted','picked_candidate','typed')),
  created_at INTEGER NOT NULL
);

CREATE TABLE confusion (
  predicted  TEXT NOT NULL,
  corrected  TEXT NOT NULL,
  n          INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (predicted, corrected)
);

CREATE TABLE word_prior (
  word       TEXT PRIMARY KEY,
  n_written  INTEGER NOT NULL DEFAULT 0,   -- times the user confirmed it
  n_rejected INTEGER NOT NULL DEFAULT 0    -- times it was shown and replaced
);

CREATE INDEX idx_correction_corrected ON correction(corrected);
CREATE INDEX idx_candidate_text       ON candidate(text);
CREATE INDEX idx_sample_created       ON sample(created_at);
```

- **Accepted events matter.** Log `accepted` rows too, not only fixes. They are the positive examples and let you compute how often each prediction is wrong.
- **`features` is the lookup key.** It lets you find past samples that look like the new stroke group without running a model. A few thousand rows can be scanned by brute force in Kotlin; add an approximate index only if that gets slow.
- **`confusion` and `word_prior` are caches.** They can be rebuilt from `correction`, so update them in the same transaction as the insert and rebuild whenever the logic changes.
- **Keep it on-device.** Handwriting is personal data. If you later sync it, encrypt it and make it opt-in.

## Re-ranking logic

The re-ranker rescores the recognizer's candidates by blending four signals: the recognizer's own preference, how similar strokes were corrected before, the user's past confusions, and how often the user writes each word. It needs no training, so it works from the first correction.

```kotlin
data class Cand(val text: String, val recScore: Double?, val rank: Int)

fun rerank(strokes: StrokeGroup, cands: List<Cand>, ctx: String): List<Cand> {
    val feat = resampleFeatures(strokes)
    val neighbours = db.nearestSamples(feat, k = 5)     // brute-force scan, distance + corrected text
    val pool = cands.toMutableList()

    // 1. Inject: if close neighbours agree on a text the recognizer never offered, add it
    neighbours.filter { it.dist < INJECT_DIST }
        .groupBy { it.correctedText }
        .filter { it.value.size >= 2 && pool.none { c -> c.text == it.key } }
        .forEach { pool += Cand(it.key, null, rank = pool.size) }

    return pool.sortedByDescending { c ->
        // 2. Recognizer preference: use its score if present, else a rank-based prior
        val base = c.recScore?.let { ln(it) } ?: -0.7 * c.rank

        // 3. Neighbour evidence: closer, more recent corrections count more
        val nb = neighbours.filter { it.correctedText == c.text }
            .sumOf { exp(-it.dist / TAU) * recency(it.createdAt) }

        // 4. Confusion: how often the user turned the top guess into this text
        val conf = db.confusionRate(cands.first().text, c.text)

        // 5. Personal vocabulary and context
        val prior = db.wordLogPrior(c.text, ctx)         // smoothed n_written vs n_rejected

        W_BASE * base + W_NB * nb + W_CONF * conf + W_PRIOR * prior
    }
}
```

Things to get right before trusting it:

- **The recognizer score may be missing.** ML Kit's candidate score can be null, so the rank-based fallback above is not optional.
- **The candidate list is short.** The injection step is what lets a correction win when the right word was never offered. Require agreement from at least two neighbours so one stray fix cannot hijack a word.
- **Weights are guesses until measured.** Tune `W_*`, `TAU` and `INJECT_DIST` on your own corrected samples with leave-one-out evaluation: for each logged correction, rerank without it and check whether the right text rises to rank 1.
- **Guard against bad labels.** Ignore a correction when the user undoes it within a few seconds, and decay old ones so a changed writing habit can win over time.
- **Never block the pen.** Run the rerank off the UI thread and show the recognizer's answer immediately, then swap in the reranked text if it differs.

## Personalization loop and roadmap

Build in three stages, and move to the next only when the earlier one has stopped improving on your own corrections. Each stage reuses the same SQLite log.

1. **Re-ranker over ML Kit (MVP).** Log samples and corrections, apply the re-ranker above. Gate: leave-one-out top-1 accuracy on your corrections beats plain ML Kit.
2. **Learned stroke embedding.** Replace the hand-built `features` vector with an embedding from your own encoder, so neighbour matching generalises across slightly different writing of the same word. Gate: neighbour hits improve over the raw-feature version.
3. **Own model with a personal adapter.** Swap ML Kit for the model from the training pipeline. Freeze the shared encoder and fine-tune only a small adapter (for example LoRA layers or the last layer) on the user's corrected samples, mixed with replayed IAM-OnDB lines so the model does not forget general handwriting. Gate: accept a new adapter only if CER on a held-out slice of the user's samples improves and CER on the general set does not regress.

Risks worth planning for:

- **Too little data per user.** A few hundred corrected words is a reasonable first guess for when an adapter can help, but treat that as an assumption to measure, not a fact.
- **Noisy labels.** Users accept wrong text without noticing. Weight explicit typed corrections above silent acceptances when building the training set.
- **Licences.** Confirm the licence of every dataset and of ML Kit's terms before shipping anything commercial.
- **Privacy.** Train on-device or on a server you control, and make any upload opt-in.
