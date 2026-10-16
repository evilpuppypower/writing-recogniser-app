/// User settings. Pure Dart (no Flutter) so it can be reused on Windows and
/// unit-tested; saving and loading lives in `lib/settings/`.
library;

import 'pressure_response.dart';

/// The app's accent colour: buttons, bars, switches and the scroll tab.
/// [system] follows the tablet's Material You colour; the others are fixed
/// ARGB colours.
enum AppColour {
  system('Match system', null),
  blue('Blue', 0xFF1E88E5),
  green('Green', 0xFF43A047),
  orange('Orange', 0xFFFB8C00),
  pink('Pink', 0xFFD81B60),
  grey('Grey', 0xFF757575);

  const AppColour(this.label, this.argb);

  final String label;

  /// ARGB colour value, or null for [system].
  final int? argb;
}

/// What the viewer's scroll tab does when you're not scrolling.
enum ScrollTabIdle {
  visible('Always show'),
  slim('Shrink to a slim bar'),
  hidden('Hide');

  const ScrollTabIdle(this.label);
  final String label;
}

/// Colours of pop-up messages and button labels (tooltips).
enum MessageStyle {
  /// Stands out from the page: dark in light mode, light in dark mode.
  contrasting('Contrasting', 'Dark in light mode, light in dark mode'),

  /// Blends with the theme: light in light mode, dark in dark mode.
  matching('Match the theme', 'Light in light mode, dark in dark mode');

  const MessageStyle(this.label, this.description);
  final String label;
  final String description;
}

/// Which hand the user writes with; the writing box leaves room on that
/// side so the hand doesn't end up writing at the screen edge.
enum WritingHand {
  right('Right hand'),
  left('Left hand');

  const WritingHand(this.label);
  final String label;
}

/// Where recognised text appears over the handwriting (owner: above).
enum TextLabelPlace {
  above('Above each word'),
  below('Below each word'),
  off('Off');

  const TextLabelPlace(this.label);
  final String label;
}

/// Where the recognised-text panel sits next to the PDF (owner: docked to
/// any side, or floating and movable).
enum TextPanelPlace {
  off('Off'),
  right('Right side'),
  left('Left side'),
  top('Top'),
  bottom('Bottom'),
  floating('Floating window');

  const TextPanelPlace(this.label);
  final String label;
}

/// The faint line under the line being written (owner's choice F2).
enum WritingGuide {
  grey('Pale grey', 0x33000000),
  blue('Pale blue', 0x551E88E5),
  off('Off', 0);

  const WritingGuide(this.label, this.colorArgb);
  final String label;

  /// See-through, so it shows faintly on any page.
  final int colorArgb;
}

/// How PDF pages look (owner's request, 2026-10-15): as printed, dark for
/// reading at night, or dark only while the tablet is in dark mode. Only
/// the screen changes: never the PDF or an export.
enum PageColours {
  light('As printed'),
  dark('Dark'),
  system('Dark when the tablet is');

  const PageColours(this.label);
  final String label;
}

/// "Also convert handwriting I haven't converted" at export (owner's
/// choice 1b): remembered from the last export once it has been chosen.
enum ExportConvertRest {
  /// Not chosen yet: ticked when nothing is converted, unticked otherwise.
  auto,
  on,
  off,
}

class AppSettings {
  const AppSettings({
    this.appColour = AppColour.system,
    this.scrollTabIdle = ScrollTabIdle.slim,
    this.slimTabOpacityPercent = defaultSlimTabOpacityPercent,
    this.messageStyle = MessageStyle.contrasting,
    this.cachedPdfLimit = defaultCachedPdfs,
    this.confirmDeleteCopy = true,
    this.recognitionPauseMs = defaultRecognitionPauseMs,
    this.writingHand = WritingHand.right,
    this.writingBoxPercent = defaultWritingBoxPercent,
    this.pressureOn = true,
    this.pressurePercent = defaultPressurePercent,
    this.pressureRangePercent = defaultPressureRangePercent,
    this.arrowHookMs = defaultArrowHookMs,
    this.keepInkOnDelete = true,
    this.twoPages = false,
    this.textLabels = TextLabelPlace.above,
    this.textPanel = TextPanelPlace.off,
    this.writingGuide = WritingGuide.grey,
    this.pageColours = PageColours.light,
    this.askPageColours = true,
    this.askWhenUnsure = true,
    this.exportConvertRest = ExportConvertRest.auto,
  });

  static const minWritingBoxPercent = 40;
  static const maxWritingBoxPercent = 100;
  static const defaultWritingBoxPercent = 67;

