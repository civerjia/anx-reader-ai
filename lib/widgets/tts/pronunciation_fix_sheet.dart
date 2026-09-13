import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/service/tts/probe/speech_probe.dart';
import 'package:anx_reader/service/tts/text/pronunciation_fixes.dart';
import 'package:anx_reader/service/tts/text/pronunciation_lexicon.dart';
import 'package:anx_reader/service/tts/tts_service.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:flutter/material.dart';

/// Corrects how narration reads a word: pick the misread character and its
/// right reading, mark it or speak a homophone, listen, save.
class PronunciationFixSheet extends StatefulWidget {
  const PronunciationFixSheet({super.key, required this.word});

  final String word;

  static final _han = RegExp(r'^[一-鿿]{1,12}$');

  /// Whether [text] is something a reading can be fixed for.
  static bool canFix(String text) => _han.hasMatch(text.trim());

  static Future<void> show(BuildContext context, String word) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => PronunciationFixSheet(word: word.trim()),
      );

  @override
  State<PronunciationFixSheet> createState() => _PronunciationFixSheetState();
}

class _PronunciationFixSheetState extends State<PronunciationFixSheet> {
  CharReadings? _chars;
  PronunciationLexicon? _lexicon;
  PronunciationFix? _existing;

  List<int> _polyphonic = const [];
  int? _index;
  String? _reading;
  bool _useHomophone = false;
  String? _homophone;

  String get _word => widget.word;

  @override
  void initState() {
    super.initState();
    for (final fix in Prefs().pronunciationFixes) {
      if (fix.word == _word) _existing = fix;
    }
    Future.wait([CharReadings.load(), PronunciationLexicon.load()]).then((loaded) {
      if (!mounted) return;
      setState(() {
        _chars = loaded[0] as CharReadings;
        _lexicon = loaded[1] as PronunciationLexicon;
        _polyphonic = [
          for (var i = 0; i < _word.length; i++)
            if (_chars!.isPolyphonic(_word[i])) i,
        ];
        final existing = _existing;
        if (existing != null) {
          _index = existing.index;
          _reading = existing.reading;
          _useHomophone = existing.useHomophone;
          _homophone = existing.homophone;
        } else if (_polyphonic.isNotEmpty) {
          final suggested = _suggestions();
          _index = _polyphonic.firstWhere(suggested.containsKey,
              orElse: () => _polyphonic.first);
          _reading = _defaultReading(_index!);
        }
      });
    });
  }

  /// Readings the lexicon gives characters of the word.
  Map<int, String> _suggestions() => {
        for (final m in _lexicon?.marks(_word) ?? const <PronunciationMark>[])
          m.start: m.notation,
      };

  /// The lexicon's reading, or else the one the voice most likely did not
  /// say: not the character's most common reading.
  String? _defaultReading(int index) {
    final suggested = _suggestions()[index];
    if (suggested != null) return suggested;
    final readings = _chars!.of(_word[index]).where((r) => !r.endsWith('5')).toList();
    if (readings.isEmpty) return null;
    final usual = _chars!.usual(_word[index]);
    return readings.firstWhere((r) => r != usual, orElse: () => readings.first);
  }

  List<String> get _candidates => _reading == null || _index == null
      ? const []
      : _chars!.homophones(_reading!, except: _word[_index!]);

  PronunciationFix? get _fix {
    final index = _index;
    final reading = _reading;
    if (index == null || reading == null) return null;
    final homophone = _useHomophone ? (_homophone ?? _candidates.firstOrNull) : _homophone;
    if (_useHomophone && homophone == null) return null;
    return PronunciationFix(
      word: _word,
      index: index,
      reading: reading,
      homophone: homophone,
      useHomophone: _useHomophone,
    );
  }

