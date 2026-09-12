import 'dart:convert';
import 'dart:io';

import 'package:anx_reader/service/knowledge/chinese_variants.dart';
import 'package:anx_reader/service/knowledge/zim_archive.dart';
import 'package:path/path.dart' as p;

/// A ZIM pack on this device, described by its own metadata.
class KnowledgePack {
  const KnowledgePack({
    required this.file,
    required this.title,
    required this.name,
    required this.language,
    required this.flavour,
    required this.date,
    required this.articleCount,
    required this.sizeBytes,
  });

  final File file;
  final String title;
  final String name;
  final String language;
  final String flavour;
  final String date;
  final int articleCount;
  final int sizeBytes;
}

/// An article found for a query: the pack it came from and its lead text.
class KnowledgeHit {
  const KnowledgeHit({
    required this.pack,
    required this.title,
    required this.text,
  });

  final KnowledgePack pack;
  final String title;
  final String text;
}

class KnowledgeLookup {
  const KnowledgeLookup({required this.hits, required this.suggestions});

  final List<KnowledgeHit> hits;

  /// Titles starting like the query, offered when nothing matched exactly.
  final List<String> suggestions;
}

/// The ways an article might be titled for [query]: as written, in the other
/// Chinese script, with a capital first letter (Wikipedia titles start with
/// one), and with underscores for spaces (as some paths are).
List<String> titleCandidates(String query) {
  final base = query.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (base.isEmpty) return const [];
  final candidates = <String>[];
  void add(String candidate) {
    if (candidate.isNotEmpty && !candidates.contains(candidate)) {
      candidates.add(candidate);
    }
  }

  for (final form in [base, toSimplifiedChinese(base), toTraditionalChinese(base)]) {
    add(form);
    if (RegExp(r'^[a-z]').hasMatch(form)) {
      add(form[0].toUpperCase() + form.substring(1));
    }
  }
  for (final candidate in List.of(candidates)) {
    if (candidate.contains(' ')) add(candidate.replaceAll(' ', '_'));
  }
  return candidates;
}

/// The ZIM packs kept under [root], looked up by article title.
class KnowledgeLibrary {
  KnowledgeLibrary(this.root);

  final Directory root;
  final _archives = <String, ZimArchive>{};
  final _packs = <String, KnowledgePack>{};

  Iterable<File> _zimFiles() {
    if (!root.existsSync()) return const [];
    return root
        .listSync()
        .whereType<File>()
        .where((file) => file.path.toLowerCase().endsWith('.zim'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  }

  Future<ZimArchive?> _archive(File file) async {
    final cached = _archives[file.path];
    if (cached != null) return cached;
    try {
      return _archives[file.path] = await ZimArchive.open(file);
    } catch (_) {
      return null;
    }
  }

  Future<KnowledgePack?> _pack(File file) async {
    final cached = _packs[file.path];
    if (cached != null) return cached;
    final archive = await _archive(file);
    if (archive == null) return null;
    final Map<String, String> metadata;
    try {
      metadata = await archive.metadata();
    } catch (_) {
      return null;
    }
    return _packs[file.path] = KnowledgePack(
      file: file,
      title: metadata['Title']?.trim().isNotEmpty == true
          ? metadata['Title']!.trim()
          : p.basenameWithoutExtension(file.path),
      name: metadata['Name'] ?? '',
      language: metadata['Language'] ?? '',
      flavour: metadata['Flavour'] ?? '',
      date: metadata['Date'] ?? '',
      articleCount: archive.entryCount,
      sizeBytes: file.lengthSync(),
    );
  }

  /// Readable packs on this device; files that cannot be read are left out.
  Future<List<KnowledgePack>> installed() async => [
        for (final file in _zimFiles())
          if (await _pack(file) case final pack?) pack,
      ];

  /// Articles titled [query] in any pack, as lead text; suggestions when none.
  Future<KnowledgeLookup> lookup(
    String query, {
    int maxCharacters = 1200,
    int maxHits = 2,
  }) async {
    final candidates = titleCandidates(query);
    if (candidates.isEmpty) {
      return const KnowledgeLookup(hits: [], suggestions: []);
    }
    final packs = await installed();
    final hits = <KnowledgeHit>[];
    for (final pack in packs) {
      if (hits.length >= maxHits) break;
      final archive = await _archive(pack.file);
      if (archive == null) continue;
      for (final candidate in candidates) {
        final ZimEntry? found;
        try {
          found = await archive.findByTitle(candidate) ??
              await archive.findByPath('C', candidate);
        } catch (_) {
          break;
        }
        if (found == null) continue;
        try {
          final article = await archive.resolve(found);
          if (!archive.mimeTypeOf(article).startsWith('text/html')) continue;
          final html = utf8.decode(await archive.content(article), allowMalformed: true);
          final text = articleLeadText(html, maxCharacters: maxCharacters);
          if (text.isEmpty) continue;
          hits.add(KnowledgeHit(pack: pack, title: article.title, text: text));
        } catch (_) {
          continue;
        }
        break;
      }
    }
    if (hits.isNotEmpty) return KnowledgeLookup(hits: hits, suggestions: const []);

    final suggestions = <String>[];
    for (final pack in packs) {
      final archive = await _archive(pack.file);
      if (archive == null) continue;
      for (final candidate in candidates.take(3)) {
        try {
          for (final entry in await archive.titlesStartingWith(candidate, limit: 8)) {
            if (!suggestions.contains(entry.title)) suggestions.add(entry.title);
          }
        } catch (_) {
          break;
        }
        if (suggestions.length >= 8) break;
      }
      if (suggestions.length >= 8) break;
    }
    return KnowledgeLookup(hits: const [], suggestions: suggestions.take(8).toList());
  }

  /// Copies a .zim file into the library if it can be read; returns its pack.
  Future<KnowledgePack?> import(File source) async {
    final probe = await () async {
      try {
        return await ZimArchive.open(source);
      } catch (_) {
        return null;
      }
    }();
    if (probe == null) return null;
    await probe.close();
    root.createSync(recursive: true);
    final target = File(p.join(root.path, p.basename(source.path)));
    if (target.path != source.path) await source.copy(target.path);
    return _pack(target);
  }

  Future<void> remove(KnowledgePack pack) async {
    await _archives.remove(pack.file.path)?.close();
    _packs.remove(pack.file.path);
    if (pack.file.existsSync()) await pack.file.delete();
  }

  /// Forgets cached packs, so files added or replaced on disk are read again.
  Future<void> refresh() async {
    for (final archive in _archives.values) {
      await archive.close();
    }
    _archives.clear();
    _packs.clear();
  }
}
