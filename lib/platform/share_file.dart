import 'dart:typed_data';

import 'package:share_plus/share_plus.dart';

/// Opens Android's share menu for a file (email, Drive, messages, …).
/// Nothing is sent until the user picks an app. True if they picked one,
/// false if they closed the menu.
Future<bool> shareFileVia(String name, String mime, List<int> bytes) async {
  final result = await SharePlus.instance.share(
    ShareParams(
      files: [XFile.fromData(Uint8List.fromList(bytes), mimeType: mime)],
      fileNameOverrides: [name],
      title: name,
    ),
  );
  return result.status != ShareResultStatus.dismissed;
}