  static const minPressurePercent = 10;
  static const maxPressurePercent = 100;
  static const defaultPressurePercent = 100;

  static const minPressureRangePercent = 20;
  static const maxPressureRangePercent = 200;
  static const defaultPressureRangePercent = 40;

  static const maxArrowHookMs = 200;
  static const defaultArrowHookMs = 70;

  static const minRecognitionPauseMs = 300;
  static const maxRecognitionPauseMs = 2000;
  static const defaultRecognitionPauseMs = 800;

  static const minSlimTabOpacityPercent = 15;
  static const maxSlimTabOpacityPercent = 100;
  static const defaultSlimTabOpacityPercent = 55;

  static const minCachedPdfs = 1;
  static const maxCachedPdfs = 10;
  static const defaultCachedPdfs = 3;

  /// Time without scrolling before the scroll tab hides or shrinks.
  static const scrollTabIdleAfter = Duration(seconds: 2);

  /// Keys used by older versions of the app, read once so earlier choices
  /// carry over.
  static const legacyKeys = {'scrollTabColour', 'scrollTabAutoHide'};

  final AppColour appColour;
  final ScrollTabIdle scrollTabIdle;

  /// How solid the slim scroll bar is, in percent (100 = fully opaque).
  final int slimTabOpacityPercent;

  final MessageStyle messageStyle;

  /// Ask before deleting a single stored copy (turned off by ticking
  /// "Don't ask again").
  final bool confirmDeleteCopy;

  /// How long after the pen lifts before handwriting is recognised.
  final int recognitionPauseMs;

  /// How many imported PDFs to keep copies of, so they reopen instantly.
  final int cachedPdfLimit;

  /// Hand used for writing; the handwriting box sits on the other side.
  final WritingHand writingHand;

  /// Width of the handwriting box, as a percentage of the space available.
  final int writingBoxPercent;

  /// Whether pressing harder draws a thicker line.
  final bool pressureOn;

  /// How much of the pressure effect to use, 10..100%.
  final int pressurePercent;

  /// The widest the thickness can change at 100%: pressing hardest makes a
  /// line this much thicker, pressing lightest this much thinner (never
  /// below 10% of the set width). Default 40 (60%..140%).
  final int pressureRangePercent;

  /// The pressure settings as the pen and export use them.
  /// "How much" was removed from Settings (owner: "Widest change" already
  /// says it), so the full effect is always used when pressure is on.
  PressureResponse get pressureResponse => pressureOn
      ? PressureResponse(range: pressureRangePercent / 100)
      : PressureResponse.none;

  /// Arrows: how much of the end of the stroke (in milliseconds before the
  /// pen lifted) is checked for a lift-off flick to drop. 0 = never trim.
  final int arrowHookMs;

  /// When a stored PDF copy is deleted, keep the ink written on it (it
  /// comes back if the same file is opened again). The delete dialog can
  /// still delete it for one PDF.
  final bool keepInkOnDelete;

  /// Pages shown side by side in pairs (two-page view) rather than one
  /// under another.
  final bool twoPages;

  /// Recognised text over the handwriting: above, below or off.
  final TextLabelPlace textLabels;

  /// The recognised-text panel: off, docked to a side, or floating.
  final TextPanelPlace textPanel;

  /// The guide line under the line being written, or off.
  final WritingGuide writingGuide;

  /// See [PageColours]: the default for PDFs that have no choice of
  /// their own (each PDF can have one, asked when it's imported).
  final PageColours pageColours;

  /// Ask "light or dark pages?" when a PDF is imported (owner: dark pages
  /// are chosen when a PDF comes in, at export and in Settings).
  final bool askPageColours;

  /// Show a "?" on words the app isn't sure about, to confirm or fix with
  /// one tap (owner's approved idea 3).
  final bool askWhenUnsure;

  /// The export dialog's "Also convert" tick, as last chosen.
  final ExportConvertRest exportConvertRest;

