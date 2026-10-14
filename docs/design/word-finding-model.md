# Word-finding model (task 4.5, owner's choice: option 2)

Which neighbouring strokes on a line are one word. Today the app decides with fixed rules (`lib/core/stroke_grouping.dart`: a gap narrower than about 0.6 letter heights joins, plus rules for dots and crossbars). This model learns, from the user's own "One word" marks, how their writing differs.

## Examples

`lib/core/word_pairs.dart`, `wordPairs(strokes)`, per page:

1. Group the strokes with today's rules, ignoring the marks.
2. On each line, sort the strokes left to right and take each neighbouring pair where at least one stroke carries a mark.
3. The answer: one word if both carry the same mark; otherwise a word boundary (the user drew the loop round the word, so its edge is a boundary).

The numbers for a pair (`wordPairFeatures`), from the two strokes' boxes and the line's letter height:

| Name | Meaning |
|---|---|
| gap | sideways gap in letter heights, -3..10 |
| overlap | share of the shorter one's height they share, 0..1 |
| secondsApart | ln(1 + seconds between them) |
| touching | 1 if they touch or overlap sideways |
| sizeRatio | ln(taller / shorter) |
| smallMark | 1 if either is dot-sized |
| rulesJoin | 1 if today's rules put them in one word |

The training file (version 3) carries these numbers and the answers only, in "wordPairs": no ink. PDFs are numbered, not named.

## Model

Logistic regression (`training/wr_train/words.py`): join when `weights · numbers + bias > 0`. It starts from "follow today's rules" (weight 4 on rulesJoin, bias -2) and a penalty pulls it back there, so a few marks can't swing it far.

## Report

Each pair is judged by a model trained without it (5-fold cross-validation). The report counts how many pairs today's rules and the model get right, how many of the rules' mistakes the model fixes, and how many right answers it breaks. It's called helpful only with at least 30 pairs, at least 5 rules mistakes, and more fixed than broken. The output (`output/word-model.json`) holds the weights, bias and counts only.

## Not yet

The app doesn't use the model. Using it (reading `word-model.json`, deciding each pair with the same numbers from the same Dart code) waits for GATE B and the owner's approval. Pairs are judged one at a time; a later version could also check whole words with the recogniser.
