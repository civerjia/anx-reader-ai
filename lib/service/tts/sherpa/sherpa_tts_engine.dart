import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:anx_reader/service/tts/sherpa/sherpa_model.dart';
import 'package:anx_reader/service/tts/sherpa/sherpa_wav.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

/// Audio produced by a local sherpa-onnx model.
class SherpaAudio {
  const SherpaAudio({required this.samples, required this.sampleRate});

  final Float32List samples;
  final int sampleRate;

  /// Wave bytes, with a short silence at the end.
  ///
  /// Players can report a clip as finished a few dozen milliseconds early,
  /// which eats the last syllable of a sentence. Padding means what gets
  /// clipped is silence.
  Uint8List toWav({Duration tail = const Duration(milliseconds: 150)}) {
    final padding = (sampleRate * tail.inMilliseconds / 1000).round();
    if (padding <= 0) return encodeWav(samples, sampleRate);

    final padded = Float32List(samples.length + padding);
    padded.setAll(0, samples);
    return encodeWav(padded, sampleRate);
  }
}

// ── Messages exchanged with the inference isolate ────────────────────────

class _InitRequest {
  _InitRequest(this.spec);

  final SherpaModelSpec spec;
}

class _GenerateRequest {
  _GenerateRequest({
    required this.id,
    required this.text,
    required this.speed,
    required this.sid,
    required this.numSteps,
    required this.referenceText,
    required this.silenceScale,
  });

  final int id;
  final String text;
  final double speed;
  final int sid;
  final int numSteps;
  final String referenceText;
  final double silenceScale;
}

class _ShutdownRequest {
  const _ShutdownRequest();
}

class _Ready {
  _Ready(this.numSpeakers, this.sampleRate);

  final int numSpeakers;
  final int sampleRate;
}

class _GenerateDone {
  _GenerateDone(this.id, this.samples, this.sampleRate);

  final int id;
  final Float32List samples;
  final int sampleRate;
}

class _WorkerError {
  _WorkerError(this.message, {this.id});

  final String message;
  final int? id;
}

/// Runs sherpa-onnx offline TTS in a background isolate.
///
/// Inference is a blocking native call, so it must stay off the UI isolate.
/// The isolate handles one message at a time, which also serialises the
/// concurrent requests the TTS prefetcher makes.
class SherpaTtsEngine {
  SherpaTtsEngine._internal();

  static final SherpaTtsEngine _instance = SherpaTtsEngine._internal();

  factory SherpaTtsEngine() => _instance;

  Isolate? _isolate;
  SendPort? _sendPort;
  ReceivePort? _receivePort;

  /// Identifies the model currently loaded in the isolate.
  String? _loadedKey;
  Completer<void>? _loading;
  final Map<int, Completer<SherpaAudio>> _pending = {};
  int _nextRequestId = 0;

  int _numSpeakers = 0;
  int _sampleRate = 0;

  int get numSpeakers => _numSpeakers;

  int get sampleRate => _sampleRate;

  bool get isLoaded => _loadedKey != null;

  /// Load [spec] if a different model (or none) is currently loaded.
  Future<void> ensureReady(SherpaModelSpec spec) async {
    // Wait out a load that is already in flight; it may be loading exactly
    // the model we want. A failed load is not our error to report here, the
    // caller that started it gets it, so fall through and try again.
    while (true) {
      if (_isReady(spec)) return;
      final loading = _loading;
      if (loading == null) break;
      try {
        await loading.future;
      } catch (_) {
        // Retry on the next turn of the loop.
      }
    }

    // Claim the load before the first await so two callers cannot both
    // spawn an isolate.
    final completer = Completer<void>();
    _loading = completer;

    try {
      await shutdown();
      final receivePort = ReceivePort();
      _receivePort = receivePort;
      _isolate = await Isolate.spawn(_workerEntry, receivePort.sendPort,
          debugName: 'sherpa-onnx-tts');

      receivePort.listen((message) {
        if (message is SendPort) {
          _sendPort = message;
          message.send(_InitRequest(spec));
        } else if (message is _Ready) {
          _numSpeakers = message.numSpeakers;
          _sampleRate = message.sampleRate;
          _loadedKey = spec.engineKey;
          _finishLoading(completer);
        } else if (message is _GenerateDone) {
          final pending = _pending.remove(message.id);
          pending?.complete(SherpaAudio(
            samples: message.samples,
            sampleRate: message.sampleRate,
          ));
        } else if (message is _WorkerError) {
          final id = message.id;
          if (id != null) {
            _pending.remove(id)?.completeError(
                SherpaModelException('sherpa-onnx: ${message.message}'));
          } else {
            AnxLog.severe('SherpaTts worker error: ${message.message}');
            _finishLoading(completer,
                SherpaModelException('sherpa-onnx: ${message.message}'));
          }
        }
      });

      await completer.future;
      AnxLog.info(
          'SherpaTts loaded ${spec.type.label} from ${spec.dir} on '
          '${spec.provider} with ${spec.numThreads} threads '
          '(speakers: $_numSpeakers, sampleRate: $_sampleRate)');
    } catch (e) {
      if (identical(_loading, completer)) _loading = null;
      await shutdown();
      rethrow;
    } finally {
      if (identical(_loading, completer)) _loading = null;
    }
  }

