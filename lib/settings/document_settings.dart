import '../core/app_settings.dart';
import 'settings_controller.dart';

/// The settings as one document sees them (owner: each document keeps its
/// own two-page view and labels; a new one starts from Settings). Changes
/// to those go to the document only ([onOwn]); every other change goes to
/// the app's settings as before.
class DocumentSettingsController extends SettingsController {
  DocumentSettingsController(
    this.app, {
    bool? twoPages,
    TextLabelPlace? textLabels,
    TextPanelPlace? textPanel,
    required this.onOwn,
  }) : super(app.value) {
    _twoPages = twoPages;
    _labels = textLabels;
    _panel = textPanel;
    app.addListener(notifyListeners);
  }

  final SettingsController app;

  /// Called after this document's own choices change.
  final void Function(
    bool? twoPages,
    TextLabelPlace? textLabels,
    TextPanelPlace? textPanel,
  )
  onOwn;

  bool? _twoPages;
  TextLabelPlace? _labels;
  TextPanelPlace? _panel;

  @override
  AppSettings get value => app.value.copyWith(
    twoPages: _twoPages,
    textLabels: _labels,
    textPanel: _panel,
  );

  @override
  Future<void> update(AppSettings settings) async {
    final now = value;
    var own = false;
    if (settings.twoPages != now.twoPages) {
      _twoPages = settings.twoPages;
      own = true;
    }
    if (settings.textLabels != now.textLabels) {
      _labels = settings.textLabels;
      own = true;
    }
    if (settings.textPanel != now.textPanel) {
      _panel = settings.textPanel;
      own = true;
    }
    if (own) onOwn(_twoPages, _labels, _panel);
    // Everything else is the app's: kept with the app's own view values.
    final rest = settings.copyWith(
      twoPages: app.value.twoPages,
      textLabels: app.value.textLabels,
      textPanel: app.value.textPanel,
    );
    if (rest != app.value) {
      await app.update(rest);
    } else if (own) {
      notifyListeners();
    }
  }

  @override
  bool get showSmoothnessGraphs => app.showSmoothnessGraphs;

  @override
  set showSmoothnessGraphs(bool on) => app.showSmoothnessGraphs = on;

  @override
  void dispose() {
    app.removeListener(notifyListeners);
    super.dispose();
  }
}
