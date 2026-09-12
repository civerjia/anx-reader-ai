import 'dart:io';

import 'package:anx_reader/utils/get_path/get_base_path.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// One GGUF file found on disk.
class LocalLlmModelFile {
  const LocalLlmModelFile({
    required this.name,
    required this.path,
    required this.bytes,
  });

  /// File name, which is what gets stored in the provider config.
  final String name;

  /// Where it lives right now.
  final String path;

  final int bytes;

  String get sizeLabel => '${(bytes / 1e9).toStringAsFixed(2)} GB';
}

/// Where the weights for a local model may live, and how a stored name maps
/// back to a file.
class LocalLlmModels {
  /// Sits next to the TTS models folder rather than inside it: these are
  /// gigabyte-scale files a user drops in by hand, and mixing them with the
  /// ONNX voices would make both harder to manage.
  static const folderName = 'llm_models';

  static List<String> _roots = const [];

  /// The platform documents directory comes first: on iOS and macOS it is the
  /// folder exposed to Finder and the Files app, which is the only convenient
  /// place to put a couple of gigabytes of weights.
  static Future<List<String>> roots() async {
    if (_roots.isNotEmpty) return _roots;

    final roots = <String>[];
    try {
      final docs = await getApplicationDocumentsDirectory();
      roots.add(p.join(docs.path, folderName));
      roots.add(docs.path);
    } catch (_) {
      // Not every platform has a documents directory.
    }
    if (documentPath.isNotEmpty) {
      roots.add(p.join(documentPath, folderName));
      roots.add(documentPath);
    }

    // Only cache once the Anx document path is known, so an early call during
    // startup cannot pin an incomplete list.
    if (documentPath.isNotEmpty) _roots = roots;
    return roots;
  }

  /// What the last scan found, for the places a build method cannot await.
  static List<String> get cachedRoots => _roots;

  static Future<String> defaultDir() async {
    final all = await roots();
    return all.isEmpty ? p.join(documentPath, folderName) : all.first;
  }

  /// Every `.gguf` under the roots, smallest first, deduplicated by name.
  ///
  /// Smallest first because that is also fastest, and on a phone the small
  /// model is the one that actually runs well.
  static Future<List<LocalLlmModelFile>> listInstalled() async {
    final found = <String, LocalLlmModelFile>{};
    for (final root in await roots()) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        if (!entity.path.toLowerCase().endsWith('.gguf')) continue;
        final name = p.basename(entity.path);
        // A multimodal projector is not a model on its own.
        if (name.startsWith('mmproj-')) continue;
        found.putIfAbsent(
          name,
          () => LocalLlmModelFile(
            name: name,
            path: entity.path,
            bytes: entity.lengthSync(),
          ),
        );
      }
    }
    final models = found.values.toList()
      ..sort((a, b) => a.bytes.compareTo(b.bytes));
    return models;
  }

  /// Turns the stored model name into a path that exists right now.
  ///
  /// Only the file name is ever stored. An iOS app's data container UUID
  /// changes between installs, so an absolute path saved before a reinstall
  /// points at nothing — the same trap the TTS models hit.
  static Future<String?> resolve(String name) async {
    if (name.isEmpty) return null;

    // An absolute path that exists is taken as given: it is what a desktop user
    // pasting a path means, and it lets a test point straight at a file.
    if (p.isAbsolute(name) && File(name).existsSync()) return name;

    final wanted = p.basename(name);
    for (final root in await roots()) {
      final candidate = File(p.join(root, wanted));
      if (candidate.existsSync()) return candidate.path;
    }

    // A name that no longer resolves is worth falling back for when there is
    // exactly one model installed: that is almost certainly the one meant.
    final installed = await listInstalled();
    if (installed.length == 1) return installed.first.path;
    return null;
  }
}