  bool _isReady(SherpaModelSpec spec) =>
      _loadedKey == spec.engineKey && _sendPort != null;

  /// Release the load slot before waking anyone up, so a waiter that retries
  /// sees a free slot instead of the completer it just awaited.
  void _finishLoading(Completer<void> completer, [Object? error]) {
    if (identical(_loading, completer)) _loading = null;
    if (completer.isCompleted) return;
    if (error == null) {
      completer.complete();
    } else {
      completer.completeError(error);
    }
  }

  /// Synthesize [text]. [ensureReady] must have completed for [spec].
  Future<SherpaAudio> generate({
    required SherpaModelSpec spec,
    required String text,
    double speed = 1.0,
    int sid = 0,
  }) async {
    await ensureReady(spec);
    final sendPort = _sendPort;
    if (sendPort == null) {
      throw SherpaModelException('sherpa-onnx engine is not running');
    }

    final id = _nextRequestId++;
    final completer = Completer<SherpaAudio>();
    _pending[id] = completer;

    sendPort.send(_GenerateRequest(
      id: id,
      text: text,
      speed: speed,
      sid: sid,
      numSteps: spec.numSteps,
      referenceText: spec.referenceText,
      silenceScale: spec.silenceScale,
    ));

    return completer.future;
  }

  /// Free the native model and stop the isolate.
  Future<void> shutdown() async {
    final sendPort = _sendPort;
    final isolate = _isolate;

    // Ask the worker to free the model first: the ONNX session lives in
    // native memory, which killing the isolate would not release. The worker
    // closes its port afterwards and the isolate ends on its own. It may be
    // blocked inside a native call, so do not wait for it, and kill it later
    // if it never got around to the request.
    sendPort?.send(const _ShutdownRequest());
    if (isolate != null) {
      Future.delayed(const Duration(seconds: 5), () {
        isolate.kill(priority: Isolate.beforeNextEvent);
      });
    }
    _isolate = null;
    _receivePort?.close();
    _receivePort = null;
    _sendPort = null;
    _loadedKey = null;
    _numSpeakers = 0;
    _sampleRate = 0;

    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(
            SherpaModelException('sherpa-onnx engine was stopped'));
      }
    }
    _pending.clear();
  }

  // ── Isolate side ───────────────────────────────────────────────────────

  static void _workerEntry(SendPort mainPort) {
    final receivePort = ReceivePort();
    mainPort.send(receivePort.sendPort);

    sherpa_onnx.OfflineTts? tts;
    Float32List? referenceAudio;
    var referenceSampleRate = 0;

    receivePort.listen((message) {
      if (message is _InitRequest) {
        try {
          // sherpa-onnx has to be initialised in every isolate that uses it.
          sherpa_onnx.initBindings();
          final spec = message.spec;
          if (spec.referenceAudio.isNotEmpty) {
            final wav = decodeWav(File(spec.referenceAudio).readAsBytesSync());
            if (wav == null) {
              throw SherpaModelException(
                  'Unsupported reference audio (need 16 bit or 32 bit float '
                  'PCM wave): ${spec.referenceAudio}');
            }
            referenceAudio = wav.samples;
            referenceSampleRate = wav.sampleRate;
          }
          tts = sherpa_onnx.OfflineTts(_buildConfig(spec));
          mainPort.send(_Ready(tts!.numSpeakers, tts!.sampleRate));
        } catch (e) {
          mainPort.send(_WorkerError('$e'));
        }
      } else if (message is _GenerateRequest) {
        final engine = tts;
        if (engine == null) {
          mainPort.send(_WorkerError('engine not initialised', id: message.id));
          return;
        }
        try {
          final audio = engine.generateWithConfig(
            text: message.text,
            config: sherpa_onnx.OfflineTtsGenerationConfig(
              silenceScale: 1.0,
              speed: message.speed,
              sid: message.sid,
              referenceAudio: referenceAudio,
              referenceSampleRate: referenceSampleRate,
              referenceText: message.referenceText,
              numSteps: message.numSteps,
            ),
          );
          mainPort.send(_GenerateDone(
            message.id,
            normalizeLoudness(tightenPauses(
              Float32List.fromList(audio.samples),
              audio.sampleRate,
              scale: message.silenceScale,
            )),
            audio.sampleRate,
          ));
        } catch (e) {
          mainPort.send(_WorkerError('$e', id: message.id));
        }
      } else if (message is _ShutdownRequest) {
        tts?.free();
        tts = null;
        receivePort.close();
      }
    });
  }

  static sherpa_onnx.OfflineTtsConfig _buildConfig(SherpaModelSpec spec) {
    final model = sherpa_onnx.OfflineTtsModelConfig(
      vits: spec.type == SherpaModelType.vits
          ? sherpa_onnx.OfflineTtsVitsModelConfig(
              model: spec.model,
              tokens: spec.tokens,
              lexicon: spec.lexicon,
              dataDir: spec.dataDir,
              dictDir: spec.dictDir,
            )
          : const sherpa_onnx.OfflineTtsVitsModelConfig(),
      matcha: spec.type == SherpaModelType.matcha
          ? sherpa_onnx.OfflineTtsMatchaModelConfig(
              acousticModel: spec.acousticModel,
              vocoder: spec.vocoder,
              tokens: spec.tokens,
              lexicon: spec.lexicon,
              dataDir: spec.dataDir,
              dictDir: spec.dictDir,
            )
          : const sherpa_onnx.OfflineTtsMatchaModelConfig(),
      kokoro: spec.type == SherpaModelType.kokoro
          ? sherpa_onnx.OfflineTtsKokoroModelConfig(
              model: spec.model,
              voices: spec.voices,
              tokens: spec.tokens,
              dataDir: spec.dataDir,
              dictDir: spec.dictDir,
              lexicon: spec.lexicon,
              lang: spec.lang,
            )
          : const sherpa_onnx.OfflineTtsKokoroModelConfig(),
      kitten: spec.type == SherpaModelType.kitten
          ? sherpa_onnx.OfflineTtsKittenModelConfig(
              model: spec.model,
              voices: spec.voices,
              tokens: spec.tokens,
              dataDir: spec.dataDir,
            )
          : const sherpa_onnx.OfflineTtsKittenModelConfig(),
      zipvoice: spec.type == SherpaModelType.zipvoice
          ? sherpa_onnx.OfflineTtsZipVoiceModelConfig(
              tokens: spec.tokens,
              encoder: spec.encoder,
              decoder: spec.decoder,
              vocoder: spec.vocoder,
              dataDir: spec.dataDir,
              lexicon: spec.lexicon,
            )
          : const sherpa_onnx.OfflineTtsZipVoiceModelConfig(),
      numThreads: spec.numThreads,
      debug: spec.debug,
      provider: spec.provider,
    );

    return sherpa_onnx.OfflineTtsConfig(
      model: model,
      ruleFsts: spec.ruleFsts,
      ruleFars: spec.ruleFars,
      // Leave sherpa's own pause trimming off: it decides what silence is
      // by amplitude alone and clips word endings. tightenPauses does it.
      silenceScale: 1.0,
    );
  }
}
