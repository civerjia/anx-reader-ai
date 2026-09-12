import 'dart:async';
import 'package:anx_reader/utils/platform_utils.dart';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/page/reading_page.dart';
import 'package:anx_reader/service/tts/base_tts.dart';
import 'package:anx_reader/service/tts/tts_skip.dart';
import 'package:anx_reader/service/tts/models/tts_voice.dart';
import 'package:anx_reader/service/tts/tts_service.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';

class SystemTts extends BaseTts {
  static final SystemTts _instance = SystemTts._internal();

  factory SystemTts() {
    return _instance;
  }

  SystemTts._internal();

  final FlutterTts flutterTts = FlutterTts();

  String? _currentVoiceText;
  static String? _prevVoiceText;

  bool restarting = false;

  late Function getHereFunction;
  late Function getNextTextFunction;
  late Function getPrevTextFunction;

  @override
  final ValueNotifier<TtsStateEnum> ttsStateNotifier =
      ValueNotifier<TtsStateEnum>(TtsStateEnum.stopped);

  @override
  void updateTtsState(TtsStateEnum newState) {
    ttsStateNotifier.value = newState;
  }

  bool get isIOS => AnxPlatform.isIOS;
  bool get isAndroid => AnxPlatform.isAndroid;
  bool get isWindows => AnxPlatform.isWindows;
  bool get isWeb => kIsWeb;

  @override
  double get volume => Prefs().ttsVolume;

  @override
  set volume(double volume) {
    Prefs().ttsVolume = volume;
    restart();
  }

  @override
  double get pitch => Prefs().ttsPitch;

  @override
  set pitch(double pitch) {
    Prefs().ttsPitch = pitch;
    restart();
  }

  @override
  double get rate => Prefs().ttsRate;

  /// The rate slider is a multiplier of normal speech, but flutter_tts hands
  /// the platform its own scale: on Apple platforms 0.5 is the default rate
  /// and 1.0 is already double, while Android takes the multiplier as is.
  /// Without this the same slider read normally on a local model and
  /// absurdly fast on a system voice.
  double get _platformRate {
    final multiplier = rate <= 0 ? 1.0 : rate;
    if (isAndroid) return multiplier.clamp(0.1, 3.0);
    return (multiplier * 0.5).clamp(0.05, 1.0);
  }

  @override
  set rate(double rate) {
    Prefs().ttsRate = rate;
    restart();
  }

  @override
  bool get isPlaying => ttsStateNotifier.value == TtsStateEnum.playing;

  @override
  String? get currentVoiceText => _currentVoiceText;

  @override
  Future<void> init(Function getCurrentText, Function getNextText,
      Function getPrevText) async {
    getHereFunction = getCurrentText;
    getNextTextFunction = getNextText;
    getPrevTextFunction = getPrevText;

    await setAwaitOptions();

    if (isAndroid) {
      await getDefaultEngine();
      await getDefaultVoice();
    }

    flutterTts.setStartHandler(() async {
      updateTtsState(TtsStateEnum.playing);
      if (!isAndroid) {
        return;
      }
      _prevVoiceText = _currentVoiceText;
      _currentVoiceText = await epubPlayerKey.currentState!.ttsPrepare();

      if (_currentVoiceText?.isNotEmpty ?? false) {
        flutterTts.speak(_currentVoiceText!);
      }
    });

    flutterTts.setCompletionHandler(() async {
      if (!isAndroid) {
        return;
      }
      updateTtsState(TtsStateEnum.playing);
      if (_currentVoiceText?.isEmpty ?? true) {
        _currentVoiceText = await getNextText();
        await speak();
      } else {
        await getNextText();
      }
    });
  }

  Future<void> setAwaitOptions() async {
    await flutterTts.awaitSpeakCompletion(true);
    if (isAndroid) {
      await flutterTts.awaitSynthCompletion(true);
      await flutterTts.setQueueMode(1);
    }
  }

  Future<void> getDefaultEngine() async {
    var engine = await flutterTts.getDefaultEngine;
    if (engine != null) {}
  }

  Future<void> getDefaultVoice() async {
    var voice = await flutterTts.getDefaultVoice;
    if (voice != null) {}
  }

