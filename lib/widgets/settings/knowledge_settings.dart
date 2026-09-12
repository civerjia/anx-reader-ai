import 'dart:io';

import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/service/knowledge/kiwix_catalog.dart';
import 'package:anx_reader/service/knowledge/knowledge_downloads.dart';
import 'package:anx_reader/service/knowledge/knowledge_library.dart';
import 'package:anx_reader/service/knowledge/knowledge_service.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

String _size(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 || unit == 0 ? 0 : 1)} ${units[unit]}';
}

/// The offline encyclopedia: packs on this device, downloads, and the Kiwix
/// catalog to choose new packs from.
class KnowledgeSettings extends StatefulWidget {
  const KnowledgeSettings({super.key});

  @override
  State<KnowledgeSettings> createState() => _KnowledgeSettingsState();
}

class _KnowledgeSettingsState extends State<KnowledgeSettings> {
  late Future<List<KnowledgePack>> _installed = knowledgeLibrary.installed();
  Future<List<KiwixPack>>? _catalog;

  @override
  void initState() {
    super.initState();
    knowledgeDownloads.addListener(_downloadsChanged);
  }

  @override
  void dispose() {
    knowledgeDownloads.removeListener(_downloadsChanged);
    super.dispose();
  }

  void _downloadsChanged() {
    if (!mounted) return;
    setState(() {
      if (knowledgeDownloads.states.isEmpty) {
        _installed = knowledgeLibrary.installed();
      }
    });
  }

  String _flavour(L10n l10n, String flavour) => switch (flavour) {
        'mini' => l10n.knowledgeFlavourMini,
        'nopic' => l10n.knowledgeFlavourNopic,
        'maxi' => l10n.knowledgeFlavourMaxi,
        _ => flavour,
      };

  Future<List<KiwixPack>> _loadCatalog() async {
    final response = await Dio().getUri<String>(kiwixCatalogUrl(),
        options: Options(responseType: ResponseType.plain));
    final packs = parseKiwixCatalog(response.data ?? '');
    // The whole Wikipedia and its most-read selection first, smallest first.
    int rank(KiwixPack p) => p.name.endsWith('_all') ? 0 : p.name.endsWith('_top') ? 1 : 2;
    packs.sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      return byRank != 0 ? byRank : a.approximateSize.compareTo(b.approximateSize);
    });
    return packs;
  }

  Future<void> _confirmDownload(KiwixPack pack) async {
    final l10n = L10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(l10n.knowledgeDownloadConfirm(
            '${pack.title} · ${_flavour(l10n, pack.flavour)}', _size(pack.approximateSize))),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(MaterialLocalizations.of(dialogContext).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.knowledgeDownload),
          ),
        ],
      ),
    );
    if (confirmed == true) knowledgeDownloads.start(pack);
  }

  Future<void> _remove(KnowledgePack pack) async {
    final l10n = L10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(l10n.knowledgeDeleteConfirm(pack.title)),
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
    await knowledgeLibrary.remove(pack);
    if (mounted) setState(() => _installed = knowledgeLibrary.installed());
  }

  Future<void> _import() async {
    final l10n = L10n.of(context);
    final result = await FilePicker.platform.pickFiles();
    final path = result?.files.single.path;
    if (path == null) return;
    final pack = await knowledgeLibrary.import(File(path));
    if (pack == null) {
      AnxToast.show(l10n.knowledgeImportFailed);
      return;
    }
    if (mounted) setState(() => _installed = knowledgeLibrary.installed());
  }

  Widget _downloadRow(L10n l10n, KiwixPack pack) {
    final state = knowledgeDownloads.states[pack.fileName];
    final partial = state?.received ?? knowledgeDownloads.partialBytes(pack);
    final total = state?.total ?? 0;
    final running = state?.running ?? false;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text('${pack.title} · ${_flavour(l10n, pack.flavour)}'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text([
            _size(pack.approximateSize),
            l10n.knowledgeArticles(pack.articleCount),
            if (pack.updated != null)
              '${pack.updated!.year}-${pack.updated!.month.toString().padLeft(2, '0')}',
          ].join(' · ')),
          if (running || partial > 0) ...[
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: total > 0 ? partial / total : (pack.approximateSize > 0 ? partial / pack.approximateSize : null),
            ),
            Text('${_size(partial)} / ${_size(total > 0 ? total : pack.approximateSize)}'),
          ],
          if (state?.error != null)
            Text(l10n.knowledgeDownloadFailed(state!.error!),
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
      ),
      trailing: running
          ? IconButton(
              tooltip: l10n.knowledgePause,
              icon: const Icon(Icons.pause),
              onPressed: () => knowledgeDownloads.pause(pack),
            )
          : IconButton(
              tooltip: partial > 0 ? l10n.knowledgeResume : l10n.knowledgeDownload,
              icon: Icon(partial > 0 ? Icons.play_arrow : Icons.download_outlined),
              onPressed: () =>
                  partial > 0 ? knowledgeDownloads.start(pack) : _confirmDownload(pack),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.knowledgeBaseHint,
            style: TextStyle(fontSize: 12, color: Colors.grey[600])),
        const SizedBox(height: 8),
        Text(l10n.knowledgeInstalled, style: Theme.of(context).textTheme.titleSmall),
        FutureBuilder<List<KnowledgePack>>(
          future: _installed,
          builder: (context, snapshot) {
            final packs = snapshot.data ?? const <KnowledgePack>[];
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(8),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (packs.isEmpty) {
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.public_off_outlined),
                title: Text(l10n.knowledgeNoneInstalled),
              );
            }
            return Column(children: [
              for (final pack in packs)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.public),
                  title: Text(pack.title),
                  subtitle: Text([
                    _flavour(l10n, pack.flavour),
                    l10n.knowledgeArticles(pack.articleCount),
                    _size(pack.sizeBytes),
                    if (pack.date.isNotEmpty) pack.date,
                  ].join(' · ')),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _remove(pack),
                  ),
                ),
            ]);
          },
        ),
        for (final state in knowledgeDownloads.states.values) _downloadRow(l10n, state.pack),
        Wrap(
          spacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: () => setState(() => _catalog = _loadCatalog()),
              icon: const Icon(Icons.cloud_download_outlined),
              label: Text(l10n.knowledgeLoadCatalog),
            ),
            OutlinedButton.icon(
              onPressed: _import,
              icon: const Icon(Icons.file_open_outlined),
              label: Text(l10n.knowledgeImport),
            ),
          ],
        ),
        if (_catalog != null)
          FutureBuilder<List<KiwixPack>>(
            future: _catalog,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Text(l10n.knowledgeCatalogFailed('${snapshot.error}'),
                    style: TextStyle(color: Theme.of(context).colorScheme.error));
              }
              if (!snapshot.hasData) {
                return const Padding(
                  padding: EdgeInsets.all(8),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 8),
                  Text(l10n.knowledgeAvailable, style: Theme.of(context).textTheme.titleSmall),
                  for (final pack in snapshot.data!)
                    if (!knowledgeDownloads.states.containsKey(pack.fileName))
                      _downloadRow(l10n, pack),
                ],
              );
            },
          ),
      ],
    );
  }
}
