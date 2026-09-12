import 'dart:io';
import 'dart:typed_data';

import 'package:anx_reader/service/dictionary/stardict.dart';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// A dictionary installed in the library: its folder and what it reports.
class InstalledDictionary {
  const InstalledDictionary({
    required this.folder,
    required this.name,
    required this.wordCount,
  });

  final Directory folder;
  final String name;
  final int wordCount;
}

/// StarDict dictionaries kept in one folder per dictionary under [root], looked
/// up offline.
class DictionaryLibrary {
  DictionaryLibrary(this.root);

  final Directory root;
  final _open = <String, StarDictionary>{};

  Iterable<File> _ifoFiles(Directory folder) => folder
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.toLowerCase().endsWith('.ifo'));

  Future<List<InstalledDictionary>> installed() async {
    if (!root.existsSync()) return const [];
    final result = <InstalledDictionary>[];
    final folders = root.listSync().whereType<Directory>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final folder in folders) {
      for (final ifo in _ifoFiles(folder)) {
        final info = StarDictInfo.parse(await ifo.readAsString());
        if (info == null) continue;
        result.add(InstalledDictionary(
          folder: folder,
          name: info.name.isEmpty ? p.basename(folder.path) : info.name,
          wordCount: info.wordCount,
        ));
      }
    }
    return result;
  }

  Future<List<StarDictionary>> _dictionaries() async {
    if (!root.existsSync()) return const [];
    final dictionaries = <StarDictionary>[];
    final folders = root.listSync().whereType<Directory>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final folder in folders) {
      for (final ifo in _ifoFiles(folder)) {
        var opened = _open[ifo.path];
        if (opened == null) {
          try {
            opened = await StarDictionary.open(ifo);
          } catch (_) {
            opened = null;
          }
          // A dictionary that cannot be read is skipped, so one bad import
          // does not switch off the others.
          if (opened == null) continue;
          _open[ifo.path] = opened;
        }
        dictionaries.add(opened);
      }
    }
    return dictionaries;
  }

  /// Entries for [text] from every dictionary; an English word with no entry of
  /// its own is tried again in its likely base forms.
  Future<List<DictionaryEntry>> lookup(String text) async {
    final term = text.trim().replaceAll(
        RegExp(r'^[\s"“”‘’\x27(（\[【《<.,;:!?，。；：！？]+|[\s"“”‘’\x27)）\]】》>.,;:!?，。；：！？]+$'),
        '');
    if (term.isEmpty) return const [];
    final dictionaries = await _dictionaries();
    Future<List<DictionaryEntry>> search(String word) async => [
          for (final dictionary in dictionaries)
            ...await dictionary.lookup(word),
        ];

    final direct = await search(term);
    if (direct.isNotEmpty) return direct;
    if (RegExp(r'^[A-Za-z][A-Za-z\x27-]*$').hasMatch(term)) {
      for (final form in englishBaseForms(term)) {
        final entries = await search(form);
        if (entries.isNotEmpty) return entries;
      }
    }
    return const [];
  }

  /// Installs the dictionaries found in [files]: archives (.zip, .tar, .tar.gz,
  /// .tgz, .tar.bz2, .tbz2) or the loose files of a dictionary. Returns the
  /// names installed.
  Future<List<String>> import(List<File> files) async {
    root.createSync(recursive: true);
    final installed = <String>[];
    final loose = <String, Uint8List>{};
    for (final file in files) {
      final name = p.basename(file.path);
      final lower = name.toLowerCase();
      Archive? archive;
      if (lower.endsWith('.zip')) {
        archive = ZipDecoder().decodeBytes(await file.readAsBytes());
      } else if (lower.endsWith('.tar.bz2') || lower.endsWith('.tbz2')) {
        archive = TarDecoder()
            .decodeBytes(BZip2Decoder().decodeBytes(await file.readAsBytes()));
      } else if (lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) {
        archive = TarDecoder()
            .decodeBytes(GZipDecoder().decodeBytes(await file.readAsBytes()));
      } else if (lower.endsWith('.tar')) {
        archive = TarDecoder().decodeBytes(await file.readAsBytes());
      }
      if (archive != null) {
        final contents = <String, Uint8List>{
          for (final entry in archive.files)
            if (entry.isFile)
              entry.name: Uint8List.fromList(entry.content as List<int>),
        };
        installed.addAll(await _install(contents));
      } else {
        loose[name] = await file.readAsBytes();
      }
    }
    if (loose.isNotEmpty) installed.addAll(await _install(loose));
    _open.clear();
    return installed;
  }

  Future<List<String>> _install(Map<String, Uint8List> contents) async {
    final names = <String>[];
    for (final entry in contents.entries) {
      if (!entry.key.toLowerCase().endsWith('.ifo')) continue;
      final info = StarDictInfo.parse(String.fromCharCodes(entry.value));
      if (info == null) continue;
      final base = entry.key.substring(0, entry.key.length - 4);
      final baseName = p.basename(base);
      final folderName = _safeName(info.name.isEmpty ? baseName : info.name);
      final folder = Directory(p.join(root.path, folderName))
        ..createSync(recursive: true);
      for (final part in contents.entries) {
        if (!part.key.startsWith(base) ||
            p.dirname(part.key) != p.dirname(entry.key)) {
          continue;
        }
        final suffix = part.key.substring(base.length);
        if (!RegExp(r'^\.(ifo|idx|idx\.gz|dict|dict\.dz|syn)$', caseSensitive: false)
            .hasMatch(suffix)) {
          continue;
        }
        await File(p.join(folder.path, '$baseName${suffix.toLowerCase()}'))
            .writeAsBytes(part.value);
      }
      names.add(info.name.isEmpty ? baseName : info.name);
    }
    return names;
  }

  Future<void> remove(InstalledDictionary dictionary) async {
    for (final key in _open.keys.toList()) {
      if (p.isWithin(dictionary.folder.path, key)) {
        await _open.remove(key)?.close();
      }
    }
    if (dictionary.folder.existsSync()) {
      await dictionary.folder.delete(recursive: true);
    }
  }

  static String _safeName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_').trim();
    return cleaned.isEmpty ? 'dictionary' : cleaned;
  }
}
