import 'dart:io';
import 'dart:typed_data';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/service/tts/models/tts_voice.dart';
import 'package:anx_reader/service/tts/sherpa/sherpa_model.dart';
import 'package:anx_reader/service/tts/sherpa/sherpa_model_roots.dart';
import 'package:anx_reader/service/tts/sherpa/sherpa_onnx_meta.dart';
import 'package:anx_reader/service/tts/sherpa/sherpa_pace.dart';
import 'package:anx_reader/service/tts/sherpa/sherpa_voice_catalog.dart';
import 'package:anx_reader/service/tts/sherpa/sherpa_tts_engine.dart';
import 'package:anx_reader/service/tts/tts_service.dart';
import 'package:anx_reader/service/tts/tts_service_provider.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

/// Local, offline TTS powered by sherpa-onnx.
///
/// Models (Kokoro, ZipVoice, VITS/Piper, Matcha, Kitten) are provided by the
/// user as a folder of ONNX files; nothing leaves the device.
class SherpaTtsProvider extends TtsServiceProvider {
  factory SherpaTtsProvider() => _instance;

  SherpaTtsProvider._internal();

  static final SherpaTtsProvider _instance = SherpaTtsProvider._internal();

  static const String _defaultModelType = 'kokoro';
  static const int _defaultNumSteps = 4;
  static const int _defaultNumThreads = 2;

  final SherpaTtsEngine _engine = SherpaTtsEngine();

  @override
  TtsService get service => TtsService.sherpa;

  @override
  String getLabel(BuildContext context) =>
      L10n.of(context).settingsNarrateSherpaTts;

  /// Local inference returns wave, not mp3.
  @override
  String get audioMimeType => 'audio/wav';

  /// A sentence on a phone CPU can take a few seconds, and the very first one
  /// also pays for loading the model.
  @override
  int get fetchTimeoutSeconds => 180;

  /// Inference runs in a single isolate, so queueing more requests in
  /// parallel only adds latency to the sentence that is needed next.
  @override
  int get maxConcurrentFetches => 1;

  @override
  List<ConfigItem> getConfigItems(BuildContext context) {
    final type = SherpaModelType.fromId(getConfig()['modelType']?.toString());
    return [
      ConfigItem(
        key: 'tip',
        label: L10n.of(context).translateTip,
        type: ConfigItemType.tip,
        defaultValue: L10n.of(context).settingsNarrateSherpaHelpText,
        link: 'https://k2-fsa.github.io/sherpa/onnx/tts/index.html',
      ),
      ConfigItem(
        key: 'modelType',
        label: L10n.of(context).settingsNarrateSherpaModelType,
        type: ConfigItemType.select,
        defaultValue: _defaultModelType,
        options: [
          for (final family in SherpaModelType.values)
            {'value': family.id, 'label': family.label},
        ],
      ),
      _modelDirItem(context),
      // A vocoder is only a separate file for the families that need one,
      // and only worth asking about when it is not next to the model.
      if (type.needsVocoder)
        ConfigItem(
          key: 'vocoder',
          label: L10n.of(context).settingsNarrateSherpaVocoder,
          description: L10n.of(context).settingsNarrateSherpaVocoderDescription,
          type: ConfigItemType.file,
          defaultValue: '',
          allowedExtensions: const ['onnx'],
        ),
      if (type.needsReferenceAudio) ...[
        _referenceAudioItem(context),
        // The clips that ship with a model carry their transcript, so only
        // ask for one when it cannot be found.
        if (_transcriptOf(getConfig()['referenceAudio']?.toString() ?? '')
            .isEmpty)
          ConfigItem(
            key: 'referenceText',
            label: L10n.of(context).settingsNarrateSherpaReferenceText,
            description:
                L10n.of(context).settingsNarrateSherpaReferenceTextDescription,
            type: ConfigItemType.text,
            defaultValue: '',
          ),
        ConfigItem(
          key: 'numSteps',
          label: L10n.of(context).settingsNarrateSherpaNumSteps,
          description:
              L10n.of(context).settingsNarrateSherpaNumStepsDescription,
          type: ConfigItemType.number,
          defaultValue: _defaultNumSteps,
        ),
      ],
      ConfigItem(
        key: 'numThreads',
        label: L10n.of(context).settingsNarrateSherpaNumThreads,
        description:
            L10n.of(context).settingsNarrateSherpaNumThreadsDescription,
        type: ConfigItemType.number,
        defaultValue: _defaultNumThreads,
      ),
      ConfigItem(
        key: 'autoSpeed',
        label: L10n.of(context).settingsNarrateSherpaAutoSpeed,
        description: L10n.of(context).settingsNarrateSherpaAutoSpeedDescription,
        type: ConfigItemType.toggle,
        defaultValue: true,
      ),
      ConfigItem(
        key: 'speedFactor',
        label: L10n.of(context).settingsNarrateSherpaSpeedFactor,
        description:
            L10n.of(context).settingsNarrateSherpaSpeedFactorDescription,
        type: ConfigItemType.range,
        defaultValue: 1.0,
        min: 0.5,
        max: 2.0,
        step: 0.05,
      ),
      ConfigItem(
        key: 'preferInt8',
        label: L10n.of(context).settingsNarrateSherpaPreferInt8,
        description:
            L10n.of(context).settingsNarrateSherpaPreferInt8Description,
        type: ConfigItemType.toggle,
        defaultValue: true,
      ),
      ConfigItem(
        key: 'lexicon',
        label: L10n.of(context).settingsNarrateSherpaLexicon,
        description: L10n.of(context).settingsNarrateSherpaLexiconDescription,
        type: ConfigItemType.text,
        defaultValue: '',
      ),
    ];
  }

