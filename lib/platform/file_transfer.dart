import 'package:flutter/services.dart';

/// Android's own "save to…" and "open…" file pickers (FileTransfer.kt).
const _channel = MethodChannel('writing_recogniser/files');

/// Asks the user where to save [bytes]. True when saved, false if they
/// cancelled.
Future<bool> saveFileAs(String name, String mime, List<int> bytes) async =>
    await _channel.invokeMethod<bool>('saveAs', {
      'name': name,
      'mime': mime,
      'bytes': Uint8List.fromList(bytes),
    }) ??
    false;

/// Asks the user to pick a file; its bytes, or null if they cancelled.
Future<List<int>?> openFile(List<String> mimes) =>
    _channel.invokeMethod<Uint8List>('open', {'mimes': mimes});
