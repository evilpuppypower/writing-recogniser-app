"""Reads the app's "Save training data" file (a zip with one JSON file)."""

from __future__ import annotations

import json
import zipfile
from dataclasses import dataclass, field

FORMAT = "writing-recogniser-training-data"
ENTRY = "training-data.json"

Strokes = list  # list of strokes; a stroke is a list of [x, y, t, pressure]


@dataclass
class Word:
    """A word read on a PDF page."""

    text: str
    engine: str
    candidates: list[str]
    corrected: bool
    previous: str
    strokes: Strokes
    document: int | None = None


@dataclass
class Correction:
    recognized: str
    corrected: str
    previous: str
    strokes: Strokes
    count: int = 1


@dataclass
class SampleWord:
    text: str
    previous: str
    strokes: Strokes


@dataclass
class TrainingData:
    version: int
    words: list[Word] = field(default_factory=list)
    corrections: list[Correction] = field(default_factory=list)
    sample_words: list[SampleWord] = field(default_factory=list)


class DataError(Exception):
    """The file isn't a training data file this program can read."""


def load(path: str) -> TrainingData:
    try:
        with zipfile.ZipFile(path) as z:
            raw = z.read(ENTRY)
    except (zipfile.BadZipFile, KeyError, OSError) as e:
        raise DataError(
            "This isn't a training data file from the app "
            f"(Settings > How well is it learning? > Save training data): {e}"
        ) from e
    doc = json.loads(raw.decode("utf-8"))
    return parse(doc)


def parse(doc: dict) -> TrainingData:
    if doc.get("format") != FORMAT:
        raise DataError("This isn't a training data file from the app.")
    data = TrainingData(version=int(doc.get("version", 1)))
    for w in doc.get("words", []):
        if not isinstance(w.get("text"), str) or not w.get("strokes"):
            continue
        data.words.append(
            Word(
                text=w["text"],
                engine=w.get("engine") or w["text"],
                candidates=[str(c) for c in w.get("candidates", [])],
                corrected=bool(w.get("corrected")),
                previous=w.get("previousWord", ""),
                strokes=w["strokes"],
                document=w.get("document"),
            )
        )
    for c in doc.get("corrections", []):
        if c.get("strokes"):
            data.corrections.append(
                Correction(
                    recognized=c.get("recognized", ""),
                    corrected=c.get("corrected", ""),
                    previous=c.get("previousWord", ""),
                    strokes=c["strokes"],
                    count=int(c.get("count", 1)),
                )
            )
    for s in doc.get("sampleWords", []):
        if s.get("strokes"):
            data.sample_words.append(
                SampleWord(
                    text=s.get("text", ""),
                    previous=s.get("previousWord", ""),
                    strokes=s["strokes"],
                )
            )
    return data
