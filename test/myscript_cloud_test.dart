import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:writing_recogniser/core/ink.dart';
import 'package:writing_recogniser/core/recognition/recognizer.dart';
import 'package:writing_recogniser/recognition/myscript_cloud_recognizer.dart';
import 'package:writing_recogniser/recognition/myscript_keys.dart';

class FakeKeyStore extends MyScriptKeyStore {
  FakeKeyStore([this.keys]);
  MyScriptKeys? keys;

  @override
  Future<MyScriptKeys?> load() async => keys;

  @override
  Future<bool> save(MyScriptKeys k) async {
    keys = k;
    return true;
  }

  @override
  Future<void> clear() async => keys = null;
}

const strokes = [
  InkStroke([
    InkPoint(10, 20, 1760000000000, 0.4),
    InkPoint(30, 25, 1760000000016, 0.6),
  ]),
  InkStroke([InkPoint(50, 20, 1760000000400, 0.5)]),
];

/// A JIIX answer like MyScript sends: words include the spaces.
const helloWorldJiix = {
  'type': 'Text',
  'label': 'hello world',
  'words': [
    {
      'label': 'hello',
      'candidates': ['hello', 'hallo', 'hells'],
    },
    {'label': ' '},
    {
      'label': 'world',
      'candidates': ['world', 'word'],
    },
  ],
};

void main() {
  test('request signature matches standard HMAC-SHA512', () {
    // Reference value from Python's hmac module.
    expect(
      myScriptHmac('{"a":1}', 'app-key', 'hmac-key'),
      '05a06088046e7bf7ef1915637cecd5151de4abb00b52ab53cb163ac8c2e28d40'
      'c16c687a7fb3486f704d8d94564289458bd2c418db071c281d525ced5e5b16df',
    );
  });

  test('request contains only strokes and recognition settings', () {
    final body = buildMyScriptRequest(
      strokes,
      const RecognitionContext(writingAreaWidth: 800, writingAreaHeight: 400),
      lang: 'en_GB',
    );
    expect(body['contentType'], 'Text');
    expect((body['configuration']! as Map)['lang'], 'en_GB');
    expect(body['width'], 800);
    final sent =
        ((body['strokeGroups']! as List).single as Map)['strokes'] as List;
    expect(sent, hasLength(2));
    final first = sent.first as Map;
    expect(first['x'], [10, 30]);
    expect(first['t'], [1760000000000, 1760000000016]);
    expect(first['p'], [0.4, 0.6]);
    expect(body.keys.toSet(), {
      'configuration',
      'xDPI',
      'yDPI',
      'contentType',
      'width',
      'height',
      'strokeGroups',
    });
  });

  test('JIIX answer becomes the full text plus word alternatives', () {
    final c = jiixToCandidates(helloWorldJiix).map((c) => c.text).toList();
    expect(c, ['hello world', 'hallo world', 'hells world', 'hello word']);
    expect(jiixToCandidates({'label': ''}), isEmpty);
  });

  group('MyScriptCloudRecognizer', () {
    test('needs keys before it can be used', () async {
      final r = MyScriptCloudRecognizer(keyStore: FakeKeyStore());
      expect((await r.status()).state, RecognizerState.needsSetup);
      expect(r.onDevice, isFalse);
    });

    test('sends a signed request and returns candidates', () async {
      late http.Request seen;
      final r = MyScriptCloudRecognizer(
        keyStore: FakeKeyStore(const MyScriptKeys('app', 'secret')),
        client: MockClient((req) async {
          seen = req;
          return http.Response(jsonEncode(helloWorldJiix), 200);
        }),
      );
      final c = await r.recognize(strokes, const RecognitionContext());
      expect(c.first.text, 'hello world');
      expect(
        seen.url.toString(),
        'https://cloud.myscript.com/api/v4.0/iink/batch',
      );
      expect(seen.headers['applicationKey'], 'app');
      expect(seen.headers['hmac'], myScriptHmac(seen.body, 'app', 'secret'));
    });

    test('rejected keys give a clear message', () async {
      final r = MyScriptCloudRecognizer(
        keyStore: FakeKeyStore(const MyScriptKeys('app', 'bad')),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({'code': 'access.not.granted', 'message': 'nope'}),
            403,
          ),
        ),
      );
      await expectLater(
        r.recognize(strokes, const RecognitionContext()),
        throwsA(
          isA<RecognitionException>().having(
            (e) => e.message,
            'message',
            contains('rejected the keys'),
          ),
        ),
      );
    });

    test(
      'falls back to US English if British English is unavailable',
      () async {
        final langs = <String>[];
        final r = MyScriptCloudRecognizer(
          keyStore: FakeKeyStore(const MyScriptKeys('app', 'secret')),
          client: MockClient((req) async {
            final lang =
                ((jsonDecode(req.body) as Map)['configuration'] as Map)['lang']
                    as String;
            langs.add(lang);
            return lang == 'en_GB'
                ? http.Response(
                    jsonEncode({'code': 'x', 'message': 'lang not available'}),
                    400,
                  )
                : http.Response(jsonEncode(helloWorldJiix), 200);
          }),
        );
        final c = await r.recognize(strokes, const RecognitionContext());
        expect(langs, ['en_GB', 'en_US']);
        expect(c.first.text, 'hello world');
      },
    );
  });
}
