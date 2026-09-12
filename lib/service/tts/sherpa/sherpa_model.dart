import 'dart:io';

import 'package:path/path.dart' as p;

/// Model families of sherpa-onnx offline TTS that Anx exposes.
enum SherpaModelType {
  kokoro('kokoro', 'Kokoro'),
  zipvoice('zipvoice', 'ZipVoice'),
  vits('vits', 'VITS / Piper'),
  matcha('matcha', 'Matcha'),
  kitten('kitten', 'Kitten');

  const SherpaModelType(this.id, this.label);

  final String id;
  final String label;

  /// Zero shot cloning families need a reference wave and its transcript.
  bool get needsReferenceAudio => this == SherpaModelType.zipvoice;

  /// Families that synthesize features and need a separate vocoder.
  bool get needsVocoder =>
      this == SherpaModelType.zipvoice || this == SherpaModelType.matcha;

  /// Families whose speaker is picked by a numeric speaker id.
  bool get hasSpeakerId =>
      this == SherpaModelType.kokoro ||
      this == SherpaModelType.vits ||
      this == SherpaModelType.kitten;

  static SherpaModelType fromId(String? id) {
    return SherpaModelType.values.firstWhere(
      (e) => e.id == id,
      orElse: () => SherpaModelType.kokoro,
    );
  }
}

/// Thrown when a model directory does not contain the files a family needs.
class SherpaModelException implements Exception {
  SherpaModelException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A fully resolved model layout.
///
/// Only plain values live here so the whole object can be sent to the
/// inference isolate over a [SendPort].
class SherpaModelSpec {
  const SherpaModelSpec({
    required this.type,
    required this.dir,
    this.model = '',
    this.voices = '',
    this.tokens = '',
    this.dataDir = '',
    this.dictDir = '',
    this.lexicon = '',
    this.ruleFsts = '',
    this.ruleFars = '',
    this.acousticModel = '',
    this.encoder = '',
    this.decoder = '',
    this.vocoder = '',
    this.lang = '',
    this.numThreads = 2,
    this.provider = 'cpu',
    this.referenceAudio = '',
    this.referenceText = '',
    this.numSteps = 4,
    this.debug = false,
  });

  final SherpaModelType type;
  final String dir;
  final String model;
  final String voices;
  final String tokens;
  final String dataDir;
  final String dictDir;
  final String lexicon;
  final String ruleFsts;
  final String ruleFars;
  final String acousticModel;
  final String encoder;
  final String decoder;
  final String vocoder;
  final String lang;
  final int numThreads;
  final String provider;
  final String referenceAudio;
  final String referenceText;
  final int numSteps;
  final bool debug;

  /// Identity of everything that requires rebuilding the native TTS object.
  /// Reference text and the step count are per request, so they are excluded;
  /// the reference wave is not, it is decoded once when the model loads.
  String get engineKey => [
        type.id,
        model,
        voices,
        tokens,
        dataDir,
        dictDir,
        lexicon,
        ruleFsts,
        ruleFars,
        acousticModel,
        encoder,
        decoder,
        vocoder,
        lang,
        referenceAudio,
        numThreads,
        provider,
      ].join('|');

  /// Identifies a voice for speed calibration: the model folder, and for a
  /// cloning model the reference clip, since that is what sets the pace.
  String paceKey(int speakerId) => [
        type.id,
        p.basename(dir),
        if (referenceAudio.isNotEmpty) p.basename(referenceAudio),
        speakerId,
      ].join(':');

  @override
  String toString() => 'SherpaModelSpec($engineKey)';
}

/// Locates model directories and the files inside them.
///
/// This class stays free of app and plugin imports so it can be unit tested:
/// the directories a relative path may live in are passed in as [roots].
class SherpaModelResolver {
  /// Directory name used for models that are stored inside the app sandbox.
  static const String modelsFolderName = 'tts_models';

