# Personal re-scoring model (Phase 4.2, preparation)

Preparation only (owner's choice B + C, 2026-10-13): the model is trained on the owner's laptop from the app's "Save training data" file. Nothing goes into the app's recognition until the owner has seen the GATE B report and approved it.

## What it does

For each handwritten word, the engine offers readings (best first). The model gives every *option* a score and picks the highest. The options are the engine's readings plus a few words the owner has written before (see below), so it can also fix a word the engine never offered. Each score is a weighted sum of a few numbers ("features"); training finds the weights that best pick what the owner really wrote. The result is a small JSON file of weights. The app can use it from pure Dart later (CLAUDE.md rule 3), with no machine-learning library on the tablet.

## Options for a word

1. The engine's own readings, in order (as the engine gave them: never re-ranked or changed by corrections).
2. Words this engine reading was corrected to before (the user's corrections).
3. The 3 words whose earlier ink looks most like this ink (shape, below).

Duplicates are merged (ignoring case). A word's own example is never used to describe itself (leave-one-out, with copies of the same ink treated as one), so training never "cheats". Corrections count once per correction.

## Features (per option)

| Name | Meaning |
|---|---|
| `engineRank` | 1 / (1 + its place in the engine's list), or 0 when the engine didn't offer it |
| `engineTop` | 1 if it is the engine's first reading |
| `wordPrior` | ln(1 + times the user has written this word) |
| `afterPrevious` | ln(1 + times it followed the previous word) |
| `correctedTo` | ln(1 + times the engine's first reading was corrected to it) |
| `shapeMatch` | highest similarity (−1..1) between this ink and the user's earlier ink of that word; 0 when there is none |
| `lengthRatio` | d = ln(w / h) − ln(letters), where w and h are the ink's width and height, each at least a tenth of the other, and d is kept within −3..3: about the same for every word of one person's writing |
| `lengthFit` | −d², so together with `lengthRatio` the model learns the user's usual letter proportions |

Words are compared ignoring case and surrounding punctuation.

## Ink shape

All strokes in writing order, joined into one path; resampled to 32 points evenly spaced along the path; moved so the points' average is (0, 0); scaled by the ink's height (at least 1e-6); the 64 numbers (x1, y1, ..., x32, y32) then scaled to length 1. Similarity is the dot product of two such vectors (y grows downward, as stored in the file).

## Training and the report

- Softmax over each word's options, weights fitted by gradient descent with a small L2 penalty.
- Examples: the file's `words` that have the engine's whole list of readings (`candidatesComplete`). Corrected words are certain; words left as shown count as right, with half the weight. Older words, `corrections` and `sampleWords` add to the user's word counts, corrections and ink, but aren't examples on their own.
- **Report** (5-fold cross-validation, so every word is judged by a model that didn't see it), in two groups, because only corrected words have a checked answer: of the words the user corrected, how many the model gets right (and the engine alone); of the words left as the app showed them, how many the model would change (counted as mistakes to be safe). It looks helpful only if it gets more corrected words right than it would change.
- Below 200 corrected-or-checked words the report says there isn't enough data yet.