  /// Reference clips found next to the model, so a cloning voice can be
  /// picked from a list instead of typed as a path.
  ConfigItem _referenceAudioItem(BuildContext context) {
    final clips = _referenceClips();
    if (clips.isEmpty) {
      return ConfigItem(
        key: 'referenceAudio',
        label: L10n.of(context).settingsNarrateSherpaReferenceAudio,
        description:
            L10n.of(context).settingsNarrateSherpaReferenceAudioDescription,
        type: ConfigItemType.file,
        defaultValue: '',
        allowedExtensions: const ['wav'],
      );
    }

    final current = getConfig()['referenceAudio']?.toString() ?? '';
    return ConfigItem(
      key: 'referenceAudio',
      label: L10n.of(context).settingsNarrateSherpaReferenceAudio,
      description:
          L10n.of(context).settingsNarrateSherpaReferenceAudioDescription,
      type: ConfigItemType.select,
      defaultValue: clips.contains(current) ? current : clips.first,
      options: [
        for (final clip in clips) {'value': clip, 'label': p.basename(clip)},
      ],
    );
  }

  /// Wave files in the model folder, `test_wavs` included.
  List<String> _referenceClips() {
    final dir = _modelDirSync();
    if (dir == null) return const [];
    final clips = <String>[];
    for (final candidate in [dir, Directory(p.join(dir.path, 'test_wavs'))]) {
      if (!candidate.existsSync()) continue;
      clips.addAll(candidate
          .listSync()
          .whereType<File>()
          .map((file) => file.path)
          .where((path) => path.toLowerCase().endsWith('.wav')));
    }
    clips.sort();
    return clips;
  }

  String _transcriptOf(String clip) {
    if (clip.trim().isEmpty) return '';
    final resolved = p.isAbsolute(clip) ? clip : _resolveClip(clip);
    if (resolved == null) return '';
    return SherpaModelResolver.transcriptFor(resolved);
  }

