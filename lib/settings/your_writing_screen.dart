import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/writing_profile.dart';

/// "Your writing" (owner: the learned size and slant shown, and editable;
/// learning carries on from what's set).
class YourWritingScreen extends StatefulWidget {
  const YourWritingScreen({super.key, this.load = _load, this.save = _save});

  final Future<WritingProfile> Function() load;
  final Future<void> Function(WritingProfile profile) save;

  static Future<WritingProfile> _load() async {
    final p = WritingProfile();
    final raw = await SharedPreferencesAsync().getString(
      WritingProfile.prefsKey,
    );
    if (raw != null) p.load(jsonDecode(raw));
    return p;
  }

  static Future<void> _save(WritingProfile p) => SharedPreferencesAsync()
      .setString(WritingProfile.prefsKey, jsonEncode(p.toJson()));

  @override
  State<YourWritingScreen> createState() => _YourWritingScreenState();
}

class _YourWritingScreenState extends State<YourWritingScreen> {
  WritingProfile? _profile;
  double _mm = 4, _slant = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget
        .load()
        .then((p) {
          if (!mounted) return;
          setState(() {
            _profile = p;
            final l = p.letterHeight;
            if (l != null) _mm = pointsToMm(l).clamp(1.0, 25.0);
            _slant = (p.slantDegrees ?? 0).clamp(-30.0, 30.0);
          });
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = "Couldn't read it: $e");
        });
  }

  Future<void> _store(
    void Function(WritingProfile p) change,
    String done,
  ) async {
    final p = _profile;
    if (p == null) return;
    change(p);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.save(p);
      if (!mounted) return;
      setState(() {});
      messenger.showSnackBar(SnackBar(content: Text(done)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text("Couldn't save it: $e")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _profile;
    final known = p?.letterHeight != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Your writing')),
      body: p == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Text(_error!),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  known
                      ? 'Learned from ${p.lines} lines of your writing. '
                            'Change it if it\'s not right: learning carries '
                            'on from what you set.'
                      : 'Not learned yet: write a few lines in any PDF or '
                            'notebook. You can also set it yourself.',
                ),
                const SizedBox(height: 24),
                Text(
                  'Usual letter height: ${_mm.toStringAsFixed(1)} mm',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Slider(
                  value: _mm,
                  min: 1,
                  max: 25,
                  divisions: 240,
                  label: '${_mm.toStringAsFixed(1)} mm',
                  onChanged: (v) => setState(() => _mm = v),
                ),
                const Text(
                  'Used to read the first few words on a new page, and to '
                  'space "Lined to fit your writing".',
                ),
                const SizedBox(height: 24),
                Text(
                  'Usual slant of your lines: ${_slant.round()}°',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Slider(
                  value: _slant,
                  min: -30,
                  max: 30,
                  divisions: 60,
                  label: '${_slant.round()}°',
                  onChanged: (v) => setState(() => _slant = v),
                ),
                const Text(
                  'How far your lines usually run uphill (+) or downhill '
                  '(−) when you write across a page.',
                ),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton(
                      onPressed: () => _store(
                        (p) => p.set(
                          letterHeight: mmToPoints(_mm),
                          slantDegrees: _slant,
                        ),
                        'Saved. Learning carries on from here.',
                      ),
                      child: const Text('Save'),
                    ),
                    OutlinedButton(
                      onPressed: () => _store((p) {
                        p.forget();
                        _mm = 4;
                        _slant = 0;
                      }, 'Learning starts again from your next lines.'),
                      child: const Text('Start learning again'),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
