"""Word-finder tests with made-up stroke pairs (no one's real data). Run
from the training folder: python -m unittest"""

import json
import unittest

import numpy as np

from wr_train import words
from wr_train.data import parse


def pair(gap, same, rules_join):
    # gap, overlap, secondsApart, touching, sizeRatio, smallMark, rulesJoin
    return {
        "features": [gap, 0.9, 0.2, 1.0 if gap <= 0 else 0.0, 0.1, 0.0,
                     1.0 if rules_join else 0.0],
        "sameWord": same,
        "document": 1,
    }


def wide_writer(n=200, seed=3):
    """Someone who leaves wide gaps inside words (about one letter height),
    which today's rules (join below 0.6) split; gaps between their words
    are about 2.5."""
    rng = np.random.default_rng(seed)
    pairs = []
    for i in range(n):
        if i % 3 == 0:
            g = float(rng.uniform(1.8, 3.2))
            pairs.append(pair(g, False, False))
        elif i % 3 == 1:
            g = float(rng.uniform(0.7, 1.3))
            pairs.append(pair(g, True, False))  # rules split it: wrong
        else:
            g = float(rng.uniform(-0.5, 0.5))
            pairs.append(pair(g, True, True))
    return pairs


def file(pairs, version=3):
    return {
        "format": "writing-recogniser-training-data",
        "version": version,
        "wordPairFeatures": words.FEATURES,
        "wordPairs": pairs,
    }


class WordFindingTests(unittest.TestCase):
    def test_reads_pairs_and_skips_odd_ones(self):
        data = parse(file([pair(1, True, False), {"features": [1, 2]}]))
        self.assertEqual(len(data.word_pairs), 1)
        self.assertTrue(data.word_pairs[0].same_word)
        self.assertEqual(data.word_pair_features, words.FEATURES)

    def test_starts_by_following_the_rules(self):
        w, b = words.train([])
        self.assertTrue(words.joins(pair(0, True, True)["features"], w, b))
        self.assertFalse(words.joins(pair(2, False, False)["features"], w, b))

    def test_learns_a_wide_writer_without_breaking_real_gaps(self):
        pairs = parse(file(wide_writer())).word_pairs
        r = words.cross_validate(pairs)
        self.assertEqual(r.pairs, 200)
        self.assertEqual(r.rules_wrong, 67)
        self.assertGreater(r.fixed, 55)
        self.assertLess(r.broken, 5)
        self.assertIn("helpful", words.verdict(r))

    def test_too_few_marks_says_so(self):
        pairs = parse(file(wide_writer(20))).word_pairs
        self.assertIn("Not enough", words.verdict(words.cross_validate(pairs)))

    def test_the_model_file_has_only_numbers(self):
        pairs = parse(file(wide_writer(60))).word_pairs
        w, b = words.train(pairs)
        m = words.model_file(w, b, words.cross_validate(pairs))
        self.assertEqual(len(m["weights"]), len(m["features"]))
        self.assertIsInstance(m["bias"], float)
        json.dumps(m)


if __name__ == "__main__":
    unittest.main()