  String? _resolveClip(String clip) {
    final dir = _modelDirSync();
    if (dir == null) return null;
    for (final candidate in [
      p.join(dir.path, clip),
      p.join(dir.path, 'test_wavs', clip),
    ]) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// The configured model folder, resolved without waiting on a future, for
  /// the settings page. Returns null while the roots are still unknown.
  Directory? _modelDirSync() {
    final configured = getConfig()['modelDir']?.toString().trim() ?? '';
    if (p.isAbsolute(configured)) {
      final dir = Directory(configured);
      return dir.existsSync() ? dir : null;
    }
    final roots = SherpaModelRoots.cached;
    final names = configured.isNotEmpty
        ? [configured]
        : SherpaModelResolver.listInstalled(roots);
    if (names.length != 1) return null;
    for (final root in roots) {
      final dir = Directory(p.join(root, names.first));
      if (dir.existsSync()) return dir;
    }
    return null;
  }

  /// Model folders found in the standard locations.
  static List<String> _installed = const [];
  static bool _scanning = false;

  /// Offer the installed models as a list instead of asking for a path:
  /// typing a folder name on a phone is a poor way to start an audiobook.
  /// Falls back to a path field for a model kept somewhere else.
  ConfigItem _modelDirItem(BuildContext context) {
    _refreshInstalled();
    final current = getConfig()['modelDir']?.toString() ?? '';
    final canPickFromList =
        _installed.isNotEmpty && (current.isEmpty || _installed.contains(current));

    if (!canPickFromList) {
      return ConfigItem(
        key: 'modelDir',
        label: L10n.of(context).settingsNarrateSherpaModelDir,
        description: L10n.of(context).settingsNarrateSherpaModelDirDescription,
        type: ConfigItemType.directory,
        defaultValue: '',
      );
    }

    return ConfigItem(
      key: 'modelDir',
      label: L10n.of(context).settingsNarrateSherpaModelDir,
      description: L10n.of(context).settingsNarrateSherpaModelDirDescription,
      type: ConfigItemType.select,
      defaultValue: current.isEmpty ? _installed.first : current,
      options: [
        for (final name in _installed) {'value': name, 'label': name},
      ],
    );
  }

  /// Rescan in the background; the settings page rebuilds often enough to
  /// pick the result up.
  void _refreshInstalled() {
    if (_scanning) return;
    _scanning = true;
    Future(() async {
      try {
        _installed =
            SherpaModelResolver.listInstalled(await SherpaModelRoots.all());
      } catch (e) {
        AnxLog.warning('Failed to look for installed sherpa models: $e');
      } finally {
        _scanning = false;
      }
    });
  }

  @override
  Map<String, dynamic> getConfig() {
    final config = Prefs().getOnlineTtsConfig(serviceId);
    return {
      'modelType': config['modelType'] ?? _defaultModelType,
      'modelDir': config['modelDir'] ?? '',
      'vocoder': config['vocoder'] ?? '',
      'referenceAudio': config['referenceAudio'] ?? '',
      'referenceText': config['referenceText'] ?? '',
      'numSteps': config['numSteps'] ?? _defaultNumSteps,
      'numThreads': config['numThreads'] ?? _defaultNumThreads,
      'autoSpeed': config['autoSpeed'] ?? true,
      'speedFactor': config['speedFactor'] ?? 1.0,
      'preferInt8': config['preferInt8'] ?? true,
      'lexicon': config['lexicon'] ?? '',
    };
  }

  @override
  void saveConfig(Map<String, dynamic> config) {
    Prefs().saveOnlineTtsConfig(serviceId, config);
    // The next request rebuilds the engine if the model actually changed.
    _cachedSpec = null;
  }

  SherpaModelSpec? _cachedSpec;
  String? _cachedConfigKey;

  int _asInt(dynamic value, int fallback) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  bool _asBool(dynamic value, bool fallback) {
    if (value is bool) return value;
    final text = value?.toString().toLowerCase();
    if (text == 'true') return true;
    if (text == 'false') return false;
    return fallback;
  }

  /// Resolve the configured model directory into concrete file paths.
  Future<SherpaModelSpec> resolveSpec() async {
    final config = getConfig();
    final key = config.toString();
    final cached = _cachedSpec;
    if (cached != null && _cachedConfigKey == key) return cached;

    final spec = await SherpaModelResolver.resolve(
      dirInput: config['modelDir']?.toString() ?? '',
      searchRoots: await SherpaModelRoots.all(),
      type: SherpaModelType.fromId(config['modelType']?.toString()),
      preferInt8: _asBool(config['preferInt8'], true),
      numThreads: _asInt(config['numThreads'], _defaultNumThreads),
      vocoderOverride: config['vocoder']?.toString() ?? '',
      lexiconOverride: config['lexicon']?.toString() ?? '',
      referenceAudio: config['referenceAudio']?.toString() ?? '',
      referenceText: config['referenceText']?.toString() ?? '',
      numSteps: _asInt(config['numSteps'], _defaultNumSteps),
    );

    if (spec.type.needsReferenceAudio && spec.referenceAudio.isEmpty) {
      throw SherpaModelException(
          '${spec.type.label} clones a voice, so it needs a reference wave '
          'file and the text spoken in it.');
    }

    _cachedSpec = spec;
    _cachedConfigKey = key;
    return spec;
  }

  /// Load the model ahead of the first sentence.
  @override
  Future<void> prepare() async {
    await _engine.ensureReady(await resolveSpec());
  }

  /// Unload the model and stop the inference isolate.
  @override
  Future<void> release() async {
    await _engine.shutdown();
  }

  @override
  Future<Uint8List> speak(
      String text, String? voice, double rate, double pitch) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return Uint8List(0);

    final spec = await resolveSpec();
    final sid = _speakerId(voice);
    final speed = SherpaPace.speed(rate: rate, factor: _paceFactor(spec, sid));

    final watch = Stopwatch()..start();
    final audio = await _engine.generate(
      spec: spec,
      text: trimmed,
      speed: speed,
      sid: sid,
    );
    watch.stop();

    if (audio.samples.isEmpty) return Uint8List(0);
    _measurePace(spec, sid, trimmed, audio, speed, watch.elapsedMilliseconds);
    return audio.toWav();
  }

