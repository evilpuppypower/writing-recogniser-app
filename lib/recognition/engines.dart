import '../core/recognition/recognizer.dart';
import 'mlkit_recognizer.dart';
import 'myscript_cloud_recognizer.dart';
import 'myscript_offline_recognizer.dart';

/// The recognition engines available in this build, in display order. The
/// first is the main engine and is picked by default: MyScript offline
/// (GATE A, owner decision 2026-10-11). The others stay for comparison.
List<Recognizer> buildEngines() => [
  MyScriptOfflineRecognizer(),
  MlKitRecognizer(),
  MyScriptCloudRecognizer(),
];
