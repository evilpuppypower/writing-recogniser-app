package com.writingrecogniser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;

/**
 * The arithmetic around the PaddleOCR models (owner, 2026-10-17: reading
 * scanned PDFs with PaddleOCR), apart from running them: preparing a page
 * image for the text finder (detection), turning its answer into boxes,
 * preparing each box for the reader (recognition), and turning the
 * reader's answer into text. Plain Java with no Android parts, so it's
 * tested off the tablet; OcrEngine.kt runs the models with ONNX Runtime.
 *
 * Follows PaddleOCR's own steps (DB text detection, CTC recognition), with
 * upright boxes: scanned pages are nearly always straight.
 */
public final class OcrMath {
    private OcrMath() {}

    /** A model input: values in channel, row, column order, and its size. */
    public static final class Input {
        public final float[] data;
        public final int width, height;

        Input(float[] data, int width, int height) {
            this.data = data;
            this.width = width;
            this.height = height;
        }
    }

    /** A line of text found: its box in the page image and what it says. */
    public static final class Line {
        public final int left, top, right, bottom;
        public String text = "";
        public float confidence = 0;

        public Line(int left, int top, int right, int bottom) {
            this.left = left;
            this.top = top;
            this.right = right;
            this.bottom = bottom;
        }
    }

    private static final float[] DET_MEAN = {0.485f, 0.456f, 0.406f};
    private static final float[] DET_STD = {0.229f, 0.224f, 0.225f};

    /** Bilinear sample of channel [c] (0 = blue, 1 = green, 2 = red) of the
     * ARGB image at (x, y). */
    private static float sample(int[] argb, int w, int h, float x, float y, int c) {
        x = Math.max(0, Math.min(w - 1, x));
        y = Math.max(0, Math.min(h - 1, y));
        int x0 = (int) x, y0 = (int) y;
        int x1 = Math.min(w - 1, x0 + 1), y1 = Math.min(h - 1, y0 + 1);
        float fx = x - x0, fy = y - y0;
        int shift = c * 8;
        float a = (argb[y0 * w + x0] >> shift) & 0xff;
        float b = (argb[y0 * w + x1] >> shift) & 0xff;
        float d = (argb[y1 * w + x0] >> shift) & 0xff;
        float e = (argb[y1 * w + x1] >> shift) & 0xff;
        return (a * (1 - fx) + b * fx) * (1 - fy) + (d * (1 - fx) + e * fx) * fy;
    }

    /**
     * The page image ([argb], [w] x [h]) for the text finder: scaled so its
     * longer side is at most [maxSide] and both sides are multiples of 32,
     * in blue, green, red order, normalised as PaddleOCR does. Made smaller
     * by averaging each pixel's patch, so thin print isn't lost.
     */
    public static Input detectionInput(int[] argb, int w, int h, int maxSide) {
        float scale = Math.min(1f, (float) maxSide / Math.max(w, h));
        int dw = Math.max(32, Math.round(w * scale / 32f) * 32);
        int dh = Math.max(32, Math.round(h * scale / 32f) * 32);
        float[] out = new float[3 * dw * dh];
        float sx = (float) w / dw, sy = (float) h / dh;
        boolean average = sx > 1.5f || sy > 1.5f;
        for (int y = 0; y < dh; y++) {
            int y0 = (int) (y * sy), y1 = Math.max(y0 + 1, Math.min(h, (int) ((y + 1) * sy)));
            for (int x = 0; x < dw; x++) {
                float[] bgr = new float[3];
                if (average) {
                    int x0 = (int) (x * sx), x1 = Math.max(x0 + 1, Math.min(w, (int) ((x + 1) * sx)));
                    for (int yy = y0; yy < y1; yy++) {
                        for (int xx = x0; xx < x1; xx++) {
                            int p = argb[yy * w + xx];
                            bgr[0] += p & 0xff;
                            bgr[1] += (p >> 8) & 0xff;
                            bgr[2] += (p >> 16) & 0xff;
                        }
                    }
                    int n = (y1 - y0) * (x1 - x0);
                    for (int c = 0; c < 3; c++) bgr[c] /= n;
                } else {
                    float px = (x + 0.5f) * sx - 0.5f, py = (y + 0.5f) * sy - 0.5f;
                    for (int c = 0; c < 3; c++) bgr[c] = sample(argb, w, h, px, py, c);
                }
                for (int c = 0; c < 3; c++) {
                    out[c * dw * dh + y * dw + x] = (bgr[c] / 255f - DET_MEAN[c]) / DET_STD[c];
                }
            }
        }
        return new Input(out, dw, dh);
    }

