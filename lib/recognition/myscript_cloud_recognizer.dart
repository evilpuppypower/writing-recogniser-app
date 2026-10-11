import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../core/ink.dart';
import '../core/recognition/recognizer.dart';
import 'jiix.dart';
import 'myscript_keys.dart';

export 'jiix.dart' show jiixToCandidates;

/// MyScript iink Cloud (REST "batch" API). Sends ONLY pen strokes (points,
/// times, pressure) to MyScript's servers; approved by the owner for the
/// task 0.3 / GATE A comparison. Needs internet and the owner's keys.
class MyScriptCloudRecognizer implements Recognizer {
  MyScriptCloudRecognizer({
    this.keyStore = const MyScriptKeyStore(),
    http.Client? client,
    this.host = 'cloud.myscript.com',
    this.languages = const ['en_GB', 'en_US'],
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  final MyScriptKeyStore keyStore;
  final http.Client _client;
  final String host;

  /// Tried in order; the next is used if MyScript doesn't offer one.
  final List<String> languages;
  final Duration timeout;

  @override
  String get name => 'MyScript Cloud';

  @override
  bool get onDevice => false;

  @override
  Future<RecognizerStatus> status() async {
    final keys = await keyStore.load();
    return keys == null
        ? const RecognizerStatus(
            RecognizerState.needsSetup,
            'MyScript Cloud needs your keys. Create an application at '
            'developer.myscript.com, then enter its Application key and HMAC '
            'key in Settings → MyScript Cloud. Needs internet; your pen '
            'strokes (only) are sent to MyScript to be recognised.',
          )
        : const RecognizerStatus(RecognizerState.ready);
  }

  @override
  Future<void> prepare({void Function(double? progress)? onProgress}) async {}

  @override
  Future<List<Candidate>> recognize(
    List<InkStroke> strokes,
    RecognitionContext context,
  ) async {
    final keys = await keyStore.load();
    if (keys == null) {
      throw const RecognitionException(
        'Enter your MyScript keys in Settings first.',
      );
    }
    RecognitionException? lastError;
    for (final lang in languages) {
      try {
        final jiix = await _post(
          keys,
          buildMyScriptRequest(strokes, context, lang: lang),
        );
        return jiixToCandidates(jiix);
      } on _LanguageNotAvailable catch (e) {
        lastError = RecognitionException(e.message);
      }
    }
    throw lastError!;
  }

  Future<Map<String, Object?>> _post(
    MyScriptKeys keys,
    Map<String, Object?> body,
  ) async {
    final json = jsonEncode(body);
    final http.Response response;
    try {
      response = await _client
          .post(
            Uri.https(host, '/api/v4.0/iink/batch'),
            headers: {
              'Accept': 'application/json,application/vnd.myscript.jiix',
              'Content-Type': 'application/json',
              'applicationKey': keys.applicationKey,
              'hmac': myScriptHmac(json, keys.applicationKey, keys.hmacKey),
            },
            body: json,
          )
          .timeout(timeout);
    } on SocketException {
      throw const RecognitionException(
        'No internet connection. MyScript Cloud needs internet; '
        'switch to ML Kit to work offline.',
      );
    } on TimeoutException {
      throw const RecognitionException(
        'MyScript Cloud took too long to answer. Check the connection.',
      );
    } on http.ClientException catch (e) {
      throw RecognitionException("Couldn't reach MyScript Cloud: $e");
    }
    final text = utf8.decode(response.bodyBytes);
    if (response.statusCode == 200) {
      return jsonDecode(text) as Map<String, Object?>;
    }
    String code = '${response.statusCode}', message = text;
    try {
      final err = jsonDecode(text) as Map<String, Object?>;
      code = '${err['code'] ?? code}';
      message = '${err['message'] ?? text}';
    } catch (_) {}
    if (code == 'access.not.granted' ||
        response.statusCode == 401 ||
        response.statusCode == 403) {
      throw RecognitionException(
        'MyScript rejected the keys ($message). Check them in Settings → '
        'MyScript Cloud.',
      );
    }
    if (message.toLowerCase().contains('lang')) {
      throw _LanguageNotAvailable(message);
    }
    throw RecognitionException('MyScript Cloud error $code: $message');
  }
}

class _LanguageNotAvailable implements Exception {
  const _LanguageNotAvailable(this.message);
  final String message;
}

/// HMAC-SHA512 of the request body, keyed with applicationKey + hmacKey,
/// as hex: how MyScript Cloud authenticates requests.
String myScriptHmac(String body, String applicationKey, String hmacKey) => Hmac(
  sha512,
  utf8.encode(applicationKey + hmacKey),
).convert(utf8.encode(body)).toString();

/// The JSON body for MyScript's batch API: text recognition of [strokes],
/// asking for JIIX with per-word candidates.
Map<String, Object?> buildMyScriptRequest(
  List<InkStroke> strokes,
  RecognitionContext context, {
  required String lang,
}) {
  final bounds = InkBounds.of(strokes);
  return {
    'configuration': {
      'lang': lang,
      'text': {
        'guides': {'enable': false},
        'mimeTypes': ['application/vnd.myscript.jiix'],
      },
      'export': {
        'jiix': {
          'bounding-box': false,
          'strokes': false,
          'text': {'chars': false, 'words': true},
        },
      },
    },
    // Flutter logical pixels are about 96 per inch.
    'xDPI': 96,
    'yDPI': 96,
    'contentType': 'Text',
    'width': (context.writingAreaWidth ?? bounds?.right ?? 0).round(),
    'height': (context.writingAreaHeight ?? bounds?.bottom ?? 0).round(),
    'strokeGroups': [
      {
        'strokes': [
          for (final s in strokes)
            {
              'pointerType': 'PEN',
              'x': [for (final p in s.points) _r(p.x)],
              'y': [for (final p in s.points) _r(p.y)],
              't': [for (final p in s.points) p.t],
              'p': [for (final p in s.points) _r(p.pressure)],
            },
        ],
      },
    ],
  };
}

double _r(double v) => (v * 100).roundToDouble() / 100;
