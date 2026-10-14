"""Word finding (task 4.5): which neighbouring strokes are one word,
learned from the user's "One word" marks (docs/design/word-finding-model.md).

A small logistic regression on the numbers the app works out for each pair
of strokes. It starts from "do what today's rules do" and moves away only
as far as the marks support."""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .data import WordPair

# The numbers, in the app's order (lib/core/word_pairs.dart).
FEATURES = [
    "gap",
    "overlap",
    "secondsApart",
    "touching",
    "sizeRatio",
    "smallMark",
    "rulesJoin",
]
# Starting weights and bias: follow today's rules (join when they do).
START = np.array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 4.0])
START_BIAS = -2.0
MIN_PAIRS = 30
MIN_RULES_WRONG = 5


def _arrays(pairs: list[WordPair]):
    x = np.array([p.features for p in pairs], dtype=float).reshape(
        len(pairs), len(FEATURES)
    )
    y = np.array([1.0 if p.same_word else 0.0 for p in pairs])
    return x, y


def train(pairs: list[WordPair], steps=400, rate=0.05, penalty=0.01):
    """Weights and bias (logistic, Adam, with a penalty pulling back
    towards today's rules)."""
    w, b = START.copy(), START_BIAS
    if not pairs:
        return w, b
    x, y = _arrays(pairs)
    n = len(pairs)
    theta = np.append(w, b)
    xb = np.hstack([x, np.ones((n, 1))])
    start = np.append(START, START_BIAS)
    m, v = np.zeros_like(theta), np.zeros_like(theta)
    for step in range(1, steps + 1):
        p = 1 / (1 + np.exp(-np.clip(xb @ theta, -30, 30)))
        grad = xb.T @ (p - y) / n + penalty * (theta - start)
        m = 0.9 * m + 0.1 * grad
        v = 0.999 * v + 0.001 * grad * grad
        mh, vh = m / (1 - 0.9**step), v / (1 - 0.999**step)
        theta -= rate * mh / (np.sqrt(vh) + 1e-8)
    return theta[:-1], float(theta[-1])


def joins(features, w, b) -> bool:
    return float(np.dot(features, w) + b) > 0


@dataclass
class Report:
    """How the model does on the user's marks, each pair judged by weights
    trained without it, compared with today's rules."""

    pairs: int = 0
    rules_right: int = 0
    model_right: int = 0
    rules_wrong: int = 0  # pairs today's rules get wrong
    fixed: int = 0  # ... of which the model gets right
    broken: int = 0  # pairs the rules get right but the model wrong

    def as_dict(self):
        return dict(self.__dict__)


def cross_validate(pairs: list[WordPair], folds=5, seed=7) -> Report:
    r = Report(pairs=len(pairs))
    rule = FEATURES.index("rulesJoin")
    for p in pairs:
        rules_ok = (p.features[rule] > 0.5) == p.same_word
        r.rules_right += rules_ok
        r.rules_wrong += not rules_ok
    if len(pairs) < folds:
        return r
    order = np.random.default_rng(seed).permutation(len(pairs))
    for f in range(folds):
        test = set(order[f::folds].tolist())
        w, b = train([p for k, p in enumerate(pairs) if k not in test])
        for k in test:
            p = pairs[k]
            ok = joins(p.features, w, b) == p.same_word
            rules_ok = (p.features[rule] > 0.5) == p.same_word
            r.model_right += ok
            r.fixed += ok and not rules_ok
            r.broken += rules_ok and not ok
    return r


def verdict(r: Report) -> str:
    if r.pairs < MIN_PAIRS or r.rules_wrong < MIN_RULES_WRONG:
        return (
            f"Not enough examples yet: {r.pairs} stroke pairs next to your "
            f'"One word" marks ({MIN_PAIRS} needed), {r.rules_wrong} of them '
            f"split wrongly by today's rules ({MIN_RULES_WRONG} needed). Use "
            '"One word" (select the strokes, then "Read as one word") when a '
            "word is split or joined wrongly, then try again."
        )
    if r.fixed > r.broken:
        return (
            f"The word finder looks helpful: of {r.rules_wrong} pairs today's "
            f"rules got wrong it gets {r.fixed} right, and it gets "
            f"{r.broken} wrong that the rules got right."
        )
    return (
        f"The word finder doesn't help yet: it fixes {r.fixed} pairs but "
        f"breaks {r.broken}. Don't use it; more marks may change that."
    )


def model_file(w, b, r: Report) -> dict:
    """Weights and counts only: no handwriting or text."""
    return {
        "format": "writing-recogniser-word-model",
        "version": 1,
        "features": FEATURES,
        "weights": [round(float(x), 6) for x in w],
        "bias": round(float(b), 6),
        "report": r.as_dict(),
    }
