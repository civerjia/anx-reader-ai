import 'package:anx_reader/service/dictionary/dictionary_library.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';

DictionaryLibrary? _library;

/// The app's dictionary library, under the documents folder. Created on first
/// use, once the documents path is known.
DictionaryLibrary get dictionaryLibrary =>
    _library ??= DictionaryLibrary(getDictionaryDir());
