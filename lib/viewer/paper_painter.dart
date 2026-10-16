import 'dart:ui' show PointMode;

import 'package:flutter/material.dart';

import '../core/night_colours.dart';
import '../core/page_layout.dart';
import '../core/paper.dart';

/// Draws [page]'s paper (see paperMarks) into [rect], where the page is
/// shown; in night colours on a dark page.
void paintPaper(
  Canvas canvas,
  Rect rect,
  LaidOutPage page, {
  bool dark = false,
}) {
  final paper = page.paper;
  if (paper == null || paper == Paper.plain || page.width <= 0) return;
  final s = rect.width / page.width;
  final colour = Color(dark ? nightArgb(paperArgb) : paperArgb);
  final line = Paint()
    ..color = colour
    ..strokeWidth = (0.6 * s).clamp(0.5, 3.0)
    ..style = PaintingStyle.stroke;
  final dot = Paint()
    ..color = colour
    ..strokeCap = StrokeCap.round
    ..strokeWidth = (1.8 * s).clamp(1.2, 8.0);
  final dots = <Offset>[];
  for (final (x1, y1, x2, y2) in paperMarks(
    paper,
    page.width,
    page.height,
    lineGap: page.lineGap,
  )) {
    final a = Offset(rect.left + x1 * s, rect.top + (page.height - y1) * s);
    if (x1 == x2 && y1 == y2) {
      dots.add(a);
    } else {
      canvas.drawLine(
        a,
        Offset(rect.left + x2 * s, rect.top + (page.height - y2) * s),
        line,
      );
    }
  }
  // All the dots in one go (a dotted page has thousands).
  if (dots.isNotEmpty) canvas.drawPoints(PointMode.points, dots, dot);
}

/// [page]'s paper over [child] (a small picture of the page).
class PaperOver extends StatelessWidget {
  const PaperOver({
    super.key,
    required this.page,
    required this.child,
    this.dark = false,
  });

  final LaidOutPage page;
  final Widget child;
  final bool dark;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(foregroundPainter: _PaperPainter(page, dark), child: child);
}

class _PaperPainter extends CustomPainter {
  _PaperPainter(this.page, this.dark);

  final LaidOutPage page;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) =>
      paintPaper(canvas, Offset.zero & size, page, dark: dark);

  @override
  bool shouldRepaint(_PaperPainter old) => old.page != page || old.dark != dark;
}

/// Choosing a blank page's paper: a small picture of each, and with
/// [afterPage], whether the page goes after that page or at the end.
/// Pops ({paper, atEnd}).
class PaperChooser extends StatefulWidget {
  const PaperChooser({
    super.key,
    required this.title,
    required this.start,
    this.afterPage,
    this.dark = false,
    this.doneLabel = 'Done',
    this.onSize,
  });

  /// Also asks the page size (a new notebook), told here as it changes.
  final ValueChanged<NotebookSize>? onSize;

  final String title;
  final Paper start;

  /// The button's label without [afterPage].
  final String doneLabel;
  final int? afterPage;
  final bool dark;

  @override
  State<PaperChooser> createState() => _PaperChooserState();
}

class _PaperChooserState extends State<PaperChooser> {
  late Paper _paper = widget.start;
  var _size = NotebookSize.a4;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    void done(bool atEnd) =>
        Navigator.of(context).pop((paper: _paper, atEnd: atEnd));
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final p in Paper.values)
                  Semantics(
                    button: true,
                    selected: p == _paper,
                    label: paperName(p),
                    child: InkWell(
                      onTap: () => setState(() => _paper = p),
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 96,
                        child: Column(
                          children: [
                            Container(
                              width: 72,
                              height: 96,
                              decoration: BoxDecoration(
                                color: widget.dark
                                    ? const Color(0xFF202124)
                                    : Colors.white,
                                border: Border.all(
                                  color: p == _paper
                                      ? scheme.primary
                                      : scheme.outlineVariant,
                                  width: p == _paper ? 3 : 1,
                                ),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: PaperOver(
                                // A small A4 page, its marks at 1/3 scale
                                // so they read at this size.
                                page: LaidOutPage.blank(
                                  0,
                                  paper: p,
                                  width: 595 / 3,
                                  height: 842 / 3,
                                  lineGap: ruledGap * 0.9,
                                ),
                                dark: widget.dark,
                                child: const SizedBox.expand(),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              paperName(p),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontWeight: p == _paper
                                    ? FontWeight.bold
                                    : null,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            if (widget.onSize != null) ...[
              const SizedBox(height: 16),
              Text('Page size', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              SegmentedButton<NotebookSize>(
                segments: [
                  for (final s in NotebookSize.values)
                    ButtonSegment(value: s, label: Text(s.label)),
                ],
                selected: {_size},
                onSelectionChanged: (v) {
                  setState(() => _size = v.first);
                  widget.onSize!(v.first);
                },
              ),
            ],
            if (_paper == Paper.linedToFit)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'The lines are spaced for the size you usually write, '
                  'measured from your writing in this document.',
                ),
              ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                if (widget.afterPage != null) ...[
                  OutlinedButton(
                    onPressed: () => done(true),
                    child: const Text('Add at the end'),
                  ),
                  FilledButton(
                    onPressed: () => done(false),
                    child: Text('Add after page ${widget.afterPage}'),
                  ),
                ] else
                  FilledButton(
                    onPressed: () => done(false),
                    child: Text(widget.doneLabel),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
