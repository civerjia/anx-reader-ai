import 'dart:ui';

import 'package:anx_reader/utils/log/common.dart';
import 'package:flutter/material.dart';

class AnxError {
  /// Set while an error is being reported, so a failure inside the reporting
  /// path cannot come back around and report itself forever.
  static bool _reporting = false;

  static void _report(String message, StackTrace? stack) {
    if (_reporting) return;
    _reporting = true;
    try {
      AnxLog.severe(message, stack);
    } catch (_) {
      // Nothing left to do: reporting the failure is what failed.
    } finally {
      _reporting = false;
    }
  }

  static Future<void> init() async {
    AnxLog.info('AnxError init');
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      _report(details.exceptionAsString(), details.stack);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      _report(error.toString(), stack);
      return false;
    };
  }
}