    /**
     * Boxes of text from the text finder's answer ([prob], one value per
     * pixel of its [mw] x [mh] input, 0..1), in the page image's own pixels
     * ([w] x [h]), top first then left to right. Each patch of pixels over
     * [threshold] is a box, kept if its pixels average at least [boxScore],
     * then grown by PaddleOCR's usual amount (the finder marks text a
     * little smaller than it is).
     */
    public static List<Line> detectionBoxes(float[] prob, int mw, int mh, int w, int h,
            float threshold, float boxScore) {
        boolean[] on = new boolean[mw * mh];
        for (int i = 0; i < on.length; i++) on[i] = prob[i] > threshold;
        int[] queue = new int[mw * mh];
        boolean[] seen = new boolean[mw * mh];
        List<Line> lines = new ArrayList<>();
        float sx = (float) w / mw, sy = (float) h / mh;
        for (int start = 0; start < on.length; start++) {
            if (!on[start] || seen[start]) continue;
            int head = 0, tail = 0;
            queue[tail++] = start;
            seen[start] = true;
            int minX = mw, minY = mh, maxX = -1, maxY = -1;
            int count = 0;
            while (head < tail) {
                int p = queue[head++];
                int x = p % mw, y = p / mw;
                count++;
                if (x < minX) minX = x;
                if (x > maxX) maxX = x;
                if (y < minY) minY = y;
                if (y > maxY) maxY = y;
                for (int dy = -1; dy <= 1; dy++) {
                    for (int dx = -1; dx <= 1; dx++) {
                        int nx = x + dx, ny = y + dy;
                        if (nx < 0 || ny < 0 || nx >= mw || ny >= mh) continue;
                        int q = ny * mw + nx;
                        if (on[q] && !seen[q]) {
                            seen[q] = true;
                            queue[tail++] = q;
                        }
                    }
                }
            }
            int bw = maxX - minX + 1, bh = maxY - minY + 1;
            if (count < 4 || Math.min(bw, bh) < 3) continue; // PaddleOCR's min_size
            // The box's own score: the average of the finder's values in it.
            double sum = 0;
            for (int y = minY; y <= maxY; y++) {
                for (int x = minX; x <= maxX; x++) sum += prob[y * mw + x];
            }
            if (sum / (bw * bh) < boxScore) continue;
            // Grown as PaddleOCR's "unclip" does: by area x 1.5 / perimeter.
            double grow = (double) bw * bh * 1.5 / (2.0 * (bw + bh));
            int left = (int) Math.floor((minX - grow) * sx);
            int top = (int) Math.floor((minY - grow) * sy);
            int right = (int) Math.ceil((maxX + 1 + grow) * sx);
            int bottom = (int) Math.ceil((maxY + 1 + grow) * sy);
            if (Math.min(bw + 2 * grow, bh + 2 * grow) < 5) continue;
            lines.add(new Line(Math.max(0, left), Math.max(0, top), Math.min(w, right), Math.min(h, bottom)));
        }
        sortReading(lines);
        return lines;
    }

