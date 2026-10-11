import 'package:flutter_test/flutter_test.dart';
import 'package:writing_recogniser/recognition/myscript_keys.dart';

class MapPrefs implements SecretPrefs {
  final values = <String, String>{};

  @override
  Future<String?> get(String key) async => values[key];

  @override
  Future<void> set(String key, String value) async => values[key] = value;

  @override
  Future<void> remove(String key) async => values.remove(key);
}

/// Stands in for the device key store: "encrypts" by reversing and tagging.
class FakeSealer extends SecretSealer {
  FakeSealer({this.available = true, this.canOpen = true});

  final bool available;
  bool canOpen;

  @override
  Future<String?> seal(String text) async =>
      available ? 'sealed:${text.split('').reversed.join()}' : null;

  @override
  Future<String?> open(String sealed) async => canOpen
      ? sealed.substring('sealed:'.length).split('').reversed.join()
      : null;
}

void main() {
  test('keys are stored only in encrypted form and read back', () async {
    final prefs = MapPrefs();
    final store = MyScriptKeyStore(sealer: FakeSealer(), prefs: prefs);
    expect(
      await store.save(const MyScriptKeys(' app-key ', 'hmac-key')),
      isTrue,
    );
    expect(prefs.values.values.any((v) => v.contains('app-key')), isFalse);
    expect(prefs.values.values.any((v) => v.contains('hmac-key')), isFalse);
    final keys = await store.load();
    expect((keys?.applicationKey, keys?.hmacKey), ('app-key', 'hmac-key'));
  });

  test('plain-text keys from older builds are encrypted and removed', () async {
    final prefs = MapPrefs()
      ..values['secrets.myscript.applicationKey'] = 'old-app'
      ..values['secrets.myscript.hmacKey'] = 'old-hmac';
    final store = MyScriptKeyStore(sealer: FakeSealer(), prefs: prefs);
    final keys = await store.load();
    expect((keys?.applicationKey, keys?.hmacKey), ('old-app', 'old-hmac'));
    expect(
      prefs.values.containsKey('secrets.myscript.applicationKey'),
      isFalse,
    );
    expect(prefs.values.containsKey('secrets.myscript.hmacKey'), isFalse);
    expect(prefs.values.values.any((v) => v.contains('old-')), isFalse);
  });

  test('nothing is saved where keys cannot be encrypted', () async {
    final prefs = MapPrefs();
    final store = MyScriptKeyStore(
      sealer: FakeSealer(available: false),
      prefs: prefs,
    );
    expect(await store.save(const MyScriptKeys('a', 'b')), isFalse);
    expect(prefs.values, isEmpty);
  });

  test('keys that can no longer be decrypted (new device) read as unset, '
      'and clear removes everything', () async {
    final prefs = MapPrefs();
    final sealer = FakeSealer();
    final store = MyScriptKeyStore(sealer: sealer, prefs: prefs);
    await store.save(const MyScriptKeys('a', 'b'));
    sealer.canOpen = false;
    expect(await store.load(), isNull);
    await store.clear();
    expect(prefs.values, isEmpty);
  });
}