  /// Apply the voice by shortName
  Future<void> _applyVoice(String? voiceShortName) async {
    if (voiceShortName == null || voiceShortName.isEmpty) {
      return;
    }

    try {
      // Get all voices to find the matching one
      final voices = await flutterTts.getVoices;
      if (voices is List) {
        for (var voice in voices) {
          final map = Map<String, dynamic>.from(voice);
          if (map['name'] == voiceShortName) {
            // flutter_tts setVoice expects a Map with 'name' and 'locale'
            await flutterTts.setVoice({
              'name': map['name'],
              'locale': map['locale'],
            });
            return;
          }
        }
      }
    } catch (e) {
      // Fallback: try to set voice directly (some platforms support this)
      // Ignore errors if voice not found
    }
  }

  /// For testing a specific voice in settings (matching OnlineTts API)
  Future<void> speakWithVoice(String content, String voiceShortName) async {
    await stop();
    await flutterTts.setVolume(volume);
    await flutterTts.setSpeechRate(_platformRate);
    await flutterTts.setPitch(pitch);
    await _applyVoice(voiceShortName);
    await flutterTts.speak(content);
  }

  @override
  Future<void> speak({String? content}) async {
    await setAwaitOptions();
    if (content != null) {
      _currentVoiceText = content;
    }
    if (_currentVoiceText == null) {
      // getHereFunction() positions the JS narration cursor. Starting from the
      // page it returns nothing and the first sentence is the next one; a
      // resumed start returns the sentence it landed on, which is the one to
      // read — taking the next would skip it.
      final here = await getHereFunction();
      _currentVoiceText = here is String && here.isNotEmpty
          ? here
          : await getNextTextFunction();
    }

    // Guard: if still null or empty (e.g. WebView not ready), abort.
    if (_currentVoiceText == null || _currentVoiceText!.isEmpty) {
      return;
    }

    await flutterTts.setVolume(volume);
    await flutterTts.setSpeechRate(_platformRate);
    await flutterTts.setPitch(pitch);

    // Apply the saved voice model. Without one, keep whatever voice the
    // platform defaults to instead of throwing.
    final selectedVoice = SystemTtsProvider().getSelectedVoice();
    if (selectedVoice.isNotEmpty) {
      await _applyVoice(selectedVoice);
    }

    await flutterTts.speak(_currentVoiceText!);

    if (!isAndroid && ttsStateNotifier.value == TtsStateEnum.playing) {
      _currentVoiceText = await getNextTextFunction();
      speak();
    }
  }

  @override
  Future<dynamic> stop() async {
    updateTtsState(TtsStateEnum.stopped);
    final result = await flutterTts.stop();
    _currentVoiceText = null;
    return result;
  }

  @override
  Future<void> pause() async {
    final result = await flutterTts.stop();
    if (result == 1) {
      updateTtsState(TtsStateEnum.paused);
    }
  }

  @override
  Future<void> resume() async {
    if (isAndroid) {
      speak(content: _prevVoiceText);
      return;
    }
    speak(content: _currentVoiceText);
  }

  @override
  Future<void> prev() async {
    if (restarting) {
      return;
    }
    restarting = true;
    await stop();
    _currentVoiceText = await getPrevTextFunction();
    speak();
    restarting = false;
  }

  @override
  Future<void> next() async {
    if (restarting) {
      return;
    }
    restarting = true;
    await stop();
    _currentVoiceText = await getNextTextFunction();
    speak();
    restarting = false;
  }

  @override
  Future<void> skip(Duration by) async {
    if (restarting) {
      return;
    }
    restarting = true;
    await stop();
    final forward = !by.isNegative;
    final landed = await stepUntil(
      step: () async =>
          await (forward ? getNextTextFunction() : getPrevTextFunction())
              as String?,
      syllables: syllablesFor(by, rate),
    );
    if (landed != null) _currentVoiceText = landed;
    speak();
    restarting = false;
  }

  @override
  Future<void> restart() async {
    if (restarting) {
      return;
    }
    restarting = true;
    await stop();
    speak();
    restarting = false;
  }

  @override
  Future<List<TtsVoice>> getVoices() async {
    try {
      dynamic voices = await flutterTts.getVoices;
      if (voices is List) {
        return voices.map((e) {
          final map = Map<String, dynamic>.from(e);
          return TtsVoice(
              shortName: map['name'] ?? '',
              name: map['name'] ?? '',
              locale: map['locale']?.replaceAll('_', '-') ?? '',
              gender: map['gender']?.toString().toLowerCase() ?? '',
              rawData: map);
        }).toList();
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  @override
  Future<void> dispose() async {
    await flutterTts.stop();
  }
}