    /**
     * Top first; lines at about the same height left to right. As
     * PaddleOCR does it: sorted by top then left, then neighbours on the
     * same row swapped into left-to-right order. (A single comparison for
     * "same row" isn't consistent, and Java's sort may refuse it.)
     */
    public static void sortReading(List<Line> lines) {
        lines.sort(Comparator.<Line>comparingInt(l -> l.top).thenComparingInt(l -> l.left));
        for (int i = 0; i < lines.size() - 1; i++) {
            for (int j = i; j >= 0; j--) {
                Line a = lines.get(j), b = lines.get(j + 1);
                int rowGap = Math.max(4, Math.min(a.bottom - a.top, b.bottom - b.top) / 2);
                if (Math.abs(b.top - a.top) < rowGap && b.left < a.left) {
                    lines.set(j, b);
                    lines.set(j + 1, a);
                } else {
                    break;
                }
            }
        }
    }

    /** The narrowest image the reader is given (PaddleOCR's 48 x 320). */
    public static final int REC_MIN_WIDTH = 320;

    /**
     * [line]'s part of the page image for the reader: [height] pixels high,
     * as wide as its shape needs (at most [maxWidth]), normalised to
     * -1..1, blue, green, red order. Short words are padded on the right
     * (with 0, as PaddleOCR does) to [REC_MIN_WIDTH].
     */
    public static Input recognitionInput(int[] argb, int w, int h, Line line, int height, int maxWidth) {
        int lw = Math.max(1, line.right - line.left), lh = Math.max(1, line.bottom - line.top);
        int rw = Math.max(1, Math.min(maxWidth, (int) Math.ceil((float) lw * height / lh)));
        int padded = Math.max(rw, Math.min(maxWidth, REC_MIN_WIDTH));
        float[] out = new float[3 * height * padded];
        float sx = (float) lw / rw, sy = (float) lh / height;
        for (int y = 0; y < height; y++) {
            for (int x = 0; x < rw; x++) {
                float px = line.left + (x + 0.5f) * sx - 0.5f;
                float py = line.top + (y + 0.5f) * sy - 0.5f;
                for (int c = 0; c < 3; c++) {
                    float v = sample(argb, w, h, px, py, c) / 255f;
                    out[c * height * padded + y * padded + x] = (v - 0.5f) / 0.5f;
                }
            }
        }
        return new Input(out, padded, height);
    }

    /**
     * The reader's answer ([probs]: [steps] rows of [classes] values) as
     * text, the way PaddleOCR reads it (CTC): the likeliest class at each
     * step, repeats and "blank" (class 0) dropped, then class i is
     * [alphabet] line i - 1. A space is the last class when the model has
     * one more class than the alphabet holds. Sets [line]'s text and its
     * confidence (the average likelihood of the characters kept).
     */
    public static void decode(float[] probs, int steps, int classes, List<String> alphabet, Line line) {
        boolean space = classes == alphabet.size() + 2;
        if (!space && classes != alphabet.size() + 1) {
            throw new IllegalStateException("The model's alphabet file doesn't match it");
        }
        StringBuilder text = new StringBuilder();
        double sure = 0;
        int kept = 0, last = -1;
        for (int t = 0; t < steps; t++) {
            int best = 0;
            float bestP = probs[t * classes];
            for (int c = 1; c < classes; c++) {
                float p = probs[t * classes + c];
                if (p > bestP) {
                    bestP = p;
                    best = c;
                }
            }
            if (best != 0 && best != last) {
                String ch = best - 1 < alphabet.size() ? alphabet.get(best - 1)
                        : (space && best == alphabet.size() + 1 ? " " : "");
                text.append(ch);
                sure += bestP;
                kept++;
            }
            last = best;
        }
        line.text = text.toString().trim();
        line.confidence = kept == 0 ? 0 : (float) (sure / kept);
    }

    /** The alphabet file's characters, one per line. */
    public static List<String> alphabet(String file) {
        List<String> out = new ArrayList<>(Arrays.asList(file.split("\r?\n", -1)));
        // A final line break leaves an empty last entry.
        if (!out.isEmpty() && out.get(out.size() - 1).isEmpty()) out.remove(out.size() - 1);
        return out;
    }
}
