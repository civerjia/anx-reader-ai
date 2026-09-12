import 'dart:typed_data';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/service/config/service_provider.dart';
import 'package:anx_reader/service/tts/models/tts_voice.dart';
import 'package:flutter/widgets.dart';

// Re-export ConfigItem for convenience
export 'package:anx_reader/service/config/config_item.dart';

// Forward declaration to avoid circular dependency
// The actual TtsService enum is defined in tts_service.dart
// ignore: unused_element
abstract class _TtsService {}

/// Base class for all TTS service providers.
///
/// Subclasses must implement:
/// - [service]: The TTS service enum value.
/// - [getLabel]: The display label.
/// - For online TTS services:
///   - [speak]: Generate speech audio from text.
///   - [getVoices]: Get available voices.
///   - [getConfigItems]: Configuration items.
///   - [getConfig] / [saveConfig]: Configuration management.
abstract class TtsServiceProvider extends ServiceProvider<dynamic> {
  String get serviceId => service.toString().split('.').last;

  /// The display label for this service.
  @override
  String getLabel(BuildContext context);

  /// Generate speech audio from text.
  /// Only required for online TTS services.
  /// System TTS doesn't use this method.
  Future<Uint8List> speak(
      String text, String? voice, double rate, double pitch) async {
    throw UnimplementedError('speak() not implemented for $service');
  }

  /// Rate the player should apply on top of the audio [speak] returned.
  ///
  /// A local model can only be pushed so fast before it slurs, so the rest
  /// of a high reading speed is done by the player.
  double get playbackRate => 1.0;

  /// Mime type of the audio [speak] returns.
  /// Online services answer with mp3; local inference returns wave.
  String get audioMimeType => 'audio/mp3';

  /// How long a single [speak] call may take before it is retried.
  int get fetchTimeoutSeconds => 10;

  /// How many [speak] calls the prefetcher may run at the same time.
  int get maxConcurrentFetches => 5;

  /// Warm up the service before the first sentence, e.g. load a local model.
  Future<void> prepare() async {}

  /// Release any resource held by the service (models, isolates, sockets).
  Future<void> release() async {}

  /// Get available voices for this TTS service.
  /// Returns empty list for system TTS (handled separately).
  Future<List<TtsVoice>> getVoices() async {
    return [];
  }

  /// Convert voice data from API response to TtsVoice model.
  /// Only needed for online TTS services.
  TtsVoice convertVoiceModel(dynamic voiceData) {
    throw UnimplementedError(
        'convertVoiceModel() not implemented for $service');
  }

  /// Get the currently selected voice for this service.
  String getSelectedVoice() {
    return Prefs().getTtsVoiceModel(serviceId);
  }

  /// Persist the selected voice for this service.
  void setSelectedVoice(String voice) {
    Prefs().setTtsVoiceModel(serviceId, voice);
  }

  /// Resolve the voice to use, optionally overriding the saved selection.
  String resolveVoice(String? voiceOverride) {
    if (voiceOverride != null && voiceOverride.isNotEmpty) {
      return voiceOverride;
    }
    final selected = getSelectedVoice();
    if (selected.isEmpty) {
      throw Exception('No voice selected for $service');
    }
    return selected;
  }
}
