import 'dart:io';

import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/service/dictionary/dictionary_library.dart';
import 'package:anx_reader/service/dictionary/dictionary_service.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

/// Imported StarDict dictionaries: what is installed, importing more, and
/// removing them.
class DictionarySettings extends StatefulWidget {
  const DictionarySettings({super.key});

  @override
  State<DictionarySettings> createState() => _DictionarySettingsState();
}

class _DictionarySettingsState extends State<DictionarySettings> {
  late Future<List<InstalledDictionary>> _installed =
      dictionaryLibrary.installed();
  bool _importing = false;

  void _reload() => setState(() => _installed = dictionaryLibrary.installed());

  Future<void> _import() async {
    final l10n = L10n.of(context);
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null) return;
    final files = [
      for (final picked in result.files)
        if (picked.path != null) File(picked.path!),
    ];
    if (files.isEmpty) return;
    setState(() => _importing = true);
    try {
      final names = await dictionaryLibrary.import(files);
      AnxToast.show(names.isEmpty
          ? l10n.dictionaryImportNothing
          : l10n.dictionaryImported(names.join('、')));
    } catch (e) {
      AnxLog.info('Dictionary import failed: $e');
      AnxToast.show(l10n.dictionaryImportNothing);
    } finally {
      if (mounted) {
        setState(() => _importing = false);
        _reload();
      }
    }
  }

  Future<void> _remove(InstalledDictionary dictionary) async {
    final l10n = L10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(l10n.dictionaryDeleteConfirm(dictionary.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(MaterialLocalizations.of(dialogContext).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(MaterialLocalizations.of(dialogContext).okButtonLabel),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await dictionaryLibrary.remove(dictionary);
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FutureBuilder<List<InstalledDictionary>>(
          future: _installed,
          builder: (context, snapshot) {
            final dictionaries = snapshot.data ?? const [];
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(12),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (dictionaries.isEmpty) {
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.menu_book_outlined),
                title: Text(l10n.dictionaryEmpty),
              );
            }
            return Column(
              children: [
                for (final dictionary in dictionaries)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.menu_book_outlined),
                    title: Text(dictionary.name),
                    subtitle: Text(l10n.dictionaryWordCount(dictionary.wordCount)),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _remove(dictionary),
                    ),
                  ),
              ],
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            l10n.dictionaryImportHint,
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            onPressed: _importing ? null : _import,
            icon: _importing
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.file_download_outlined),
            label: Text(l10n.dictionaryImport),
          ),
        ),
      ],
    );
  }
}
