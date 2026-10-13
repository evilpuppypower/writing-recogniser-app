"""The numbers the model looks at (docs/design/rescoring-model.md). The app
must compute exactly the same ones, so keep this in step with that note."""

from __future__ import annotations

import math
import re

import numpy as np

SHAPE_POINTS = 32

FEATURES = [
    "engineRank",
    "engineTop",
    "wordPrior",
    "afterPrevious",
    "correctedTo",
    "shapeMatch",
    "lengthRatio",
    "lengthFit",
]

_EDGE_PUNCTUATION = re.compile(r"^[^\w']+|[^\w']+$")


def norm(word: str) -> str:
    """A word for comparing: lower case, without surrounding punctuation."""
    return _EDGE_PUNCTUATION.sub("", word.strip().lower())


def _points(strokes) -> np.ndarray:
    pts = [p[:2] for s in strokes for p in s]
    return np.asarray(pts, dtype=float).reshape(-1, 2)


def shape_vector(strokes) -> np.ndarray | None:
    """The ink's shape as 64 numbers of total length 1; None if there's no
    ink."""
    p = _points(strokes)
    if len(p) == 0:
        return None
    if len(p) == 1:
        p = np.vstack([p, p])
    seg = np.sqrt(((p[1:] - p[:-1]) ** 2).sum(axis=1))
    dist = np.concatenate([[0.0], np.cumsum(seg)])
    total = dist[-1]
    if total <= 0:
        resampled = np.repeat(p[:1], SHAPE_POINTS, axis=0)
    else:
        at = np.linspace(0.0, total, SHAPE_POINTS)
        resampled = np.column_stack(
            [np.interp(at, dist, p[:, 0]), np.interp(at, dist, p[:, 1])]
        )
    resampled = resampled - resampled.mean(axis=0)
    height = max(p[:, 1].max() - p[:, 1].min(), 1e-6)
    v = (resampled / height).reshape(-1)
    length = np.linalg.norm(v)
    if length == 0:
        return None
    return v / length


def length_ratio(strokes, word: str) -> float:
    """ln(ink width / height) - ln(letters): about the same number for every
    word in one person's writing (their letters' proportions), so far from
    their usual value means the word has the wrong length."""
    p = _points(strokes)
    letters = len(norm(word))
    if len(p) == 0 or letters == 0:
        return 0.0
    width = max(p[:, 0].max() - p[:, 0].min(), 1e-6)
    height = max(p[:, 1].max() - p[:, 1].min(), 1e-6)
    return math.log(width / height) - math.log(letters)


def length_fit(strokes, word: str) -> float:
    """-(length_ratio)^2. With [length_ratio] the model learns the user's
    usual letter proportions (where the best fit is)."""
    d = length_ratio(strokes, word)
    return -(d * d)