  // ============ Speed calibration ============

  final Set<String> _reported = {};
  final Map<String, double> _paceSyllables = {};
  final Map<String, double> _paceSeconds = {};

  /// Speed calibration for the voice about to speak: measured when automatic
  /// calibration is on, otherwise the baseline from the settings.
  double _paceFactor(SherpaModelSpec spec, int sid) {
    final config = getConfig();
    if (!_asBool(config['autoSpeed'], true)) {
      final manual = _asDouble(config['speedFactor'], 1.0);
      return manual.clamp(SherpaPace.minFactor, SherpaPace.maxFactor);
    }
    final learned = Prefs().getTtsPaceFactor(spec.paceKey(sid));
    return learned > 0 ? learned : 1.0;
  }

  /// Learn how fast this voice actually talks, from the audio it produced.
  ///
  /// Every model has its own natural pace, so the same rate setting sounds
  /// slow on one and rushed on another. A sentence or two is enough, after
  /// which the factor is stored and reused.
  void _measurePace(SherpaModelSpec spec, int sid, String text,
      SherpaAudio audio, double speed, int elapsedMs) {
    final key = spec.paceKey(sid);
    if (audio.sampleRate <= 0) return;
    final seconds = audio.samples.length / audio.sampleRate;
    if (seconds <= 0) return;

    // One line per model, so the real time factor on this device is in the
    // log without a sentence by sentence flood.
    if (_reported.add(key)) {
      AnxLog.info('SherpaTts $key: ${elapsedMs}ms for '
          '${seconds.toStringAsFixed(1)}s of audio '
          '(RTF ${(elapsedMs / 1000 / seconds).toStringAsFixed(2)})');
    }

    final config = getConfig();
    if (!_asBool(config['autoSpeed'], true)) return;
    if (Prefs().getTtsPaceFactor(key) > 0) return;

    _paceSyllables[key] =
        (_paceSyllables[key] ?? 0) + SherpaPace.syllables(text);
    // What the model would have produced at speed 1.0.
    _paceSeconds[key] = (_paceSeconds[key] ?? 0) + seconds * speed;

    final factor = SherpaPace.factorFrom(
      syllables: _paceSyllables[key]!,
      naturalSeconds: _paceSeconds[key]!,
    );
    if (factor == null) return;

    Prefs().setTtsPaceFactor(key, factor);
    _paceSyllables.remove(key);
    _paceSeconds.remove(key);
    AnxLog.info('SherpaTts calibrated $key to speed x'
        '${factor.toStringAsFixed(2)}');
  }

