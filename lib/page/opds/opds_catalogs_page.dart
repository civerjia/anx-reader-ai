import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/opds_catalog.dart';
import 'package:anx_reader/page/opds/opds_browser_page.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

/// The reader's OPDS catalogs: add, edit, remove, and open one to browse.
class OpdsCatalogsPage extends StatefulWidget {
  const OpdsCatalogsPage({super.key});

  @override
  State<OpdsCatalogsPage> createState() => _OpdsCatalogsPageState();
}

class _OpdsCatalogsPageState extends State<OpdsCatalogsPage> {
  List<OpdsCatalog> _catalogs = Prefs().opdsCatalogs;

  void _save(List<OpdsCatalog> catalogs) {
    Prefs().opdsCatalogs = catalogs;
    setState(() => _catalogs = catalogs);
  }

  Future<void> _edit(OpdsCatalog? existing) async {
    final edited = await showDialog<OpdsCatalog>(
      context: context,
      builder: (_) => _CatalogDialog(existing: existing),
    );
    if (edited == null) return;
    final next = [..._catalogs];
    final index = next.indexWhere((c) => c.id == edited.id);
    if (index >= 0) {
      next[index] = edited;
    } else {
      next.add(edited);
    }
    _save(next);
  }

  Future<void> _delete(OpdsCatalog catalog) async {
    final l10n = L10n.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(l10n.opdsDeleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (ok == true) _save(_catalogs.where((c) => c.id != catalog.id).toList());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.opdsCatalogs),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: l10n.opdsAddCatalog,
            onPressed: () => _edit(null),
          ),
        ],
      ),
      body: _catalogs.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(l10n.opdsNoCatalogs),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: () => _edit(null),
                    icon: const Icon(Icons.add),
                    label: Text(l10n.opdsAddCatalog),
                  ),
                ],
              ),
            )
          : ListView(
              children: [
                for (final catalog in _catalogs)
                  ListTile(
                    leading: const Icon(Icons.public),
                    title: Text(catalog.title),
                    subtitle: Text(
                      catalog.url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => OpdsBrowserPage(
                          catalog: catalog,
                          url: Uri.parse(catalog.url.trim()),
                          title: catalog.title,
                        ),
                      ),
                    ),
                    trailing: PopupMenuButton<String>(
                      onSelected: (action) => action == 'edit'
                          ? _edit(catalog)
                          : _delete(catalog),
                      itemBuilder: (_) => [
                        PopupMenuItem(
                            value: 'edit', child: Text(l10n.opdsEditCatalog)),
                        PopupMenuItem(
                            value: 'delete', child: Text(l10n.commonDelete)),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class _CatalogDialog extends StatefulWidget {
  const _CatalogDialog({this.existing});
  final OpdsCatalog? existing;

  @override
  State<_CatalogDialog> createState() => _CatalogDialogState();
}

class _CatalogDialogState extends State<_CatalogDialog> {
  late final _name = TextEditingController(text: widget.existing?.title ?? '');
  late final _url = TextEditingController(text: widget.existing?.url ?? '');
  late final _user = TextEditingController(text: widget.existing?.username ?? '');
  late final _pass = TextEditingController(text: widget.existing?.password ?? '');
  String? _urlError;

  @override
  void dispose() {
    for (final c in [_name, _url, _user, _pass]) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final url = _url.text.trim();
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty) {
      setState(() => _urlError = L10n.of(context).opdsInvalidUrl);
      return;
    }
    final name = _name.text.trim().isEmpty ? uri.host : _name.text.trim();
    Navigator.pop(
      context,
      OpdsCatalog(
        id: widget.existing?.id ?? const Uuid().v4(),
        title: name,
        url: url,
        username: _user.text.trim(),
        password: _pass.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return AlertDialog(
      title: Text(widget.existing == null ? l10n.opdsAddCatalog : l10n.opdsEditCatalog),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: l10n.opdsCatalogUrl,
                hintText: l10n.opdsCatalogUrlHint,
                errorText: _urlError,
              ),
            ),
            TextField(
              controller: _name,
              decoration: InputDecoration(labelText: l10n.opdsCatalogName),
            ),
            TextField(
              controller: _user,
              autocorrect: false,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: l10n.opdsUsername,
                helperText: l10n.opdsCredentialsOptional,
              ),
            ),
            TextField(
              controller: _pass,
              obscureText: true,
              decoration: InputDecoration(labelText: l10n.opdsPassword),
              onChanged: (_) => setState(() {}),
            ),
            // Allowed, because a server on the home network rarely has TLS,
            // but not silently.
            if (_url.text.trim().toLowerCase().startsWith('http://') &&
                _user.text.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  l10n.opdsInsecureCredentials,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        TextButton(onPressed: _submit, child: Text(l10n.commonConfirm)),
      ],
    );
  }
}
