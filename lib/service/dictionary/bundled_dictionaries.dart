import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// A dictionary shipped inside the app, under `assets/dictionaries/<id>/`.
class BundledDictionary {
  const BundledDictionary(this.id, this.version, this.files);

  final String id;

  /// Raise when the files change, so installed copies are replaced.
  final int version;
  final List<String> files;
}

/// English-Chinese, common words: see tool/dictionaries/build_ecdict.dart.
const bundledDictionaries = [
  BundledDictionary('ecdict', 1, [
    'ecdict.ifo',
    'ecdict.idx',
    'ecdict.dict.dz',
    'ecdict.syn',
    'LICENSE.txt',
  ]),
];

/// Copies each bundled dictionary into [root] once per version.
///
/// A marker file records the install, so a bundled dictionary the reader
/// removed stays removed until a new version of it ships.
Future<List<String>> installBundledDictionaries({
  required Directory root,
  required Future<ByteData> Function(String asset) load,
  List<BundledDictionary> dictionaries = bundledDictionaries,
}) async {
  root.createSync(recursive: true);
  final installed = <String>[];
  for (final dictionary in dictionaries) {
    final marker = File(
        p.join(root.path, '.bundled-${dictionary.id}-v${dictionary.version}'));
    if (marker.existsSync()) continue;
    final folder = Directory(p.join(root.path, dictionary.id))
      ..createSync(recursive: true);
    for (final name in dictionary.files) {
      final data = await load('assets/dictionaries/${dictionary.id}/$name');
      await File(p.join(folder.path, name)).writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    marker.writeAsStringSync(DateTime.now().toIso8601String());
    installed.add(dictionary.id);
  }
  return installed;
}
