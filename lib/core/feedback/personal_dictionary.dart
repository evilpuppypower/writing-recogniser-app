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
  /// written out ([looksLikeShorthand]) [learnAfter] times, true, and the
  /// user is asked whether it's their shorthand (it's never learned
  /// without asking: "in" corrected to "into" is usually a misreading).
  /// Counted again from nothing after each question.
  bool learnFromCorrection(String recognised, String corrected) {
    if (!looksLikeShorthand(recognised, corrected)) return false;
    final s = _k(recognised);
    if (_short.containsKey(s)) return false;
    final key = '$s\u0000${_k(corrected)}';
    final n = (_seen[key] ?? 0) + 1;
    _seen[key] = n;
    if (n < learnAfter) return false;
    _seen.remove(key);
    return true;
  }

  /// Corrections seen towards asking about shorthand, merged from
  /// [other]'s (the larger count of each).
  void mergeSeen(Map<String, int> other) {
    for (final e in other.entries) {
      if (e.value > (_seen[e.key] ?? 0)) _seen[e.key] = e.value;
    }
  }

  Map<String, int> get seen => Map.unmodifiable(_seen);

  /// Whether [short] could be shorthand for [full]: short (at most 5
  /// characters), at least 2 letters shorter, the same first letter, and
  /// its letters in [full] in the same order ("b/c" for "because"), and
  /// not an everyday word ("in" for "into" is a misreading, not
  /// shorthand).
  static bool looksLikeShorthand(String short, String full) {
    final s = short.trim().toLowerCase(), f = full.trim().toLowerCase();
    if (s.isEmpty || s.length > 5 || f.length < s.length + 2) return false;
    if (_everyday.contains(s)) return false;
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
  /// or comma after it stays, and a capital at the start stays: "B/c" is
  /// "Because").
  String expand(String text) {
    if (_short.isEmpty) return text;
    return text
        .split(' ')
        .map((token) {
          final m = RegExp(r'^(.*?)([.,;:!?]*)$').firstMatch(token)!;
          final word = m.group(1)!, tail = m.group(2)!;
          final s = _short[_k(token)] ?? _short[_k(word)];
          if (s == null) return token;
          final full = _capitalLike(token, s.full);
          return _short.containsKey(_k(token)) ? full : '$full$tail';
        })
        .join(' ');
  }

  static String _capitalLike(String token, String full) {
    if (token.isEmpty || full.isEmpty) return full;
    final first = token[0];
    final isCapital =
        first != first.toLowerCase() && first == first.toUpperCase();
    return isCapital ? full[0].toUpperCase() + full.substring(1) : full;
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

  /// Short everyday words that are never taken for shorthand.
  static const _everyday = {
    'a',
    'i',
    'an',
    'am',
    'as',
    'at',
    'be',
    'by',
    'do',
    'go',
    'he',
    'if',
    'in',
    'is',
    'it',
    'me',
    'my',
    'no',
    'of',
    'on',
    'or',
    'so',
    'to',
    'up',
    'us',
    'we',
    'all',
    'and',
    'any',
    'are',
    'but',
    'can',
    'did',
    'for',
    'get',
    'had',
    'has',
    'her',
    'him',
    'his',
    'how',
    'its',
    'let',
    'may',
    'new',
    'not',
    'now',
    'off',
    'old',
    'one',
    'our',
    'out',
    'own',
    'put',
    'say',
    'see',
    'set',
    'she',
    'the',
    'too',
    'two',
    'use',
    'was',
    'way',
    'who',
    'why',
    'yes',
    'yet',
    'you',
    'also',
    'back',
    'been',
    'both',
    'come',
    'does',
    'done',
    'each',
    'even',
    'from',
    'give',
    'good',
    'have',
    'here',
    'into',
    'just',
    'know',
    'last',
    'like',
    'make',
    'many',
    'more',
    'most',
    'much',
    'must',
    'next',
    'only',
    'over',
    'part',
    'same',
    'some',
    'such',
    'take',
    'than',
    'that',
    'them',
    'then',
    'they',
    'this',
    'time',
    'very',
    'want',
    'well',
    'were',
    'what',
    'when',
    'will',
    'with',
    'work',
    'year',
    'your',
    'about',
    'after',
    'again',
    'being',
    'could',
    'every',
    'first',
    'great',
    'never',
    'other',
    'right',
    'since',
    'still',
    'their',
    'there',
    'these',
    'thing',
    'think',
    'those',
    'three',
    'under',
    'until',
    'where',
    'which',
    'while',
    'would',
    'write',
  };
}