  AppSettings copyWith({
    AppColour? appColour,
    ScrollTabIdle? scrollTabIdle,
    int? slimTabOpacityPercent,
    MessageStyle? messageStyle,
    int? cachedPdfLimit,
    bool? confirmDeleteCopy,
    int? recognitionPauseMs,
    WritingHand? writingHand,
    int? writingBoxPercent,
    bool? pressureOn,
    int? pressurePercent,
    int? pressureRangePercent,
    int? arrowHookMs,
    bool? keepInkOnDelete,
    bool? twoPages,
    TextLabelPlace? textLabels,
    TextPanelPlace? textPanel,
    WritingGuide? writingGuide,
    PageColours? pageColours,
    bool? askPageColours,
    bool? askWhenUnsure,
    ExportConvertRest? exportConvertRest,
  }) => AppSettings(
    appColour: appColour ?? this.appColour,
    scrollTabIdle: scrollTabIdle ?? this.scrollTabIdle,
    slimTabOpacityPercent: (slimTabOpacityPercent ?? this.slimTabOpacityPercent)
        .clamp(minSlimTabOpacityPercent, maxSlimTabOpacityPercent),
    messageStyle: messageStyle ?? this.messageStyle,
    cachedPdfLimit: (cachedPdfLimit ?? this.cachedPdfLimit).clamp(
      minCachedPdfs,
      maxCachedPdfs,
    ),
    confirmDeleteCopy: confirmDeleteCopy ?? this.confirmDeleteCopy,
    recognitionPauseMs: (recognitionPauseMs ?? this.recognitionPauseMs).clamp(
      minRecognitionPauseMs,
      maxRecognitionPauseMs,
    ),
    writingHand: writingHand ?? this.writingHand,
    writingBoxPercent: (writingBoxPercent ?? this.writingBoxPercent).clamp(
      minWritingBoxPercent,
      maxWritingBoxPercent,
    ),
    pressureOn: pressureOn ?? this.pressureOn,
    pressurePercent: (pressurePercent ?? this.pressurePercent).clamp(
      minPressurePercent,
      maxPressurePercent,
    ),
    pressureRangePercent: (pressureRangePercent ?? this.pressureRangePercent)
        .clamp(minPressureRangePercent, maxPressureRangePercent),
    arrowHookMs: (arrowHookMs ?? this.arrowHookMs).clamp(0, maxArrowHookMs),
    keepInkOnDelete: keepInkOnDelete ?? this.keepInkOnDelete,
    twoPages: twoPages ?? this.twoPages,
    textLabels: textLabels ?? this.textLabels,
    textPanel: textPanel ?? this.textPanel,
    writingGuide: writingGuide ?? this.writingGuide,
    pageColours: pageColours ?? this.pageColours,
    askPageColours: askPageColours ?? this.askPageColours,
    askWhenUnsure: askWhenUnsure ?? this.askWhenUnsure,
    exportConvertRest: exportConvertRest ?? this.exportConvertRest,
  );

  Map<String, Object> toMap() => {
    'appColour': appColour.name,
    'scrollTabIdle': scrollTabIdle.name,
    'slimTabOpacityPercent': slimTabOpacityPercent,
    'messageStyle': messageStyle.name,
    'cachedPdfLimit': cachedPdfLimit,
    'confirmDeleteCopy': confirmDeleteCopy,
    'recognitionPauseMs': recognitionPauseMs,
    'writingHand': writingHand.name,
    'writingBoxPercent': writingBoxPercent,
    'pressureOn': pressureOn,
    'pressurePercent': pressurePercent,
    'pressureRangePercent': pressureRangePercent,
    'arrowHookMs': arrowHookMs,
    'keepInkOnDelete': keepInkOnDelete,
    'twoPages': twoPages,
    'textLabels': textLabels.name,
    'textPanel': textPanel.name,
    'writingGuide': writingGuide.name,
    'pageColours': pageColours.name,
    'askPageColours': askPageColours,
    'askWhenUnsure': askWhenUnsure,
    'exportConvertRest': exportConvertRest.name,
  };