  Future<void> _listen() async {
    final fix = _fix;
    if (fix == null) return;
    final text = PronunciationFixes.rewrite(_word, [fix]);
    final marks = PronunciationFixes.marks(text, [fix]);
    final multiplier = Prefs().ttsRate <= 0 ? 1.0 : Prefs().ttsRate;
    await SpeechProbe.speak(
      ProbeCase('fix', text, '', marks: [
        for (final m in marks) ProbeMark(text[m.start], m.notation, start: m.start),
      ]),
      voice: SystemTtsProvider().getSelectedVoice(),
      rate: (multiplier * 0.5).clamp(0.05, 1.0),
    );
  }

  void _save() {
    final fix = _fix;
    if (fix == null) return;
    Prefs().pronunciationFixes = [
      for (final f in Prefs().pronunciationFixes)
        if (f.word != _word) f,
      fix,
    ];
    AnxToast.show(L10n.of(context).pronunciationFixSaved);
    Navigator.of(context).pop();
  }

  void _delete() {
    Prefs().pronunciationFixes = [
      for (final f in Prefs().pronunciationFixes)
        if (f.word != _word) f,
    ];
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    SpeechProbe.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final chars = _chars;
    Widget label(String text) => Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 6),
          child: Text(text, style: theme.textTheme.labelLarge),
        );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: chars == null
            ? const SizedBox(
                height: 160, child: Center(child: CircularProgressIndicator()))
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(l10n.pronunciationFixTitle(_word),
                        style: theme.textTheme.titleMedium),
                    if (_polyphonic.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Text(l10n.pronunciationFixNoPolyphone),
                      )
                    else ...[
                      label(l10n.pronunciationFixChar),
                      Wrap(spacing: 8, children: [
                        for (final i in _polyphonic)
                          ChoiceChip(
                            label: Text(_word[i]),
                            selected: _index == i,
                            onSelected: (_) => setState(() {
                              _index = i;
                              _reading = _defaultReading(i);
                              _homophone = null;
                            }),
                          ),
                      ]),
                      label(l10n.pronunciationFixReading),
                      if (_suggestions()[_index] case final suggested?)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                              l10n.pronunciationFixSuggested(toneMarked(suggested)),
                              style: theme.textTheme.bodySmall),
                        ),
                      Wrap(spacing: 8, children: [
                        for (final r in chars.of(_word[_index!]))
                          ChoiceChip(
                            label: Text(toneMarked(r)),
                            selected: _reading == r,
                            onSelected: (_) => setState(() {
                              _reading = r;
                              _homophone = null;
                            }),
                          ),
                      ]),
                      const SizedBox(height: 16),
                      SegmentedButton<bool>(
                        segments: [
                          ButtonSegment(
                              value: false,
                              label: Text(l10n.pronunciationFixModeMark)),
                          ButtonSegment(
                              value: true,
                              label: Text(l10n.pronunciationFixModeHomophone)),
                        ],
                        selected: {_useHomophone},
                        onSelectionChanged: (value) =>
                            setState(() => _useHomophone = value.single),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(l10n.pronunciationFixModeHint,
                            style: theme.textTheme.bodySmall),
                      ),
                      if (_useHomophone) ...[
                        label(l10n.pronunciationFixHomophone),
                        if (_candidates.isEmpty)
                          Text(l10n.pronunciationFixNoHomophone)
                        else
                          Wrap(spacing: 8, children: [
                            for (final c in _candidates)
                              ChoiceChip(
                                label: Text(c),
                                selected: (_homophone ?? _candidates.first) == c,
                                onSelected: (_) => setState(() => _homophone = c),
                              ),
                          ]),
                      ],
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          if (SpeechProbe.isAvailable)
                            TextButton.icon(
                              onPressed: _fix == null ? null : _listen,
                              icon: const Icon(Icons.volume_up_outlined),
                              label: Text(l10n.pronunciationFixListen),
                            ),
                          const Spacer(),
                          if (_existing != null)
                            TextButton(
                              onPressed: _delete,
                              child: Text(l10n.pronunciationFixDelete),
                            ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: _fix == null ? null : _save,
                            child: Text(l10n.pronunciationFixSave),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
      ),
    );
  }
}
