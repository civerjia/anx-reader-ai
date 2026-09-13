import 'dart:io';

import 'package:anx_reader/utils/log/common.dart';
import 'package:flutter/services.dart';

/// A pronunciation attached to part of a probe sentence.
class ProbeMark {
  const ProbeMark(this.target, this.notation, {this.occurrence = 0, this.start});

  /// The text the pronunciation applies to.
  final String target;
  final String notation;

  /// Which occurrence of [target] in the sentence, from 0.
  final int occurrence;

  /// Where [target] starts, when known; overrides [occurrence].
  final int? start;
}

class ProbeCase {
  const ProbeCase(this.id, this.text, this.expect, {this.marks = const []});

  final String id;
  final String text;

  /// How a careful human reader would say it.
  final String expect;
  final List<ProbeMark> marks;
}

class ProbeGroup {
  const ProbeGroup(this.title, this.note, this.cases);

  final String title;
  final String note;
  final List<ProbeCase> cases;
}

/// Speaks probe sentences with the iOS system voice through
/// AVSpeechSynthesizer directly, so pronunciation attributes can be tried
/// without changing the reader's own narration.
class SpeechProbe {
  static const _channel = MethodChannel('anx_reader/speech_probe');

  static bool get isAvailable => Platform.isIOS;

  static Future<Map<String, dynamic>?> speak(
    ProbeCase probe, {
    String? voice,
    double? rate,
  }) async {
    if (!isAvailable) return null;
    final marks = <Map<String, dynamic>>[];
    for (final mark in probe.marks) {
      var start = mark.start ?? -1;
      for (var i = 0; mark.start == null && i <= mark.occurrence; i++) {
        start = probe.text.indexOf(mark.target, start + 1);
        if (start < 0) break;
      }
      if (start < 0) {
        AnxLog.info('SpeechProbe: ${probe.id}: "${mark.target}" not found');
        continue;
      }
      marks.add({
        // Dart string indices are UTF-16 units, as NSString ranges are.
        'start': start,
        'length': mark.target.length,
        'notation': mark.notation,
      });
    }
    try {
      final used = await _channel.invokeMapMethod<String, dynamic>('speak', {
        'text': probe.text,
        'marks': marks,
        'voice': voice,
        'rate': rate,
      });
      return used;
    } on PlatformException catch (e) {
      AnxLog.info('SpeechProbe: speak failed: $e');
    } on MissingPluginException catch (e) {
      AnxLog.info('SpeechProbe: channel not registered: $e');
    }
    return null;
  }

  static Future<void> stop() async {
    if (!isAvailable) return;
    try {
      await _channel.invokeMethod('stop');
    } on PlatformException {
      // Nothing playing.
    } on MissingPluginException {
      // Not on this platform build.
    }
  }
}