  /// Reads settings saved by [toMap] (or by older versions, see
  /// [legacyKeys]). Missing or invalid values fall back to the defaults, so
  /// an old or damaged save never stops the app starting.
  factory AppSettings.fromMap(Map<String, Object?> m) {
    const d = AppSettings();

    T byName<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.firstWhere((v) => v.name == name, orElse: () => fallback);

    final legacyAutoHide = m['scrollTabAutoHide'];
    final idleFallback = legacyAutoHide is bool
        ? (legacyAutoHide ? ScrollTabIdle.hidden : ScrollTabIdle.visible)
        : d.scrollTabIdle;
    final limit = m['cachedPdfLimit'];
    final opacity = m['slimTabOpacityPercent'];
    final confirm = m['confirmDeleteCopy'];
    final pause = m['recognitionPauseMs'];
    final box = m['writingBoxPercent'];
    final pressure = m['pressurePercent'];
    final pressureOn = m['pressureOn'];
    final range = m['pressureRangePercent'];
    final hook = m['arrowHookMs'];
    final keepInk = m['keepInkOnDelete'];
    final twoPages = m['twoPages'];
    final askPageColours = m['askPageColours'];
    final askWhenUnsure = m['askWhenUnsure'];

    return AppSettings(
      appColour: byName(
        AppColour.values,
        m['appColour'] ?? m['scrollTabColour'],
        d.appColour,
      ),
      scrollTabIdle: byName(
        ScrollTabIdle.values,
        m['scrollTabIdle'],
        idleFallback,
      ),
      slimTabOpacityPercent: opacity is int
          ? opacity.clamp(minSlimTabOpacityPercent, maxSlimTabOpacityPercent)
          : d.slimTabOpacityPercent,
      messageStyle: byName(
        MessageStyle.values,
        m['messageStyle'],
        d.messageStyle,
      ),
      cachedPdfLimit: limit is int
          ? limit.clamp(minCachedPdfs, maxCachedPdfs)
          : d.cachedPdfLimit,
      confirmDeleteCopy: confirm is bool ? confirm : d.confirmDeleteCopy,
      recognitionPauseMs: pause is int
          ? pause.clamp(minRecognitionPauseMs, maxRecognitionPauseMs)
          : d.recognitionPauseMs,
      writingHand: byName(WritingHand.values, m['writingHand'], d.writingHand),
      writingBoxPercent: box is int
          ? box.clamp(minWritingBoxPercent, maxWritingBoxPercent)
          : d.writingBoxPercent,
      // Before the on/off switch, 0% meant off.
      pressureOn: pressureOn is bool
          ? pressureOn
          : (pressure is int ? pressure > 0 : d.pressureOn),
      pressurePercent: pressure is int && pressure > 0
          ? pressure.clamp(minPressurePercent, maxPressurePercent)
          : d.pressurePercent,
      pressureRangePercent: range is int
          ? range.clamp(minPressureRangePercent, maxPressureRangePercent)
          : d.pressureRangePercent,
      arrowHookMs: hook is int ? hook.clamp(0, maxArrowHookMs) : d.arrowHookMs,
      keepInkOnDelete: keepInk is bool ? keepInk : d.keepInkOnDelete,
      twoPages: twoPages is bool ? twoPages : d.twoPages,
      textLabels: byName(TextLabelPlace.values, m['textLabels'], d.textLabels),
      textPanel: byName(TextPanelPlace.values, m['textPanel'], d.textPanel),
      writingGuide: byName(
        WritingGuide.values,
        m['writingGuide'],
        d.writingGuide,
      ),
      pageColours: byName(PageColours.values, m['pageColours'], d.pageColours),
      askPageColours: askPageColours is bool
          ? askPageColours
          : d.askPageColours,
      askWhenUnsure: askWhenUnsure is bool ? askWhenUnsure : d.askWhenUnsure,
      exportConvertRest: byName(
        ExportConvertRest.values,
        m['exportConvertRest'],
        d.exportConvertRest,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.appColour == appColour &&
      other.scrollTabIdle == scrollTabIdle &&
      other.slimTabOpacityPercent == slimTabOpacityPercent &&
      other.messageStyle == messageStyle &&
      other.cachedPdfLimit == cachedPdfLimit &&
      other.confirmDeleteCopy == confirmDeleteCopy &&
      other.recognitionPauseMs == recognitionPauseMs &&
      other.writingHand == writingHand &&
      other.writingBoxPercent == writingBoxPercent &&
      other.pressureOn == pressureOn &&
      other.pressurePercent == pressurePercent &&
      other.pressureRangePercent == pressureRangePercent &&
      other.arrowHookMs == arrowHookMs &&
      other.keepInkOnDelete == keepInkOnDelete &&
      other.twoPages == twoPages &&
      other.textLabels == textLabels &&
      other.textPanel == textPanel &&
      other.writingGuide == writingGuide &&
      other.pageColours == pageColours &&
      other.askPageColours == askPageColours &&
      other.askWhenUnsure == askWhenUnsure &&
      other.exportConvertRest == exportConvertRest;

  @override
  int get hashCode => Object.hashAll([
    appColour,
    scrollTabIdle,
    slimTabOpacityPercent,
    messageStyle,
    cachedPdfLimit,
    confirmDeleteCopy,
    recognitionPauseMs,
    writingHand,
    writingBoxPercent,
    pressureOn,
    pressurePercent,
    pressureRangePercent,
    arrowHookMs,
    keepInkOnDelete,
    twoPages,
    textLabels,
    textPanel,
    writingGuide,
    pageColours,
    askPageColours,
    askWhenUnsure,
    exportConvertRest,
  ]);
}
