import 'dart:async';
import 'package:anx_reader/service/tts/models/tts_voice.dart';
import 'package:flutter/material.dart';

enum TtsStateEnum { playing, stopped, paused, continued }

abstract class BaseTts {
  double get volume;
  set volume(double volume);

  double get pitch;
  set pitch(double pitch);

  double get rate;
  set rate(double rate);

  ValueNotifier<TtsStateEnum> get ttsStateNotifier;
  void updateTtsState(TtsStateEnum newState);

  Future<void> init(
      Function getCurrentText, Function getNextText, Function getPrevText);

  Future<void> speak({String? content});

  Future<dynamic> stop();

  Future<void> pause();

  Future<void> resume();

  Future<void> prev();

  Future<void> next();

  /// Moves narration by about [by] — forward when positive, back when
  /// negative — and carries on reading from there.
  Future<void> skip(Duration by);

  Future<void> restart();

  Future<void> dispose();

  bool get isPlaying;

  String? get currentVoiceText;

  Future<List<TtsVoice>> getVoices();
}
