"""Turns PaddleOCR's official models into the ONNX files the app reads
scanned PDFs with (owner, 2026-10-23), so the app depends on no one else's
copy. Run by .github/workflows/ocr-models.yml, by hand only.

For each model in sources.txt: download it, check its pinned SHA-256,
convert it with PaddleOCR's own converter (paddle2onnx), and check the
result:
  - ONNX Runtime and PaddlePaddle give the same answer for the same input
    (the conversion changed nothing);
  - the text finder finds a line on a made-up page, and the reader reads
    a made-up line of text as it was written;
  - the reader takes several lines at once (the app reads 6 at a time).
The reader's alphabet is taken from the model's own settings, so it always
matches it.

Two steps, so the converting can run with no network (see the workflow):
  fetch WORK      downloads the archives into WORK and checks their
                  fingerprints; exits non-zero if any isn't pinned yet.
  build WORK OUT  checks the fingerprints again, converts and checks, and
                  writes to OUT: the .onnx files, the alphabet, SHA256SUMS
                  and NOTES.md (where each file came from, with what).
                  Nothing is written if any check fails.

Usage: python -I tool/ocr_models/convert.py fetch WORK
       python -I tool/ocr_models/convert.py build WORK OUT
"""

import hashlib
import json
import pathlib
import subprocess
import sys
import tarfile
import tempfile
import urllib.request


# The converter's libraries are loaded only by "build" (see _load): the
# download step, which has network, runs none of their code.
np = onnx = ort = paddle_infer = yaml = Image = ImageDraw = ImageFont = None


def _load():
    global np, onnx, ort, paddle_infer, yaml, Image, ImageDraw, ImageFont
    import numpy as np
    import onnx
    import onnxruntime as ort
    import paddle.inference as paddle_infer
    import yaml
    from PIL import Image, ImageDraw, ImageFont

HERE = pathlib.Path(__file__).resolve().parent
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
MAX_DOWNLOAD = 400 * 1024 * 1024
# A made-up line for the reader: letters, digits and a space.
SAMPLE = "Scanned page 2026"


def sources():
    out = []
    for line in (HERE / "sources.txt").read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        name, kind, url, sha = (p.strip() for p in line.split("|"))
        assert kind in ("det", "rec"), f"{name}: unknown kind {kind}"
        assert url.startswith("https://"), f"{name}: not an https address"
        out.append((name, kind, url, sha.lower()))
    return out


def download(url, to):
    h = hashlib.sha256()
    size = 0
    with urllib.request.urlopen(url, timeout=120) as r, open(to, "wb") as f:
        while chunk := r.read(1 << 20):
            size += len(chunk)
            if size > MAX_DOWNLOAD:
                raise SystemExit(f"{url}: larger than {MAX_DOWNLOAD} bytes")
            h.update(chunk)
            f.write(chunk)
    return h.hexdigest()


def model_dir(root):
    """The folder in the archive holding inference.json/.pdiparams."""
    found = [p.parent for p in root.rglob("inference.pdiparams")]
    if len(found) != 1:
        raise SystemExit(f"{root}: expected one model, found {len(found)}")
    return found[0]


def convert(src, out):
    graph = "inference.json" if (src / "inference.json").exists() else "inference.pdmodel"
    subprocess.run(
        [
            # The converter's own command, from the same environment.
            str(pathlib.Path(sys.executable).parent / "paddle2onnx"),
            "--model_dir", str(src),
            "--model_filename", graph,
            "--params_filename", "inference.pdiparams",
            "--save_file", str(out),
            "--enable_onnx_checker", "True",
        ],
        check=True,
    )
    onnx.checker.check_model(str(out))


def paddle_run(src, x):
    graph = "inference.json" if (src / "inference.json").exists() else "inference.pdmodel"
    config = paddle_infer.Config(str(src / graph), str(src / "inference.pdiparams"))
    config.disable_gpu()
    # Plain maths, so the answers can be compared closely.
    config.disable_mkldnn()
    p = paddle_infer.create_predictor(config)
    i = p.get_input_handle(p.get_input_names()[0])
    i.reshape(list(x.shape))
    i.copy_from_cpu(x)
    p.run()
    return p.get_output_handle(p.get_output_names()[0]).copy_to_cpu()


