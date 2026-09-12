import 'dart:io';

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
      return await _channel.invokeMethod<bool>('hasDefinition', {'term': term}) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
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
