import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/opds_catalog.dart';
import 'package:anx_reader/service/book.dart';
import 'package:anx_reader/service/opds/opds_client.dart';
import 'package:anx_reader/service/opds/opds_feed.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One page of an OPDS catalog: folders to open and books to download.
class OpdsBrowserPage extends ConsumerStatefulWidget {
  const OpdsBrowserPage({
    super.key,
    required this.catalog,
    required this.url,
    required this.title,
  });

  final OpdsCatalog catalog;
  final Uri url;
  final String title;

  @override
  ConsumerState<OpdsBrowserPage> createState() => _OpdsBrowserPageState();
}

class _OpdsBrowserPageState extends ConsumerState<OpdsBrowserPage> {
  late final OpdsClient _client = OpdsClient(widget.catalog);
  final List<OpdsEntry> _entries = [];
  final Map<String, double> _downloads = {};
  final Map<String, CancelToken> _cancelTokens = {};
  Uri? _next;
  String? _searchTemplate;
  bool _loading = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load(widget.url);
  }

  @override
  void dispose() {
    for (final token in _cancelTokens.values) {
      token.cancel();
    }
    super.dispose();
  }

  Future<void> _load(Uri url, {bool append = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final feed = await _client.fetch(url);
      final template =
          append ? _searchTemplate : await _client.searchTemplate(feed);
      if (!mounted) return;
      setState(() {
        if (!append) _entries.clear();
        _entries.addAll(feed.entries);
        _next = feed.next;
        _searchTemplate = template;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _open(OpdsEntry entry) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => OpdsBrowserPage(
          catalog: widget.catalog,
          url: entry.navigation!,
          title: entry.title,
        ),
      ),
    );
  }

  void _search(String query) {
    final template = _searchTemplate;
    if (template == null || query.trim().isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => OpdsBrowserPage(
          catalog: widget.catalog,
          url: _client.searchUrl(template, query.trim()),
          title: query.trim(),
        ),
      ),
    );
  }

  /// Formats the importer accepts, in the catalog's preference order.
  List<OpdsAcquisition> _importable(OpdsEntry entry) => entry.acquisitions
      .where((a) => a.extension != null && allowBookExtensions.contains(a.extension))
      .toList();

  Future<void> _download(OpdsEntry entry) async {
    final l10n = L10n.of(context);
    final formats = _importable(entry);
    if (formats.isEmpty) {
      AnxToast.show(l10n.opdsNoSupportedFormat);
      return;
    }
    if (_downloads.containsKey(entry.id)) return;
    final token = CancelToken();
    _cancelTokens[entry.id] = token;
    setState(() => _downloads[entry.id] = 0);
    try {
      final file = await _client.download(
        entry,
        formats.first,
        cancelToken: token,
        onProgress: (received, total) {
          if (!mounted || total <= 0) return;
          setState(() => _downloads[entry.id] = received / total);
        },
      );
      if (!mounted) return;
      AnxToast.show(l10n.opdsDownloaded(entry.title));
      importBookList([file], context, ref);
    } catch (e) {
      if (!token.isCancelled) AnxToast.show(l10n.opdsDownloadFailed('$e'));
    } finally {
      _cancelTokens.remove(entry.id);
      if (mounted) setState(() => _downloads.remove(entry.id));
    }
  }

  Map<String, String> get _imageHeaders => {
        if (widget.catalog.hasCredentials)
          'Authorization': OpdsClient(widget.catalog).authorizationHeader!,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        bottom: _searchTemplate == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(56),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: TextField(
                    textInputAction: TextInputAction.search,
                    onSubmitted: _search,
                    decoration: InputDecoration(
                      hintText: l10n.opdsSearchHint,
                      prefixIcon: const Icon(Icons.search),
                      isDense: true,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24)),
                    ),
                  ),
                ),
              ),
      ),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    final l10n = L10n.of(context);
    if (_error != null && _entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l10n.opdsLoadFailed('$_error'), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => _load(widget.url),
                child: Text(l10n.opdsRetry),
              ),
            ],
          ),
        ),
      );
    }
    if (_loading && _entries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_entries.isEmpty) return Center(child: Text(l10n.opdsEmpty));

    return ListView.builder(
      itemCount: _entries.length + 1,
      itemBuilder: (context, index) {
        if (index == _entries.length) {
          if (_next == null) return const SizedBox(height: 24);
          return Padding(
            padding: const EdgeInsets.all(12),
            child: Center(
              child: _loading
                  ? const CircularProgressIndicator()
                  : TextButton(
                      onPressed: () => _load(_next!, append: true),
                      child: Text(l10n.opdsLoadMore),
                    ),
            ),
          );
        }
        final entry = _entries[index];
        return entry.isBook ? _bookTile(entry) : _folderTile(entry);
      },
    );
  }

  Widget _folderTile(OpdsEntry entry) => ListTile(
        leading: const Icon(Icons.folder_outlined),
        title: Text(entry.title),
        subtitle: entry.summary.isEmpty
            ? null
            : Text(entry.summary, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right),
        onTap: entry.navigation == null ? null : () => _open(entry),
      );

  Widget _bookTile(OpdsEntry entry) {
    final l10n = L10n.of(context);
    final progress = _downloads[entry.id];
    final formats = entry.acquisitions
        .map((a) => a.extension ?? '?')
        .toSet()
        .join(' · ')
        .toUpperCase();
    return ListTile(
      leading: SizedBox(
        width: 44,
        height: 64,
        child: entry.thumbnail == null
            ? const Icon(Icons.menu_book_outlined)
            : CachedNetworkImage(
                imageUrl: entry.thumbnail.toString(),
                httpHeaders: _imageHeaders,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => const Icon(Icons.menu_book_outlined),
              ),
      ),
      title: Text(entry.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        progress == null
            ? [if (entry.author.isNotEmpty) entry.author, formats].join('\n')
            : l10n.opdsDownloading((progress * 100).round()),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: progress == null
          ? IconButton(
              icon: const Icon(Icons.download_outlined),
              onPressed: () => _download(entry),
            )
          : SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(value: progress == 0 ? null : progress),
            ),
      onTap: () => _download(entry),
    );
  }
}
