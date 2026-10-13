"""The options for each word, their features, training and the report
(docs/design/rescoring-model.md)."""

from __future__ import annotations

import json
from collections import Counter, defaultdict
from dataclasses import dataclass

import numpy as np

from .data import TrainingData
from .features import FEATURES, length_fit, length_ratio, norm, shape_vector

# Starting weights: just follow the engine. Training moves away from these
# only as far as the data supports (the penalty pulls back towards them).
START = np.array([2.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
SHAPE_NEIGHBOURS = 3
UNCHECKED_WEIGHT = 0.5
MIN_WORDS = 200
MIN_CORRECTED = 20


@dataclass
class Example:
    options: list[str]  # as shown, best engine reading first
    features: np.ndarray  # one row per option
    truth: int  # index of the right option, -1 if none of them
    engine: int  # index of the engine's first reading, -1 if not an option
    shown: int  # index of what the app showed (uncorrected words), or -1
    corrected: bool
    weight: float


class Memory:
    """What the user has written and corrected, with their ink, from which
    each example's features are computed without that example itself."""

    def __init__(self, data: TrainingData):
        self.entries = []  # (id, text, previous, vector)
        self.confusions = []  # (id, from, to, count)
        self.display = defaultdict(Counter)
        by_ink = {}
        # Copies of the same ink (e.g. a PDF imported twice) share one id,
        # so a copy can't give a word its own answer.
        self.word_ids = []
        for i, w in enumerate(data.words):
            wid = by_ink.setdefault(json.dumps(w.strokes), f"w{i}")
            self.word_ids.append(wid)
            self._add(wid, w.text, w.previous, w.strokes)
            if w.corrected and norm(w.engine) != norm(w.text):
                self.confusions.append((wid, norm(w.engine), w.text, 1))
        for j, c in enumerate(data.corrections):
            # The same correction is usually also one of the words: one id.
            cid = by_ink.get(json.dumps(c.strokes), f"c{j}")
            if cid.startswith("c"):
                self._add(cid, c.corrected, c.previous, c.strokes)
                # One per row: the app's "count" is a running total.
                self.confusions.append((cid, norm(c.recognized), c.corrected, 1))
        for k, s in enumerate(data.sample_words):
            self._add(f"s{k}", s.text, s.previous, s.strokes)

        self.ids = [e[0] for e in self.entries]
        vecs = [e[3] for e in self.entries]
        self.vectors = np.array(vecs) if vecs else np.zeros((0, 64))
        by_text = defaultdict(list)
        for n, e in enumerate(self.entries):
            by_text[e[1]].append(n)
        self.by_text = {t: np.array(i) for t, i in by_text.items()}
        self.word_counts = Counter(e[1] for e in self.entries)
        self.pair_counts = Counter((e[2], e[1]) for e in self.entries)
        self.confusion_counts = defaultdict(Counter)
        for _, f, t, n in self.confusions:
            self.confusion_counts[f][norm(t)] += n
        self.own = defaultdict(list)  # id -> its entries and confusions
        for n, e in enumerate(self.entries):
            self.own[e[0]].append(("entry", n))
        for cid, f, t, n in self.confusions:
            self.own[cid].append(("confusion", (f, norm(t), n)))

    def _add(self, eid, text, previous, strokes):
        v = shape_vector(strokes)
        t = norm(text)
        if v is None or not t:
            return
        self.entries.append((eid, t, norm(previous), v))
        self.display[t][text.strip()] += 1

    def shown(self, t: str) -> str:
        d = self.display.get(t)
        return d.most_common(1)[0][0] if d else t

    def example(
        self, wid, strokes, engine_list, previous, truth, corrected, shown=None
    ):
        """The options and features for one word, leaving out [wid]'s own
        ink and corrections."""
        own_entries = {n for kind, n in self.own.get(wid, []) if kind == "entry"}
        own_conf = Counter()
        for kind, x in self.own.get(wid, []):
            if kind == "confusion":
                own_conf[(x[0], x[1])] += x[2]
        prev = norm(previous)
        v = shape_vector(strokes)
        if v is None:
            return None  # no ink to judge
        # Similarity of this ink to every stored ink, without its own.
        if v is not None and len(self.vectors):
            sims = self.vectors @ v
            for n in own_entries:
                sims[n] = -np.inf
        else:
            sims = np.full(len(self.entries), -np.inf)

        def best_shape(t):
            idx = self.by_text.get(t)
            if idx is None:
                return None
            s = sims[idx].max()
            return None if s == -np.inf else float(s)

        def count(t):
            return self.word_counts[t] - sum(
                1 for n in own_entries if self.entries[n][1] == t
            )

        def after(t):
            return self.pair_counts[(prev, t)] - sum(
                1
                for n in own_entries
                if self.entries[n][1] == t and self.entries[n][2] == prev
            )

        top = norm(engine_list[0]) if engine_list else ""

        def corrected_to(t):
            return self.confusion_counts[top][t] - own_conf[(top, t)]

        # Options: the engine's readings, then the user's corrections of
        # its first reading, then the words whose ink looks most alike.
        options, seen = [], set()

        def offer(text):
            t = norm(text)
            if t and t not in seen:
                seen.add(t)
                options.append(text.strip())

        for c in engine_list:
            offer(c)
        for t, _ in self.confusion_counts[top].most_common():
            if corrected_to(t) > 0:
                offer(self.shown(t))
        if len(sims) and v is not None:
            best = {}
            near = min(SHAPE_NEIGHBOURS * 10, len(sims))
            top_n = np.argpartition(-sims, near - 1)[:near]
            for n in top_n[np.argsort(-sims[top_n])]:
                if sims[n] == -np.inf:
                    break
                t = self.entries[n][1]
                best.setdefault(t, sims[n])
                if len(best) >= SHAPE_NEIGHBOURS:
                    break
            for t in best:
                offer(self.shown(t))
        if not options:
            return None

        engine_norm = [norm(c) for c in engine_list]
        rows = []
        for o in options:
            t = norm(o)
            rank = engine_norm.index(t) if t in engine_norm else None
            shape = best_shape(t)
            rows.append(
                [
                    0.0 if rank is None else 1.0 / (1 + rank),
                    1.0 if rank == 0 else 0.0,
                    np.log1p(max(count(t), 0)),
                    np.log1p(max(after(t), 0)) if prev else 0.0,
                    np.log1p(max(corrected_to(t), 0)),
                    0.0 if shape is None else shape,
                    length_ratio(strokes, o),
                    length_fit(strokes, o),
                ]
            )
        truth_norm = norm(truth)
        truth_index = next(
            (k for k, o in enumerate(options) if norm(o) == truth_norm), -1
        )
        shown_norm = norm(truth if shown is None else shown)
        return Example(
            options=options,
            features=np.array(rows, dtype=float),
            truth=truth_index,
            engine=next((k for k, o in enumerate(options) if norm(o) == top), -1),
            shown=next(
                (k for k, o in enumerate(options) if norm(o) == shown_norm), -1
            ),
            corrected=corrected,
            weight=1.0 if corrected else UNCHECKED_WEIGHT,
        )


def examples(data: TrainingData, memory: Memory | None = None) -> list[Example]:
    """One example per word with the engine's whole list of readings (older
    words, with a partial list, only add to the memory)."""
    memory = memory or Memory(data)
    out = []
    for i, w in enumerate(data.words):
        if not w.complete or not w.candidates:
            continue
        e = memory.example(
            memory.word_ids[i],
            w.strokes,
            w.candidates,
            w.previous,
            w.text,
            w.corrected,
            shown=w.text,
        )
        if e is not None:
            out.append(e)
    return out


def _stack(exs: list[Example]):
    """The examples as padded arrays (words x options x features), so
    training works on all of them at once."""
    k = max(len(e.options) for e in exs)
    f = np.zeros((len(exs), k, len(FEATURES)))
    mask = np.zeros((len(exs), k), dtype=bool)
    for i, e in enumerate(exs):
        f[i, : len(e.options)] = e.features
        mask[i, : len(e.options)] = True
    truth = np.array([e.truth for e in exs])
    weight = np.array([e.weight for e in exs])
    return f, mask, truth, weight


def train(exs: list[Example], steps=400, rate=0.05, penalty=0.01) -> np.ndarray:
    """Weights that best pick the right option (softmax, weighted, with a
    penalty pulling back towards just following the engine)."""
    w = START.copy()
    usable = [e for e in exs if e.truth >= 0 and len(e.options) > 1]
    if not usable:
        return w
    f, mask, truth, weight = _stack(usable)
    weight = weight / weight.sum()
    target = np.zeros(mask.shape)
    target[np.arange(len(usable)), truth] = 1.0
    m, v = np.zeros_like(w), np.zeros_like(w)
    for step in range(1, steps + 1):
        s = np.where(mask, f @ w, -np.inf)
        p = np.exp(s - s.max(axis=1, keepdims=True))
        p /= p.sum(axis=1, keepdims=True)
        grad = penalty * (w - START) + np.einsum(
            "n,nkf,nk->f", weight, f, p - target
        )
        # Adam: steady steps whatever the features' sizes.
        m = 0.9 * m + 0.1 * grad
        v = 0.999 * v + 0.001 * grad * grad
        mh, vh = m / (1 - 0.9**step), v / (1 - 0.999**step)
        w -= rate * mh / (np.sqrt(vh) + 1e-8)
    return w


def pick(e: Example, w: np.ndarray) -> int:
    return int(np.argmax(e.features @ w))


@dataclass
class Report:
    """How the model does, in two groups: the words the user corrected
    (their right answer is certain) and the words left as the app showed
    them (probably right, but nobody checked)."""

    words: int = 0
    corrected: int = 0
    corrected_fixed: int = 0  # corrected words the model gets right
    corrected_engine_right: int = 0  # ... the engine alone had right
    unchecked: int = 0
    unchecked_changed: int = 0  # left-as-shown words the model would change

    def as_dict(self):
        return dict(self.__dict__)


def cross_validate(exs: list[Example], folds=5, seed=7) -> Report:
    """Each word judged by weights trained without it."""
    r = Report(words=len(exs))
    r.corrected = sum(e.corrected for e in exs)
    r.unchecked = r.words - r.corrected
    if len(exs) < folds:
        return r
    order = np.random.default_rng(seed).permutation(len(exs))
    for f in range(folds):
        test = set(order[f::folds].tolist())
        w = train([e for k, e in enumerate(exs) if k not in test])
        for k in test:
            e = exs[k]
            choice = pick(e, w)
            if e.corrected:
                r.corrected_fixed += e.truth >= 0 and choice == e.truth
                r.corrected_engine_right += e.truth >= 0 and e.engine == e.truth
            else:
                r.unchecked_changed += choice != e.shown
    return r


def verdict(r: Report) -> str:
    if r.words < MIN_WORDS or r.corrected < MIN_CORRECTED:
        return (
            f"Not enough data yet: {r.words} words read ({MIN_WORDS} needed) "
            f"and {r.corrected} corrected ({MIN_CORRECTED} needed). Keep "
            "using the app and correcting misread words, then try again."
        )
    if r.corrected_fixed > r.unchecked_changed:
        return (
            f"The model looks helpful: it gets {r.corrected_fixed} of the "
            f"{r.corrected} words you corrected right, and would change "
            f"{r.unchecked_changed} of the {r.unchecked} words you left as "
            "they were (count those as mistakes to be safe)."
        )
    return (
        f"The model doesn't help yet: it gets {r.corrected_fixed} of your "
        f"{r.corrected} corrected words right but would change "
        f"{r.unchecked_changed} words you left as they were. Don't use it; "
        "more corrections may change that."
    )


def model_file(w: np.ndarray, r: Report) -> dict:
    """The trained model: weights and counts only, no handwriting or text."""
    return {
        "format": "writing-recogniser-rescoring-model",
        "version": 1,
        "features": FEATURES,
        "weights": [round(float(x), 6) for x in w],
        "report": r.as_dict(),
    }
