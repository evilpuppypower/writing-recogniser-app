"""python -m wr_train [training-data.zip]

Trains the model and prints a plain report. Without a file name, asks for
the file with a window."""

from __future__ import annotations

import json
import sys
from pathlib import Path

from .data import DataError, load
from .model import Memory, cross_validate, examples, model_file, train, verdict


def _ask_for_file() -> str | None:
    try:
        import tkinter
        from tkinter import filedialog
    except ImportError:
        return None
    root = tkinter.Tk()
    root.withdraw()
    root.attributes("-topmost", True)  # in front of the console window
    path = filedialog.askopenfilename(
        title="Choose the training data file from the app",
        filetypes=[("Training data", "*.zip"), ("All files", "*.*")],
    )
    root.destroy()
    return path or None


def main(argv: list[str]) -> int:
    path = argv[0] if argv else _ask_for_file()
    if not path:
        print("No file chosen.")
        return 1
    try:
        data = load(path)
    except DataError as e:
        print(e)
        return 1
    if data.version < 2:
        print(
            "This file is from an older version of the app, which only saved "
            "corrections. Save the training data again from the new version."
        )
        return 1
    print(
        f"Read {len(data.words)} words from your PDFs, "
        f"{len(data.corrections)} corrections and "
        f"{len(data.sample_words)} practice words."
    )
    print("Training (this takes a few seconds to a few minutes)...")
    memory = Memory(data)
    exs = examples(data, memory)
    report = cross_validate(exs)
    weights = train(exs)
    out = Path(__file__).resolve().parent.parent / "output"
    out.mkdir(exist_ok=True)
    (out / "model.json").write_text(
        json.dumps(model_file(weights, report), indent=2), encoding="utf-8"
    )
    lines = [
        f"Words checked: {report.words}",
        f"  You corrected {report.corrected}. The model gets "
        f"{report.corrected_fixed} of them right "
        f"(the engine alone: {report.corrected_engine_right}).",
        f"  You left {report.unchecked} as they were. The model would "
        f"change {report.unchecked_changed} of them.",
        "",
        verdict(report),
        "",
        f"Saved: {out / 'model.json'} (weights only: no handwriting or text).",
    ]
    text = "\n".join(lines)
    (out / "report.txt").write_text(text + "\n", encoding="utf-8")
    print()
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
