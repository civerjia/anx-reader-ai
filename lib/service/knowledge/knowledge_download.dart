import 'dart:async';
import 'dart:io';

import 'package:anx_reader/service/knowledge/kiwix_catalog.dart';
import 'package:anx_reader/service/knowledge/zim_archive.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

/// Downloads one Kiwix pack into [root], resuming from a partial `.part` file.
///
/// Kiwix answers through a load balancer that redirects to a mirror. Redirects
/// are followed by hand so the Range header reaches the mirror on every hop,
/// and the exact size is read from the mirror's Content-Range (the catalog's
/// size is rounded).
class KnowledgeDownload {
  KnowledgeDownload({required this.pack, required this.root, Dio? dio})
      : _dio = dio ?? Dio();

  final KiwixPack pack;
  final Directory root;
  final Dio _dio;
  CancelToken? _cancel;

  File get partFile => File(p.join(root.path, '${pack.fileName}.part'));
  File get finalFile => File(p.join(root.path, pack.fileName));

  int get downloadedBytes => partFile.existsSync() ? partFile.lengthSync() : 0;

  bool get isRunning => _cancel != null && !_cancel!.isCancelled;

  Options _options(int from) => Options(
        responseType: ResponseType.stream,
        followRedirects: false,
        headers: {HttpHeaders.rangeHeader: 'bytes=$from-'},
        validateStatus: (status) => status != null && status < 400,
      );

  /// Downloads the rest of the pack, calling [onProgress] with bytes on disk and
  /// the total. Throws when stopped or failed; call again to continue.
  Future<File> start({void Function(int received, int total)? onProgress}) async {
    root.createSync(recursive: true);
    final cancel = _cancel = CancelToken();
    var have = downloadedBytes;
    var url = pack.downloadUrl;
    Response<ResponseBody>? response;
    for (var hop = 0; hop < 8; hop++) {
      response = await _dio.getUri<ResponseBody>(url,
          options: _options(have), cancelToken: cancel);
      final status = response.statusCode ?? 0;
      if (status >= 300 && status < 400) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.data?.stream.drain<void>();
        if (location == null) throw StateError('redirect without a location');
        url = url.resolve(location);
        continue;
      }
      break;
    }
    if (response == null || (response.statusCode ?? 0) >= 300) {
      throw StateError('too many redirects');
    }

    var total = 0;
    final range = response.headers.value(HttpHeaders.contentRangeHeader);
    final match = range == null ? null : RegExp(r'/(\d+)$').firstMatch(range);
    if (response.statusCode == 206 && match != null) {
      total = int.parse(match.group(1)!);
    } else {
      // The server sent the whole file: start over rather than append.
      have = 0;
      total = int.tryParse(
              response.headers.value(HttpHeaders.contentLengthHeader) ?? '') ??
          0;
    }

    final sink = partFile.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
    try {
      onProgress?.call(have, total);
      await for (final chunk in response.data!.stream) {
        sink.add(chunk);
        have += chunk.length;
        onProgress?.call(have, total);
      }
    } finally {
      await sink.flush();
      await sink.close();
      if (identical(_cancel, cancel)) _cancel = null;
    }

    if (total > 0 && have < total) {
      throw StateError('connection ended at $have of $total bytes');
    }
    if (finalFile.existsSync()) await finalFile.delete();
    await partFile.rename(finalFile.path);
    final archive = await ZimArchive.open(finalFile);
    await archive.close();
    return finalFile;
  }

  void pause() => _cancel?.cancel('paused');

  /// Stops and removes what was downloaded.
  Future<void> discard() async {
    pause();
    if (partFile.existsSync()) await partFile.delete();
  }
}
