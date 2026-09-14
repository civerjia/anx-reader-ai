import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/service/library_index/library_index.dart';
import 'package:flutter/material.dart';

/// Status of the library's full-text index, and the button that builds it.
class LibraryIndexSettings extends StatefulWidget {
  const LibraryIndexSettings({super.key});

  @override
  State<LibraryIndexSettings> createState() => _LibraryIndexSettingsState();
}

class _LibraryIndexSettingsState extends State<LibraryIndexSettings> {
  late Future<({int books, int chunks, int bytes})> _stats =
      LibraryIndex.instance.stats();
  bool _wasRunning = false;

  @override
  void initState() {
    super.initState();
    LibraryIndex.instance.status.addListener(_statusChanged);
  }

  @override
  void dispose() {
    LibraryIndex.instance.status.removeListener(_statusChanged);
    super.dispose();
  }

  void _statusChanged() {
    final running = LibraryIndex.instance.status.value.running;
    if (_wasRunning && !running && mounted) {
      setState(() => _stats = LibraryIndex.instance.stats());
    }
    _wasRunning = running;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return ValueListenableBuilder<LibraryIndexStatus>(
      valueListenable: LibraryIndex.instance.status,
      builder: (context, status, _) => FutureBuilder(
        future: _stats,
        builder: (context, snapshot) {
          final stats = snapshot.data;
          final built = (stats?.books ?? 0) > 0;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(status.running
                    ? l10n.libraryIndexProgress(
                        status.done, status.total, status.title)
                    : built
                        ? l10n.libraryIndexSummary(stats!.books, stats.chunks,
                            '${(stats.bytes / 1048576).toStringAsFixed(1)} MB')
                        : l10n.libraryIndexEmpty),
                trailing: FilledButton.tonal(
                  onPressed: status.running
                      ? null
                      : () => LibraryIndex.instance.updateAll(),
                  child: Text(
                      built ? l10n.libraryIndexUpdate : l10n.libraryIndexBuild),
                ),
              ),
              if (status.running)
                LinearProgressIndicator(
                  value: status.total == 0 ? null : status.done / status.total,
                ),
            ],
          );
        },
      ),
    );
  }
}
