"""Tests with made-up handwriting (no one's real data). Run from the
training folder: python -m unittest"""

import io
import json
import math
import unittest
import zipfile

import numpy as np

from wr_train.data import DataError, load, parse
from wr_train.features import length_ratio, norm, shape_vector
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


def word(text, engine, candidates, corrected=False, previous="", seed=0):
    return {
        "text": text,
        "engine": engine,
        "candidates": candidates,
        "corrected": corrected,
        "previousWord": previous,
        "strokes": ink(text, wobble=2.0, seed=seed),
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
    everything else it reads right. Some "teh"s were corrected."""
    words, rng = [], np.random.default_rng(1)
    vocab = ["cat", "dog", "house", "tree", "river", "apple", "chair"]
    for i in range(n):
        if i % 4 == 0:
            words.append(
                word(
                    "the", "teh", ["teh", "the", "ten"],
                    corrected=i % 8 == 0, seed=i,
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
        # The engine gets every "the" wrong (75 of 300).
        self.assertEqual(report.engine_right, 225)
        self.assertGreater(report.fixed, 60)
        self.assertLess(report.broke, 5)
        self.assertIn("helps", verdict(report))

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
