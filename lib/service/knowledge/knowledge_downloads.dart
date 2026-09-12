import 'dart:async';

import 'package:anx_reader/service/knowledge/kiwix_catalog.dart';
import 'package:anx_reader/service/knowledge/knowledge_download.dart';
import 'package:anx_reader/service/knowledge/knowledge_service.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Where one pack's download stands.
class KnowledgeDownloadState {
  KnowledgeDownloadState(this.pack);

  final KiwixPack pack;
  int received = 0;
  int total = 0;
  bool running = false;
  String? error;

  double? get fraction => total > 0 ? received / total : null;
}

/// Downloads that keep going while the reader moves around the app, and the
/// state the settings page shows for them.
class KnowledgeDownloads extends ChangeNotifier {
  final _downloads = <String, KnowledgeDownload>{};
  final states = <String, KnowledgeDownloadState>{};
  DateTime _lastNotified = DateTime.fromMillisecondsSinceEpoch(0);

  KnowledgeDownload _download(KiwixPack pack) => _downloads[pack.fileName] ??=
      KnowledgeDownload(pack: pack, root: getKnowledgeDir());

  /// Bytes already on disk from an earlier, unfinished download of [pack].
  int partialBytes(KiwixPack pack) => _download(pack).downloadedBytes;

  Future<void> start(KiwixPack pack) async {
    final download = _download(pack);
    if (download.isRunning) return;
    final state = states[pack.fileName] ??= KnowledgeDownloadState(pack);
    state
      ..running = true
      ..error = null
      ..received = download.downloadedBytes;
    notifyListeners();
    try {
      await download.start(onProgress: (received, total) {
        state
          ..received = received
          ..total = total;
        final now = DateTime.now();
        if (now.difference(_lastNotified) > const Duration(milliseconds: 250)) {
          _lastNotified = now;
          notifyListeners();
        }
      });
      states.remove(pack.fileName);
      _downloads.remove(pack.fileName);
      await knowledgeLibrary.refresh();
    } catch (e) {
      state.running = false;
      if (!(e is DioException && CancelToken.isCancel(e))) {
        state.error = e is DioException ? (e.message ?? e.type.name) : e.toString();
        AnxLog.info('Knowledge download of ${pack.fileName} stopped: $e');
      }
    } finally {
      notifyListeners();
    }
  }

  void pause(KiwixPack pack) => _downloads[pack.fileName]?.pause();

  Future<void> discard(KiwixPack pack) async {
    await _download(pack).discard();
    states.remove(pack.fileName);
    _downloads.remove(pack.fileName);
    notifyListeners();
  }
}

final knowledgeDownloads = KnowledgeDownloads();