  /// The transcript that goes with a reference clip.
  ///
  /// sherpa-onnx ships its sample clips with the text next to them, either as
  /// `<clip>.txt` or as a line in `prompt.txt` starting with the file name,
  /// so nobody has to retype what the clip says.
  static String transcriptFor(String wavPath) {
    final file = File(wavPath);
    if (!file.existsSync()) return '';
    final dir = file.parent;
    final base = p.basename(wavPath);
    final stem = p.basenameWithoutExtension(wavPath);

    for (final name in ['$base.txt', '$stem.txt', '$stem.lab']) {
      final paired = File(p.join(dir.path, name));
      if (paired.existsSync()) {
        final text = paired.readAsStringSync().trim();
        if (text.isNotEmpty) return text;
      }
    }

    for (final name in ['prompt.txt', 'transcript.txt', 'trans.txt']) {
      final list = File(p.join(dir.path, name));
      if (!list.existsSync()) continue;
      for (final line in list.readAsLinesSync()) {
        final trimmed = line.trim();
        if (!trimmed.startsWith(base) && !trimmed.startsWith(stem)) continue;
        final text = trimmed
            .substring(trimmed.startsWith(base) ? base.length : stem.length)
            .trim();
        if (text.isNotEmpty) return text;
      }
    }

    return '';
  }

  /// Model folders sitting in [roots], newest looking first.
  ///
  /// A folder counts as a model when it holds a tokens file or any ONNX
  /// file, which is true of every sherpa-onnx TTS release.
  static List<String> listInstalled(List<String> roots) {
    final found = <String, String>{};
    for (final root in roots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      for (final entry in dir.listSync().whereType<Directory>()) {
        final name = p.basename(entry.path);
        if (found.containsKey(name)) continue;
        final looksLikeModel = entry.listSync().whereType<File>().any((file) {
          final base = p.basename(file.path).toLowerCase();
          return base == 'tokens.txt' || base.endsWith('.onnx');
        });
        if (looksLikeModel) found[name] = entry.path;
      }
    }
    final names = found.keys.toList()..sort();
    return names;
  }

  /// Resolve a user supplied path to an existing directory.
  ///
  /// An empty setting is not an error when exactly one model is installed:
  /// that is almost certainly the one meant, and typing a folder name on a
  /// phone is a poor way to spend someone's evening.
  static Future<String> resolveDir(String input,
      {List<String> roots = const []}) async {
    final raw = input.trim();
    if (raw.isEmpty) {
      final installed = listInstalled(roots);
      if (installed.length == 1) {
        return p.join(
          roots.firstWhere(
            (root) => Directory(p.join(root, installed.first)).existsSync(),
          ),
          installed.first,
        );
      }
      if (installed.isEmpty) {
        throw SherpaModelException(
            'No sherpa-onnx model found. Unpack one into:\n'
            '${roots.isEmpty ? '(no model folder available)' : roots.first}');
      }
      throw SherpaModelException(
          'Several models are installed, pick one in the settings:\n'
          '${installed.join('\n')}');
    }

    final candidates = <String>[];
    if (p.isAbsolute(raw)) {
      candidates.add(raw);
    } else {
      for (final root in roots) {
        candidates.add(p.join(root, raw));
      }
    }

    for (final candidate in candidates) {
      if (Directory(candidate).existsSync()) return candidate;
    }

    throw SherpaModelException(
        'Model directory not found: $raw\nLooked in:\n${candidates.join('\n')}');
  }

  /// Resolve a user supplied path to an existing file.
  ///
  /// Relative paths are resolved against [relativeTo] first (usually the model
  /// directory), then against the shared model roots, so a vocoder that is
  /// downloaded separately can sit next to the models instead of inside one.
  static Future<String> resolveFile(String input,
      {String? relativeTo,
      List<String> roots = const [],
      String what = 'File'}) async {
    final raw = input.trim();
    if (raw.isEmpty) {
      throw SherpaModelException('$what is not configured');
    }

    final candidates = <String>[];
    if (p.isAbsolute(raw)) {
      candidates.add(raw);
    } else {
      if (relativeTo != null) candidates.add(p.join(relativeTo, raw));
      for (final root in roots) {
        candidates.add(p.join(root, raw));
      }
    }

    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }

    throw SherpaModelException(
        '$what not found: $raw\nLooked in:\n${candidates.join('\n')}');
  }

