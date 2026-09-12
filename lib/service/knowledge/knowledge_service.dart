import 'package:anx_reader/service/knowledge/knowledge_library.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';

KnowledgeLibrary? _library;

/// The app's offline encyclopedia, under the documents folder. Created on first
/// use, once the documents path is known.
KnowledgeLibrary get knowledgeLibrary =>
    _library ??= KnowledgeLibrary(getKnowledgeDir());

/// Whether any pack is on this device, checked without opening one, so a
/// prompt can mention the encyclopedia only when there is something to look up.
bool hasKnowledgePacks() {
  final dir = getKnowledgeDir();
  if (!dir.existsSync()) return false;
  return dir.listSync().any((entry) => entry.path.toLowerCase().endsWith('.zim'));
}
