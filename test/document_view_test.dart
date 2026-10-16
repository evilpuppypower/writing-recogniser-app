import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/core/app_settings.dart';
import 'package:writing_recogniser/core/document_view.dart';
import 'package:writing_recogniser/core/page_ink.dart';
import 'package:writing_recogniser/core/pen_tools.dart';
import 'package:writing_recogniser/settings/document_settings.dart';
import 'package:writing_recogniser/settings/settings_controller.dart';

void main() {
  test('a document\'s view is kept and read back', () {
    const view = DocumentView(
      page: 3,
      pageX: 0.25,
      pageY: 0.75,
      zoomToFit: 1.5,
      mode: PenMode.highlighter,
      twoPages: true,
      textLabels: 'off',
      showTyped: false,
    );
    final back = DocumentView.fromJson(view.toJson());
    expect(back.page, 3);
    expect((back.pageX, back.pageY, back.zoomToFit), (0.25, 0.75, 1.5));
    expect(back.mode, PenMode.highlighter);
    expect(back.twoPages, isTrue);
    expect(back.textLabels, 'off');
    expect(back.showTyped, isFalse);
    // Nothing saved, or unreadable: Settings decides.
    expect(DocumentView.fromJson(null).twoPages, isNull);
    expect(DocumentView.fromJson('nonsense').page, isNull);
    expect(DocumentView.fromJson('{"z": -1, "x": 9}').pageX, 1.0);
  });

  test('its own pen over the app\'s, favourites kept', () {
    const fav = PenStyle(tool: InkTool.pen, colorArgb: 0xFF00FF00, width: 3);
    const app = PenToolsState(favourites: [fav]);
    const mine = PenStyle(tool: InkTool.pen, colorArgb: 0xFFFF0000, width: 1);
    final tools = const DocumentView(pen: mine).applyTo(app);
    expect(tools.pen, mine);
    expect(tools.favourites, [fav]);
  });

  test('two pages and labels change for the document only', () async {
    final app = SettingsController(const AppSettings());
    final own = <(bool?, TextLabelPlace?)>[];
    final doc = DocumentSettingsController(
      app,
      onOwn: (two, labels, _) => own.add((two, labels)),
    );
    // Starts from Settings.
    expect(doc.value.twoPages, app.value.twoPages);
    await doc.update(doc.value.copyWith(twoPages: true));
    expect(doc.value.twoPages, isTrue);
    expect(app.value.twoPages, isFalse, reason: 'Settings stay as they were');
    expect(own.last.$1, isTrue);
    // Anything else still changes the app's settings.
    await doc.update(doc.value.copyWith(cachedPdfLimit: 7));
    expect(app.value.cachedPdfLimit, 7);
    expect(app.value.twoPages, isFalse);
    expect(doc.value.twoPages, isTrue);
    doc.dispose();
  });
}
