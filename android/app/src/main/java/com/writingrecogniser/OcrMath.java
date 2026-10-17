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
     * in blue, green, red order, normalised as PaddleOCR does.
     */
    public static Input detectionInput(int[] argb, int w, int h, int maxSide) {
        float scale = Math.min(1f, (float) maxSide / Math.max(w, h));
        int dw = Math.max(32, Math.round(w * scale / 32f) * 32);
        int dh = Math.max(32, Math.round(h * scale / 32f) * 32);
        float[] out = new float[3 * dw * dh];
        float sx = (float) w / dw, sy = (float) h / dh;
        for (int y = 0; y < dh; y++) {
            for (int x = 0; x < dw; x++) {
                float px = (x + 0.5f) * sx - 0.5f, py = (y + 0.5f) * sy - 0.5f;
                for (int c = 0; c < 3; c++) {
                    float v = sample(argb, w, h, px, py, c) / 255f;
                    out[c * dw * dh + y * dw + x] = (v - DET_MEAN[c]) / DET_STD[c];
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
            if (count < 4 || Math.min(bw, bh) < 2) continue;
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
            lines.add(new Line(Math.max(0, left), Math.max(0, top), Math.min(w, right), Math.min(h, bottom)));
        }
        lines.sort(readingOrder());
        return lines;
    }

    /** Top first; lines at about the same height left to right. */
    public static Comparator<Line> readingOrder() {
        return (a, b) -> {
            int ah = a.bottom - a.top, bh = b.bottom - b.top;
            int ac = (a.top + a.bottom) / 2, bc = (b.top + b.bottom) / 2;
            if (Math.abs(ac - bc) < Math.min(ah, bh) / 2) return Integer.compare(a.left, b.left);
            return Integer.compare(ac, bc);
        };
    }

    /**
     * [line]'s part of the page image for the reader: [height] pixels high,
     * as wide as its shape needs (at most [maxWidth]), normalised to
     * -1..1, blue, green, red order.
     */
    public static Input recognitionInput(int[] argb, int w, int h, Line line, int height, int maxWidth) {
        int lw = Math.max(1, line.right - line.left), lh = Math.max(1, line.bottom - line.top);
        int rw = Math.max(height / 4, Math.min(maxWidth, (int) Math.ceil((float) lw * height / lh)));
        float[] out = new float[3 * height * rw];
        float sx = (float) lw / rw, sy = (float) lh / height;
        for (int y = 0; y < height; y++) {
            for (int x = 0; x < rw; x++) {
                float px = line.left + (x + 0.5f) * sx - 0.5f;
                float py = line.top + (y + 0.5f) * sy - 0.5f;
                for (int c = 0; c < 3; c++) {
                    float v = sample(argb, w, h, px, py, c) / 255f;
                    out[c * height * rw + y * rw + x] = (v - 0.5f) / 0.5f;
                }
            }
        }
        return new Input(out, rw, height);
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
