import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/service/tts/text/pronunciation_fixes.dart';
import 'package:anx_reader/widgets/tts/pronunciation_fix_sheet.dart';
import 'package:flutter/material.dart';

/// The words a listener corrected, to review, change or remove.
class PronunciationFixesPage extends StatefulWidget {
  const PronunciationFixesPage({super.key});

  @override
  State<PronunciationFixesPage> createState() => _PronunciationFixesPageState();
}

class _PronunciationFixesPageState extends State<PronunciationFixesPage> {
  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final fixes = Prefs().pronunciationFixes;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsNarratePronunciationFixes)),
      body: fixes.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(l10n.pronunciationFixesEmpty, textAlign: TextAlign.center),
              ),
            )
          : ListView.separated(
              itemCount: fixes.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final fix = fixes[i];
                final mode = fix.useHomophone
                    ? '${l10n.pronunciationFixModeHomophone} ${fix.homophone}'
                    : l10n.pronunciationFixModeMark;
                return ListTile(
                  title: Text(fix.word),
                  subtitle: Text('${fix.char} ${toneMarked(fix.reading)} · $mode'),
                  onTap: () async {
                    await PronunciationFixSheet.show(context, fix.word);
                    if (mounted) setState(() {});
                  },
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: l10n.pronunciationFixDelete,
                    onPressed: () => setState(() {
                      Prefs().pronunciationFixes = [
                        for (final f in fixes)
                          if (f.word != fix.word) f,
                      ];
                    }),
                  ),
                );
              },
            ),
    );
  }
}