  /// Build the model layout for [dir], picking the files [type] needs.
  ///
  /// [searchRoots] are the directories a relative [dirInput] is looked up in.
  /// [preferInt8] decides which variant wins when a model ships both a float
  /// and a quantised file. [vocoderOverride] and [referenceAudio] may point
  /// outside the model directory.
  static Future<SherpaModelSpec> resolve({
    required String dirInput,
    required SherpaModelType type,
    List<String> searchRoots = const [],
    bool preferInt8 = true,
    int numThreads = 2,
    String provider = 'cpu',
    String vocoderOverride = '',
    String lexiconOverride = '',
    String referenceAudio = '',
    String referenceText = '',
    int numSteps = 4,
    String lang = '',
    bool debug = false,
  }) async {
    final dir = await resolveDir(dirInput, roots: searchRoots);
    final threads = numThreads < 1 ? 1 : numThreads;
    final entries = Directory(dir).listSync();
    final names = entries
        .whereType<File>()
        .map((f) => p.basename(f.path))
        .toList()
      ..sort();
    final dirNames = entries
        .whereType<Directory>()
        .map((d) => p.basename(d.path))
        .toSet();

    String abs(String name) => p.join(dir, name);

    String? pickOnnx(List<String> mustContain,
        {List<String> mustNotContain = const []}) {
      final matches = names.where((n) {
        final lower = n.toLowerCase();
        if (!lower.endsWith('.onnx')) return false;
        if (!mustContain.every(lower.contains)) return false;
        if (mustNotContain.any(lower.contains)) return false;
        return true;
      }).toList();
      if (matches.isEmpty) return null;
      matches.sort((a, b) {
        final aInt8 = a.toLowerCase().contains('int8');
        final bInt8 = b.toLowerCase().contains('int8');
        if (aInt8 == bInt8) return a.length.compareTo(b.length);
        if (preferInt8) return aInt8 ? -1 : 1;
        return aInt8 ? 1 : -1;
      });
      return abs(matches.first);
    }

    String requireFile(String name, String what) {
      if (!names.contains(name)) {
        throw SherpaModelException(
            '$what ($name) is missing from $dir\nFiles found: ${names.join(', ')}');
      }
      return abs(name);
    }

    String optionalDir(String name) =>
        dirNames.contains(name) ? p.join(dir, name) : '';

    // Text normalisation rules that ship with several Chinese models.
    // sherpa-onnx applies them in order, and numbers have to come last so
    // dates and phone numbers are matched first.
    String rules(String extension) {
      const order = ['date', 'phone', 'number'];
      final found = names.where((n) => n.endsWith(extension)).toList()
        ..sort((a, b) {
          int rank(String n) {
            final hit = order.indexWhere((k) => n.toLowerCase().contains(k));
            return hit < 0 ? order.length : hit;
          }

          final byRank = rank(a).compareTo(rank(b));
          return byRank != 0 ? byRank : a.compareTo(b);
        });
      return found.map(abs).join(',');
    }

    // sherpa-onnx accepts several lexicons joined by a comma, which is how
    // the bilingual Kokoro model handles Chinese plus English.
    String lexicons() {
      if (lexiconOverride.trim().isNotEmpty) {
        return lexiconOverride
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .map((e) => p.isAbsolute(e) ? e : p.join(dir, e))
            .join(',');
      }
      final found = names
          .where((n) =>
              n.toLowerCase().startsWith('lexicon') &&
              n.toLowerCase().endsWith('.txt'))
          .toList();

      // The bilingual Kokoro model ships a US and a GB English lexicon.
      // sherpa-onnx keeps the first pronunciation it reads and warns about
      // every duplicate, so load only one of them, as the upstream example
      // does. The lexicon setting overrides this.
      final hasUsEnglish = found.any((n) => n.toLowerCase().contains('-us-en'));
      return found
          .where((n) =>
              !hasUsEnglish || !n.toLowerCase().contains('-gb-en'))
          .map(abs)
          .join(',');
    }

    Future<String> vocoder(List<String> hints) async {
      if (vocoderOverride.trim().isNotEmpty) {
        return resolveFile(vocoderOverride,
            relativeTo: dir, roots: searchRoots, what: 'Vocoder');
      }
      for (final hint in hints) {
        final found = pickOnnx([hint]);
        if (found != null) return found;
      }
      throw SherpaModelException(
          'No vocoder found for ${type.label}. Put the vocoder (for example '
          'vocos_24khz.onnx) inside $dir, or set the vocoder path in settings.');
    }

    switch (type) {
      case SherpaModelType.kokoro:
        return SherpaModelSpec(
          type: type,
          dir: dir,
          model: pickOnnx(['model']) ??
              pickOnnx([], mustNotContain: ['voices']) ??
              (throw SherpaModelException(
                  'No Kokoro model.onnx found in $dir')),
          voices: requireFile('voices.bin', 'Kokoro voices'),
          tokens: requireFile('tokens.txt', 'tokens'),
          dataDir: optionalDir('espeak-ng-data'),
          dictDir: optionalDir('dict'),
          lexicon: lexicons(),
          ruleFsts: rules('.fst'),
          ruleFars: rules('.far'),
          lang: lang,
          numThreads: threads,
          provider: provider,
          debug: debug,
        );

      case SherpaModelType.kitten:
        return SherpaModelSpec(
          type: type,
          dir: dir,
          model: pickOnnx(['model']) ??
              (throw SherpaModelException('No Kitten model.onnx found in $dir')),
          voices: requireFile('voices.bin', 'Kitten voices'),
          tokens: requireFile('tokens.txt', 'tokens'),
          dataDir: optionalDir('espeak-ng-data'),
          ruleFsts: rules('.fst'),
          ruleFars: rules('.far'),
          numThreads: threads,
          provider: provider,
          debug: debug,
        );

      case SherpaModelType.zipvoice:
        final resolvedReference = referenceAudio.trim().isEmpty
            ? ''
            : await resolveFile(referenceAudio,
                relativeTo: dir, roots: searchRoots, what: 'Reference audio');
        final encoder = pickOnnx(['encoder']);
        final decoder = pickOnnx(['decoder'], mustNotContain: ['encoder']);
        if (encoder == null || decoder == null) {
          throw SherpaModelException(
              'ZipVoice needs an encoder and a decoder .onnx in $dir\n'
              'Files found: ${names.join(', ')}');
        }
        return SherpaModelSpec(
          type: type,
          dir: dir,
          tokens: requireFile('tokens.txt', 'tokens'),
          encoder: encoder,
          decoder: decoder,
          vocoder: await vocoder(['vocos', 'vocoder', 'hifigan']),
          dataDir: optionalDir('espeak-ng-data'),
          lexicon: lexicons(),
          ruleFsts: rules('.fst'),
          ruleFars: rules('.far'),
          referenceAudio: resolvedReference,
          referenceText: referenceText.trim().isNotEmpty
              ? referenceText
              : transcriptFor(resolvedReference),
          numSteps: numSteps < 1 ? 1 : numSteps,
          numThreads: threads,
          provider: provider,
          debug: debug,
        );

      case SherpaModelType.matcha:
        final acoustic = pickOnnx(['acoustic']) ??
            pickOnnx(['model-steps']) ??
            pickOnnx([], mustNotContain: ['vocos', 'hifigan', 'vocoder']);
        if (acoustic == null) {
          throw SherpaModelException(
              'No Matcha acoustic model found in $dir\n'
              'Files found: ${names.join(', ')}');
        }
        return SherpaModelSpec(
          type: type,
          dir: dir,
          acousticModel: acoustic,
          vocoder: await vocoder(['hifigan', 'vocos', 'vocoder']),
          tokens: requireFile('tokens.txt', 'tokens'),
          dataDir: optionalDir('espeak-ng-data'),
          dictDir: optionalDir('dict'),
          lexicon: lexicons(),
          ruleFsts: rules('.fst'),
          ruleFars: rules('.far'),
          numThreads: threads,
          provider: provider,
          debug: debug,
        );

      case SherpaModelType.vits:
        final model = pickOnnx([]) ??
            (throw SherpaModelException('No VITS .onnx model found in $dir'));
        return SherpaModelSpec(
          type: type,
          dir: dir,
          model: model,
          tokens: requireFile('tokens.txt', 'tokens'),
          dataDir: optionalDir('espeak-ng-data'),
          dictDir: optionalDir('dict'),
          lexicon: lexicons(),
          ruleFsts: rules('.fst'),
          ruleFars: rules('.far'),
          numThreads: threads,
          provider: provider,
          debug: debug,
        );
    }
  }
}
