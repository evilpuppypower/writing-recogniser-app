import 'package:flutter/foundation.dart';

/// The PDF open now (its library id), or null: Review my writing leaves
/// its words alone, as the open PDF saves its own.
final openDocument = ValueNotifier<String?>(null);
