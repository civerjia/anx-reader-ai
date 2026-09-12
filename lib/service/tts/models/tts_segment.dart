import 'dart:typed_data';

import 'package:anx_reader/service/tts/models/tts_sentence.dart';

class TtsSegment {
  TtsSegment({required this.sentence, this.advanceAfter = true});

  final TtsSentence sentence;

  /// Whether the reader moves on once this segment has played. A long
  /// sentence is synthesized in several pieces, and the reader must only
  /// advance after the last of them.
  final bool advanceAfter;
  Uint8List? audio;
  bool isSilent = false;

  /// Why there is no audio, when the backend failed rather than the
  /// sentence being empty. Silence from a failure must not be treated as a
  /// sentence that simply had nothing to say.
  String? error;
  int fetchVersion =
      0; // Version to track if audio was fetched with current settings

  bool get isReady => isSilent || (audio != null && audio!.isNotEmpty);
}