def onnx_session(path):
    return ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])


def onnx_run(session, x):
    return session.run(None, {session.get_inputs()[0].name: x})[0]


def same(name, a, b):
    if a.shape != b.shape:
        raise SystemExit(f"{name}: shapes differ, {a.shape} vs {b.shape}")
    diff = float(np.max(np.abs(a.astype(np.float64) - b.astype(np.float64))))
    print(f"{name}: largest difference from PaddlePaddle {diff:.2e}")
    if diff > 1e-3:
        raise SystemExit(f"{name}: ONNX answer differs from PaddlePaddle's")


def _font(size):
    try:
        return ImageFont.truetype(FONT, size)
    except OSError:
        return ImageFont.load_default(size=size)


def page_image():
    """A white page with three lines of black text (red, green, blue)."""
    img = Image.new("RGB", (960, 640), "white")
    d = ImageDraw.Draw(img)
    font = _font(36)
    for i, line in enumerate(["The quick brown fox", "jumps over 13 lazy dogs", SAMPLE]):
        d.text((60, 80 + i * 160), line, fill="black", font=font)
    return img


def det_input(img):
    # As OcrMath.detectionInput: ImageNet normalisation, sides a multiple
    # of 32, blue-green-red channels.
    a = np.asarray(img, dtype=np.float32)[:, :, ::-1] / 255.0
    mean = np.array([0.485, 0.456, 0.406], np.float32)
    std = np.array([0.229, 0.224, 0.225], np.float32)
    a = (a - mean) / std
    return np.ascontiguousarray(a.transpose(2, 0, 1)[None])


def rec_input(text, width=320):
    """[text] as a line image for the reader: 48 high, -1..1."""
    font = _font(32)
    w = int(font.getlength(text)) + 16
    img = Image.new("RGB", (w, 48), "white")
    ImageDraw.Draw(img).text((8, 6), text, fill="black", font=font)
    img = img.resize((min(width, w), 48))
    a = np.asarray(img, dtype=np.float32)[:, :, ::-1] / 255.0
    a = (a - 0.5) / 0.5
    out = np.zeros((3, 48, width), np.float32)
    out[:, :, : a.shape[1]] = a.transpose(2, 0, 1)
    return out


def decode(probs, alphabet):
    """As OcrMath.decode: CTC, blank first, space last if one more class."""
    space = probs.shape[-1] == len(alphabet) + 2
    text, last = [], -1
    for best in probs.argmax(-1):
        if best != 0 and best != last:
            text.append(alphabet[best - 1] if best - 1 < len(alphabet) else (" " if space else ""))
        last = best
    return "".join(text).strip()


def alphabet_of(src):
    cfg = yaml.safe_load((src / "inference.yml").read_text(encoding="utf-8"))
    chars = (cfg.get("PostProcess") or {}).get("character_dict")
    if not chars:
        raise SystemExit(f"{src}: no character_dict in inference.yml")
    chars = [str(c) for c in chars]
    if any("\n" in c or "\r" in c for c in chars):
        raise SystemExit(f"{src}: a character holds a line break")
    return chars


def check_det(name, src, path):
    x = det_input(page_image())
    s = onnx_session(path)
    got = onnx_run(s, x)
    same(name, got, paddle_run(src, x))
    found = (got[0, 0] > 0.3).mean()
    print(f"{name}: text found on {found:.1%} of the made-up page")
    if not 0.02 < found < 0.6:
        raise SystemExit(f"{name}: didn't find the text on the made-up page")


