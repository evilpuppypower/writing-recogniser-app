"""Tests with made-up handwriting (no one's real data). Run from the
training folder: python -m unittest"""

import io
import json
import math
import unittest
import zipfile

import numpy as np

from wr_train.data import DataError, load, parse
from wr_train.features import length_fit, length_ratio, norm, shape_vector
from wr_train.model import (
    Memory,
    cross_validate,
    examples,
    model_file,
    train,
    verdict,
)


def ink(word, wobble=0.0, seed=0):
    """Made-up ink for a word: a wavy line, one bump per letter, whose
    shape depends on the letters (so each word looks different)."""
    rng = np.random.default_rng(seed)
    pts = []
    for i, ch in enumerate(word):
        h = 30 + (ord(ch) % 7) * 5
        for k in range(6):
            x = i * 20 + k * 3
            y = 50 - h * math.sin(math.pi * k / 5) + rng.normal(0, wobble)
            pts.append([x, y, 1000 + i * 100 + k * 10, 0.5])
    return [pts]


def word(
    text, engine, candidates, corrected=False, previous="", seed=0,
    auto=False, complete=True, strokes=None,
):
    return {
        "text": text,
        "engine": engine,
        "candidates": candidates,
        "candidatesComplete": complete,
        "corrected": corrected,
        "autoReplaced": auto,
        "previousWord": previous,
        "strokes": strokes or ink(text, wobble=2.0, seed=seed),
    }


def doc(words, corrections=(), sample_words=(), version=2):
    return {
        "format": "writing-recogniser-training-data",
        "version": version,
        "words": list(words),
        "corrections": list(corrections),
        "sampleWords": list(sample_words),
    }


class FeatureTests(unittest.TestCase):
    def test_norm(self):
        self.assertEqual(norm(' "Hello," '), "hello")
        self.assertEqual(norm("don't"), "don't")

    def test_shape_vector_is_unit_length_and_size_free(self):
        v = shape_vector(ink("cat"))
        self.assertEqual(v.shape, (64,))
        self.assertAlmostEqual(float(np.linalg.norm(v)), 1.0)
        # The same word written twice as big looks the same.
        big = [[[x * 2, y * 2, t, p] for x, y, t, p in s] for s in ink("cat")]
        self.assertAlmostEqual(float(shape_vector(big) @ v), 1.0, places=6)
        # A different word looks less alike.
        self.assertLess(float(shape_vector(ink("elephant")) @ v), 0.95)
        self.assertIsNone(shape_vector([]))

    def test_length_ratio_is_steady_for_the_right_length(self):
        # One person's letters keep their proportions: the right word
        # length gives about the same value for short and long words.
        right = [length_ratio(ink(w), w) for w in ["at", "cat", "elephant"]]
        self.assertLess(max(right) - min(right), 0.3)
        self.assertGreater(
            abs(length_ratio(ink("elephant"), "an") - right[0]), 1.0
        )

    def test_length_numbers_stay_small_for_thin_ink(self):
        l = [[[0, 0, 0, 0.5], [0, 100, 10, 0.5]]]  # a straight "l"
        self.assertGreaterEqual(length_ratio(l, "l"), -3.0)
        self.assertGreaterEqual(length_fit(l, "ll"), -9.0)


class DataTests(unittest.TestCase):
    def test_reads_the_apps_zip(self):
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:
            z.writestr("training-data.json", json.dumps(doc([word("a", "a", ["a"])])))
        buf.seek(0)
        data = load(buf)
        self.assertEqual(len(data.words), 1)

    def test_refuses_other_files(self):
        with self.assertRaises(DataError):
            parse({"format": "something else"})
        with self.assertRaises(DataError):
            load(io.BytesIO(b"not a zip"))


def misread_world(n=300):
    """The engine reads "the" as "teh" every time (and offers "the" second);
    everything else it reads right. Half the "teh"s the user corrected; the
    app already swapped the others (after earlier corrections)."""
    words, rng = [], np.random.default_rng(1)
    vocab = ["cat", "dog", "house", "tree", "river", "apple", "chair"]
    for i in range(n):
        if i % 4 == 0:
            fixed_by_user = i % 8 == 0
            words.append(
                word(
                    "the", "teh", ["teh", "the", "ten"],
                    corrected=fixed_by_user, auto=not fixed_by_user, seed=i,
                )
            )
        else:
            w = vocab[rng.integers(len(vocab))]
            words.append(word(w, w, [w, w[:-1] + "s"], seed=i))
    return parse(doc(words))


class ModelTests(unittest.TestCase):
    def test_options_never_use_a_words_own_ink(self):
        data = parse(doc([word("zebra", "zebra", ["zebra"], seed=1)]))
        ex = examples(data)
        # Only one zebra: there's no earlier ink of it to match.
        self.assertEqual(ex[0].options, ["zebra"])
        self.assertEqual(ex[0].features[0][5], 0.0)

    def test_learns_a_repeated_misreading_without_breaking_the_rest(self):
        data = misread_world()
        exs = examples(data, Memory(data))
        report = cross_validate(exs)
        self.assertEqual(report.words, 300)
        # 38 "the"s corrected by the user; the engine had none of them.
        self.assertEqual(report.corrected, 38)
        self.assertEqual(report.corrected_engine_right, 0)
        self.assertGreater(report.corrected_fixed, 30)
        # Words left as shown (including the app's own swaps) stay.
        self.assertLess(report.unchecked_changed, 5)
        self.assertIn("helpful", verdict(report))

    def test_older_words_without_the_whole_list_are_not_examples(self):
        data = parse(
            doc(
                [
                    word("cat", "cat", ["cat"], seed=1),
                    word("cat", "cat", ["cat"], seed=2, complete=False),
                ]
            )
        )
        self.assertEqual(len(examples(data)), 1)

    def test_copies_of_the_same_ink_dont_give_away_the_answer(self):
        same = ink("zebra", wobble=1.0, seed=3)
        data = parse(
            doc(
                [
                    word("zebra", "zebra", ["zebra"], strokes=same),
                    word("zebra", "zebra", ["zebra"], strokes=same),
                ]
            )
        )
        for e in examples(data):
            self.assertEqual(e.features[0][5], 0.0, "no shape match to itself")

    def test_corrections_count_once_each(self):
        c = {
            "recognized": "teh", "corrected": "the", "previousWord": "",
            "strokes": ink("the", seed=9), "count": 3,
        }
        data = parse(
            doc([word("the", "teh", ["teh", "the"], seed=1)], corrections=[c])
        )
        ex = examples(data)[0]
        the = [norm(o) for o in ex.options].index("the")
        self.assertAlmostEqual(ex.features[the][4], math.log(2))

    def test_too_little_data_says_so(self):
        data = misread_world(40)
        report = cross_validate(examples(data))
        self.assertIn("Not enough data", verdict(report))

    def test_the_model_file_has_no_text_or_ink(self):
        data = misread_world(60)
        exs = examples(data)
        m = model_file(train(exs), cross_validate(exs))
        text = json.dumps(m)
        for secret in ["the", "teh", "house"]:
            self.assertNotIn(f'"{secret}"', text)
        self.assertEqual(len(m["weights"]), len(m["features"]))


if __name__ == "__main__":
    unittest.main()
