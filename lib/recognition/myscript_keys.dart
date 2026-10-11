import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The owner's MyScript Cloud keys. Entered on the tablet in Settings and
/// stored only there, encrypted (see [SecretSealer]); never in the code or
/// on GitHub.
class MyScriptKeys {
  const MyScriptKeys(this.applicationKey, this.hmacKey);

  final String applicationKey;
  final String hmacKey;
}

/// Encrypts and decrypts small secrets with a key the device keeps in its
/// hardware key store (Android: `SecretBox.kt`).
class SecretSealer {
  const SecretSealer();

  static const _channel = MethodChannel('writing_recogniser/secrets');

  /// The encrypted form of [text], or null where the platform has no
  /// secure store (then nothing is saved).
  Future<String?> seal(String text) async {
    try {
      return await _channel.invokeMethod<String>('seal', {'text': text});
    } on MissingPluginException {
      return null;
    }
  }

  /// [sealed] decrypted, or null if it can't be (e.g. a new device).
  Future<String?> open(String sealed) async {
    try {
      return await _channel.invokeMethod<String>('open', {'sealed': sealed});
    } on MissingPluginException {
      return null;
    }
  }
}

/// Where the encrypted values are kept (app-private settings by default).
abstract class SecretPrefs {
  Future<String?> get(String key);
  Future<void> set(String key, String value);
  Future<void> remove(String key);
}

class _AppPrefs implements SecretPrefs {
  const _AppPrefs();

  @override
  Future<String?> get(String key) => SharedPreferencesAsync().getString(key);

  @override
  Future<void> set(String key, String value) =>
      SharedPreferencesAsync().setString(key, value);

  @override
  Future<void> remove(String key) => SharedPreferencesAsync().remove(key);
}

class MyScriptKeyStore {
  const MyScriptKeyStore({
    this.sealer = const SecretSealer(),
    this.prefs = const _AppPrefs(),
  });

  final SecretSealer sealer;
  final SecretPrefs prefs;

  // Encrypted values.
  static const _app = 'secrets.myscript.sealed.applicationKey';
  static const _hmac = 'secrets.myscript.sealed.hmacKey';
  // Plain-text values from older builds: encrypted and removed on first load.
  static const _oldApp = 'secrets.myscript.applicationKey';
  static const _oldHmac = 'secrets.myscript.hmacKey';

  Future<MyScriptKeys?> load() async {
    final p = prefs;
    final oldApp = await p.get(_oldApp);
    final oldHmac = await p.get(_oldHmac);
    if (oldApp != null || oldHmac != null) {
      if ((oldApp ?? '').isNotEmpty && (oldHmac ?? '').isNotEmpty) {
        await save(MyScriptKeys(oldApp!, oldHmac!));
      }
      await p.remove(_oldApp);
      await p.remove(_oldHmac);
    }
    final sealedApp = await p.get(_app);
    final sealedHmac = await p.get(_hmac);
    if (sealedApp == null || sealedHmac == null) return null;
    final app = await sealer.open(sealedApp);
    final hmac = await sealer.open(sealedHmac);
    if (app == null || app.isEmpty || hmac == null || hmac.isEmpty) {
      return null;
    }
    return MyScriptKeys(app, hmac);
  }

  /// Saves [keys] encrypted. False if this device can't store them safely.
  Future<bool> save(MyScriptKeys keys) async {
    final app = await sealer.seal(keys.applicationKey.trim());
    final hmac = await sealer.seal(keys.hmacKey.trim());
    if (app == null || hmac == null) return false;
    final p = prefs;
    await p.set(_app, app);
    await p.set(_hmac, hmac);
    return true;
  }

  Future<void> clear() async {
    final p = prefs;
    for (final k in [_app, _hmac, _oldApp, _oldHmac]) {
      await p.remove(k);
    }
  }
}