def check_rec(name, src, path, alphabet):
    s = onnx_session(path)
    one = rec_input(SAMPLE)[None]
    got = onnx_run(s, one)
    same(name, got, paddle_run(src, one))
    classes = got.shape[-1]
    if classes not in (len(alphabet) + 1, len(alphabet) + 2):
        raise SystemExit(f"{name}: {classes} classes for {len(alphabet)} characters")
    read = decode(got[0], alphabet)
    print(f"{name}: read {read!r} (written {SAMPLE!r})")
    if read.replace(" ", "").lower() != SAMPLE.replace(" ", "").lower():
        raise SystemExit(f"{name}: misread the made-up line")
    # Several lines at once, each read as on its own.
    lines = ["Scanned", "page 2026", SAMPLE, "fox"]
    batch = np.stack([rec_input(t) for t in lines])
    many = onnx_run(s, batch)
    for i in range(len(lines)):
        alone = onnx_run(s, batch[i : i + 1])[0]
        if np.max(np.abs(many[i] - alone)) > 1e-3:
            raise SystemExit(f"{name}: a line reads differently in a batch")
    print(f"{name}: reads {len(lines)} lines at once")


def fetch(work):
    """Downloads every archive into [work]; every fingerprint is checked
    before anything is converted."""
    work.mkdir(parents=True, exist_ok=True)
    unpinned = []
    for name, kind, url, sha in sources():
        got = download(url, work / f"{name}.tar")
        print(f"{name}: SHA-256 {got}")
        if not sha:
            unpinned.append(name)
        elif got != sha:
            raise SystemExit(f"{name}: fingerprint changed (pinned {sha}); stopping")
    if unpinned:
        raise SystemExit(
            "Not pinned yet: " + ", ".join(unpinned)
            + ". Check the fingerprints above, pin them in sources.txt and run again."
        )


def build(work, out):
    _load()
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        raise SystemExit(f"{out}: not empty")
    tmp = pathlib.Path(tempfile.mkdtemp())
    files, notes = {}, []
    for name, kind, url, sha in sources():
        tar = work / f"{name}.tar"
        # Checked again: these are the files converted.
        if not sha or hashlib.sha256(tar.read_bytes()).hexdigest() != sha:
            raise SystemExit(f"{name}: archive doesn't match its pinned fingerprint")
        dest = tmp / name
        with tarfile.open(tar) as t:
            t.extractall(dest, filter="data")
        src = model_dir(dest)
        path = tmp / f"{kind}-{name}.onnx"
        convert(src, path)
        if kind == "det":
            check_det(name, src, path)
        else:
            alphabet = alphabet_of(src)
            check_rec(name, src, path, alphabet)
            d = tmp / f"dict-{name}.txt"
            d.write_text("\n".join(alphabet) + "\n", encoding="utf-8")
            files[d.name] = d
        files[path.name] = path
        notes.append(f"- `{path.name}`: from `{name}`, {url} (SHA-256 `{sha}`)")
    sums = []
    for fname, path in sorted(files.items()):
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        (out / fname).write_bytes(path.read_bytes())
        sums.append(f"{digest}  {fname}")
    (out / "SHA256SUMS").write_text("\n".join(sums) + "\n")
    versions = {
        m: __import__(m).__version__
        for m in ("paddle", "paddle2onnx", "onnx", "onnxruntime")
    }
    (out / "NOTES.md").write_text(
        "PaddleOCR's official models (Apache 2.0) converted to ONNX for the app's "
        "scanned-PDF reader, by tool/ocr_models/convert.py.\n\n"
        + "\n".join(notes)
        + "\n- `dict-*.txt`: the reader's alphabet, from its own `inference.yml`.\n\n"
        + "Converted with " + json.dumps(versions) + ". Each file was checked against "
        "PaddlePaddle's own answer and on made-up text.\n\nSHA-256:\n\n```\n"
        + "\n".join(sums) + "\n```\n"
    )
    print("\n".join(sums))


def main():
    args = sys.argv[1:]
    if len(args) == 2 and args[0] == "fetch":
        fetch(pathlib.Path(args[1]))
    elif len(args) == 3 and args[0] == "build":
        build(pathlib.Path(args[1]), pathlib.Path(args[2]))
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
