import 'package:anx_reader/service/tts/sherpa/sherpa_model.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Where a model folder named by a relative path may live.
class SherpaModelRoots {
  static List<String> _cache = const [];

  /// The platform documents directory comes first: on iOS and macOS it is the
  /// folder exposed to Finder and the Files app, which is the only convenient
  /// place for a user to drop a few hundred megabytes of ONNX files.
  static Future<List<String>> all() async {
    if (_cache.isNotEmpty) return _cache;

    final roots = <String>[];
    try {
      final docs = await getApplicationDocumentsDirectory();
      roots.add(p.join(docs.path, SherpaModelResolver.modelsFolderName));
      roots.add(docs.path);
    } catch (_) {
      // The documents directory is not available on every platform.
    }
    if (documentPath.isNotEmpty) {
      roots.add(p.join(documentPath, SherpaModelResolver.modelsFolderName));
      roots.add(documentPath);
    }

    // Only cache once the Anx document path is known, otherwise an early
    // call during startup would pin an incomplete list.
    if (documentPath.isNotEmpty) _cache = roots;
    return roots;
  }

  /// What the last scan found, for the places a settings page cannot wait
  /// for a future.
  static List<String> get cached => _cache;

  /// The default place to put models, shown in the settings hint.
  static Future<String> defaultDir() async {
    final roots = await all();
    return roots.isEmpty
        ? p.join(documentPath, SherpaModelResolver.modelsFolderName)
        : roots.first;
  }
}
