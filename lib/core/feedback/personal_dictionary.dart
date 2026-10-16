/// The user's own words and shorthand (owner: a dictionary they can add to
/// in Settings and from the PDF; shorthand learned from their corrections,
/// e.g. "w/" -> "with"). Words are preferred when reading; shorthand is
/// written out in full in typed text and found by search. Pure Dart.
library;

class Shorthand {
  const Shorthand(this.full, {this.learned = false});

  /// What it stands for.
  final String full;

  /// Learned from corrections (rather than added by the user).
  final bool learned;
}

class PersonalDictionary {
  final _words = <String>{};
  final _short = <String, Shorthand>{};

  /// Corrections that look like shorthand, until they're learned.
  final _seen = <String, int>{};

  /// The same shorthand correction this often, and it's learned.
  static const learnAfter = 2;

  static String _k(String s) => s.trim().toLowerCase();

  List<String> get words => _words.toList()..sort();

  Map<String, Shorthand> get shorthand => Map.unmodifiable(_short);

  void addWord(String word) {
    final w = word.trim();
    if (w.isNotEmpty) _words.add(w);
  }

  void removeWord(String word) => _words.remove(word);

  void addShorthand(String short, String full, {bool learned = false}) {
    final s = _k(short), f = full.trim();
    if (s.isEmpty || f.isEmpty || s == _k(f)) return;
    _short[s] = Shorthand(f, learned: learned);
  }

  void removeShorthand(String short) {
    _short.remove(_k(short));
    // Not learned again from the corrections already seen.
    _seen.removeWhere((k, _) => k.startsWith('${_k(short)}\u0000'));
  }

  /// [recognised] corrected to [corrected]: when it looks like shorthand
  /// written out ([looksLikeShorthand]) [learnAfter] times, it's learned.
  /// True when it was learned just now.
  bool learnFromCorrection(String recognised, String corrected) {
    if (!looksLikeShorthand(recognised, corrected)) return false;
    final s = _k(recognised);
    if (_short.containsKey(s)) return false;
    final key = '$s\u0000${_k(corrected)}';
    final n = (_seen[key] ?? 0) + 1;
    _seen[key] = n;
    if (n < learnAfter) return false;
    addShorthand(recognised, corrected, learned: true);
    _seen.remove(key);
    return true;
  }

  /// Whether [short] could be shorthand for [full]: short (at most 5
  /// characters), at least 2 letters shorter, the same first letter, and
  /// its letters in [full] in the same order ("b/c" for "because").
  static bool looksLikeShorthand(String short, String full) {
    final s = short.trim().toLowerCase(), f = full.trim().toLowerCase();
    if (s.isEmpty || s.length > 5 || f.length < s.length + 2) return false;
    final sl = s.replaceAll(RegExp('[^a-z0-9]'), '');
    final fl = f.replaceAll(RegExp('[^a-z0-9]'), '');
    if (sl.isEmpty || fl.isEmpty || sl[0] != fl[0]) return false;
    var i = 0;
    for (final c in fl.split('')) {
      if (i < sl.length && c == sl[i]) i++;
    }
    return i == sl.length;
  }

  /// [text] with shorthand written out in full (word by word; a full stop
  /// or comma after it stays).
  String expand(String text) {
    if (_short.isEmpty) return text;
    return text
        .split(' ')
        .map((token) {
          final m = RegExp(r'^(.*?)([.,;:!?]*)$').firstMatch(token)!;
          final word = m.group(1)!, tail = m.group(2)!;
          final s = _short[_k(token)] ?? _short[_k(word)];
          if (s == null) return token;
          return _short.containsKey(_k(token)) ? s.full : '${s.full}$tail';
        })
        .join(' ');
  }

  Map<String, Object?> toJson() => {
    'words': words,
    'short': {
      for (final e in _short.entries)
        e.key: {'full': e.value.full, if (e.value.learned) 'learned': true},
    },
    'seen': _seen,
  };

  void load(Object? j) {
    _words.clear();
    _short.clear();
    _seen.clear();
    if (j is! Map) return;
    for (final w in (j['words'] as List?) ?? const []) {
      if (w is String) addWord(w);
    }
    final short = j['short'];
    if (short is Map) {
      for (final e in short.entries) {
        final v = e.value;
        if (e.key is String && v is Map && v['full'] is String) {
          addShorthand(
            e.key as String,
            v['full'] as String,
            learned: v['learned'] == true,
          );
        }
      }
    }
    final seen = j['seen'];
    if (seen is Map) {
      for (final e in seen.entries) {
        if (e.key is String && e.value is int) {
          _seen[e.key as String] = e.value as int;
        }
      }
    }
  }

  static const prefsKey = 'dictionary';
}