  double _asDouble(dynamic value, double fallback) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? fallback;
  }

  int _speakerId(String? voiceOverride) {
    final raw = (voiceOverride == null || voiceOverride.isEmpty)
        ? getSelectedVoice()
        : voiceOverride;
    return int.tryParse(raw.trim()) ?? 0;
  }

  @override
  Future<List<TtsVoice>> getVoices() async {
    final spec = await resolveSpec();
    await _engine.ensureReady(spec);

    if (!spec.type.hasSpeakerId) {
      final name = spec.referenceAudio.isEmpty
          ? spec.type.label
          : p.basenameWithoutExtension(spec.referenceAudio);
      return [
        TtsVoice(
          shortName: '0',
          name: name,
          locale: spec.type.label,
          description: spec.dir,
        ),
      ];
    }

    final names = _voiceNames(spec);
    final count = _engine.numSpeakers > 0 ? _engine.numSpeakers : 1;
    return [
      for (var sid = 0; sid < count; sid++)
        _voice(sid, sid < names.length ? names[sid] : '', spec),
    ];
  }

  TtsVoice _voice(int sid, String name, SherpaModelSpec spec) {
    if (name.isEmpty) {
      return TtsVoice(
        shortName: '$sid',
        name: 'Speaker $sid',
        locale: spec.type.label,
      );
    }
    final grade = SherpaVoiceCatalog.grade(name);
    return TtsVoice(
      shortName: '$sid',
      name: name,
      locale: _localeOf(name) ?? spec.type.label,
      gender: _genderOf(name),
      description: grade == null ? '#$sid' : '#$sid · grade $grade',
    );
  }

  /// Kokoro and Kitten name their voices `<language><gender>_<name>`, e.g.
  /// `zf_xiaoxiao` is a Chinese female voice and `am_adam` an American
  /// English male one. Decoding it lets the settings page group the 54
  /// voices by language instead of listing bare numbers.
  static const Map<String, String> _voiceLanguages = {
    'a': 'en-US',
    'b': 'en-GB',
    'e': 'es-ES',
    'f': 'fr-FR',
    'h': 'hi-IN',
    'i': 'it-IT',
    'j': 'ja-JP',
    'p': 'pt-BR',
    'z': 'zh-CN',
  };

  static final RegExp _voiceNamePattern = RegExp(r'^([a-z])([fm])_');

  String? _localeOf(String name) {
    final match = _voiceNamePattern.firstMatch(name);
    if (match == null) return null;
    return _voiceLanguages[match.group(1)];
  }

  String _genderOf(String name) {
    final match = _voiceNamePattern.firstMatch(name);
    if (match == null) return '';
    return match.group(2) == 'f' ? 'Female' : 'Male';
  }

  /// Speaker names, from a `voices.txt` next to the model if the user wrote
  /// one, otherwise from the model's own ONNX metadata.
  List<String> _voiceNames(SherpaModelSpec spec) {
    for (final name in ['voices.txt', 'speakers.txt']) {
      final file = File(p.join(spec.dir, name));
      if (!file.existsSync()) continue;
      try {
        return file
            .readAsLinesSync()
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty && !line.startsWith('#'))
            .toList();
      } catch (e) {
        AnxLog.warning('Failed to read $name: $e');
      }
    }

    final model = spec.model.isNotEmpty ? spec.model : spec.acousticModel;
    if (model.isEmpty) return const [];
    return SherpaOnnxMeta.speakerNames(model);
  }

  @override
  TtsVoice convertVoiceModel(dynamic voiceData) {
    if (voiceData is TtsVoice) return voiceData;
    if (voiceData is Map<String, dynamic>) return TtsVoice.fromMap(voiceData);
    return const TtsVoice(shortName: '0', name: 'Speaker 0', locale: '');
  }

  @override
  String getSelectedVoice() {
    final selected = Prefs().getTtsVoiceModel(serviceId);
    return selected.isEmpty ? '0' : selected;
  }
}
