import 'dart:io';

import 'package:anx_reader/utils/log/common.dart';
import 'package:flutter/services.dart';

/// The dictionaries enabled in iOS Settings, shown in Apple's look-up panel.
/// Apps cannot read their text, so they are offered as a panel beside the
/// app's own dictionaries rather than inline.
class SystemDictionary {
  static const _channel = MethodChannel('anx_reader/system_dictionary');

  static bool get isAvailable => Platform.isIOS;

  static Future<bool> hasDefinition(String term) async {
    if (!isAvailable || term.trim().isEmpty) return false;
    try {
      final has = await _channel
              .invokeMethod<bool>('hasDefinition', {'term': term}) ??
          false;
      AnxLog.info('SystemDictionary: definition for a ${term.runes.length}-character term: $has');
      return has;
    } on PlatformException catch (e) {
      AnxLog.info('SystemDictionary: hasDefinition failed: $e');
      return false;
    } on MissingPluginException catch (e) {
      AnxLog.info('SystemDictionary: channel not registered: $e');
      return false;
    }
  }

  static Future<void> show(String term) async {
    if (!isAvailable) return;
    try {
      await _channel.invokeMethod<bool>('show', {'term': term});
    } on PlatformException {
      // Nothing to show.
    } on MissingPluginException {
      // Not on this platform build.
    }
  }
}
