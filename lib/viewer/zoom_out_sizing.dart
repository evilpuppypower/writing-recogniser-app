import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

/// How far the pages can be zoomed out (owner: to half of what fills the
/// screen, for any PDF): pdfrx's usual sizing, with its smallest zoom
/// (the page filling the width) halved.
class ZoomOutSizing extends PdfViewerSizeDelegateProvider {
  const ZoomOutSizing({this.smallest = 0.5});

  /// The smallest zoom, as a share of the zoom that fills the screen.
  final double smallest;

  @override
  PdfViewerSizeDelegate create() =>
      _ZoomOut(smallest, const PdfViewerSizeDelegateProviderLegacy().create());

  @override
  bool operator ==(Object other) =>
      other is ZoomOutSizing && other.smallest == smallest;

  @override
  int get hashCode => smallest.hashCode;
}

class _ZoomOut implements PdfViewerSizeDelegate {
  _ZoomOut(this.smallest, this.inner);

  final double smallest;
  final PdfViewerSizeDelegate inner;

  @override
  void init(PdfViewerController controller) => inner.init(controller);

  @override
  void dispose() => inner.dispose();

  @override
  double get onePassRenderingScaleThreshold =>
      inner.onePassRenderingScaleThreshold;

  @override
  PdfViewerLayoutMetrics calculateMetrics({
    required Size viewSize,
    required PdfPageLayout? layout,
    required int? pageNumber,
    required double pageMargin,
    required EdgeInsets? boundaryMargin,
  }) {
    final m = inner.calculateMetrics(
      viewSize: viewSize,
      layout: layout,
      pageNumber: pageNumber,
      pageMargin: pageMargin,
      boundaryMargin: boundaryMargin,
    );
    return PdfViewerLayoutMetrics(
      minScale: m.minScale * smallest,
      maxScale: m.maxScale,
      coverScale: m.coverScale,
      alternativeFitScale: m.alternativeFitScale,
    );
  }

  @override
  void onLayoutInitialized({
    required PdfViewerLayoutSnapshot state,
    required int initialPageNumber,
    required double coverScale,
    required double? alternativeFitScale,
    required PdfPageLayout layout,
    required PdfDocument document,
  }) => inner.onLayoutInitialized(
    state: state,
    initialPageNumber: initialPageNumber,
    coverScale: coverScale,
    alternativeFitScale: alternativeFitScale,
    layout: layout,
    document: document,
  );

  @override
  void onLayoutUpdate({
    required PdfViewerLayoutSnapshot oldState,
    required PdfViewerLayoutSnapshot newState,
    required double currentZoom,
    required Rect oldVisibleRect,
    required int? anchorPageNumber,
    required bool isLayoutChanged,
    required bool isViewSizeChanged,
  }) => inner.onLayoutUpdate(
    oldState: oldState,
    newState: newState,
    currentZoom: currentZoom,
    oldVisibleRect: oldVisibleRect,
    anchorPageNumber: anchorPageNumber,
    isLayoutChanged: isLayoutChanged,
    isViewSizeChanged: isViewSizeChanged,
  );
}
