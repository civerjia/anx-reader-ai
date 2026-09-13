import 'dart:convert';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/service/tts/probe/speech_probe.dart';
import 'package:anx_reader/service/tts/probe/speech_probe_cases.dart';
import 'package:anx_reader/service/tts/tts_service.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Plays probe sentences with the system voice and records, per sentence,
/// whether it was read right. Verdicts are kept across visits and written to
/// the app log.
class SpeechProbePage extends StatefulWidget {
  const SpeechProbePage({super.key});

  @override
  State<SpeechProbePage> createState() => _SpeechProbePageState();
}

class _SpeechProbePageState extends State<SpeechProbePage> {
  static const _verdictsKey = 'speechProbeVerdicts';

  late final Map<String, bool> _verdicts = _load();
  String? _playing;
  String _voice = '';

  Map<String, bool> _load() {
    try {
      final saved = Prefs().prefs.getString(_verdictsKey);
      if (saved == null) return {};
      return Map<String, bool>.from(jsonDecode(saved) as Map);
    } catch (_) {
      return {};
    }
  }

  @override
  void dispose() {
    SpeechProbe.stop();
    super.dispose();
  }

  Future<void> _play(ProbeCase probe) async {
    setState(() => _playing = probe.id);
    final multiplier = Prefs().ttsRate <= 0 ? 1.0 : Prefs().ttsRate;
    final used = await SpeechProbe.speak(
      probe,
      voice: SystemTtsProvider().getSelectedVoice(),
      rate: (multiplier * 0.5).clamp(0.05, 1.0),
    );
    if (used != null && mounted) {
      setState(() => _voice =
          '${used['name']} · ${used['language']} · quality ${used['quality']}');
    }
  }

  void _judge(ProbeCase probe, bool right) {
    setState(() {
      if (_verdicts[probe.id] == right) {
        _verdicts.remove(probe.id);
      } else {
        _verdicts[probe.id] = right;
      }
    });
    Prefs().prefs.setString(_verdictsKey, jsonEncode(_verdicts));
    AnxLog.info('SpeechProbe: ${probe.id} ${_verdicts[probe.id] == null ? 'cleared' : right ? 'right' : 'WRONG'} '
        '"${probe.text}" expect ${probe.expect} voice $_voice');
  }

  String _summary() {
    final lines = <String>['voice: $_voice'];
    for (final group in speechProbeGroups) {
      for (final probe in group.cases) {
        final verdict = _verdicts[probe.id];
        final mark = verdict == null ? '?' : verdict ? '✓' : '✗';
        lines.add('$mark ${probe.id} ${probe.text} | ${probe.expect}');
      }
    }
    return lines.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final judged = _verdicts.length;
    final total =
        speechProbeGroups.fold<int>(0, (sum, g) => sum + g.cases.length);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.settingsNarrateSpeechProbe),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all_outlined),
            tooltip: l10n.speechProbeCopy,
            onPressed: () {
              final summary = _summary();
              Clipboard.setData(ClipboardData(text: summary));
              AnxLog.info('SpeechProbe: summary\n$summary');
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l10n.speechProbeCopied)));
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(l10n.speechProbeHint(judged, total)),
          ),
          if (_voice.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(_voice, style: Theme.of(context).textTheme.bodySmall),
            ),
          for (final group in speechProbeGroups) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 2),
              child: Text(group.title,
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(group.note,
                  style: Theme.of(context).textTheme.bodySmall),
            ),
            for (final probe in group.cases) _row(probe),
          ],
        ],
      ),
    );
  }

  Widget _row(ProbeCase probe) {
    final verdict = _verdicts[probe.id];
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 4, right: 8),
      leading: IconButton(
        icon: Icon(_playing == probe.id
            ? Icons.volume_up
            : Icons.play_circle_outline),
        onPressed: () => _play(probe),
      ),
      title: Text(probe.text),
      subtitle: Text(
          '${probe.id} · ${probe.expect}${probe.marks.isEmpty ? '' : ' · ${probe.marks.map((m) => '${m.target}=${m.notation}').join(' ')}'}'),
      onTap: () => _play(probe),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(Icons.check_circle,
                color: verdict == true ? Colors.green : scheme.outlineVariant),
            onPressed: () => _judge(probe, true),
          ),
          IconButton(
            icon: Icon(Icons.cancel,
                color: verdict == false ? scheme.error : scheme.outlineVariant),
            onPressed: () => _judge(probe, false),
          ),
        ],
      ),
    );
  }
}
