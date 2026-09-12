import 'dart:io';
import 'dart:typed_data';

import 'package:anx_reader/service/knowledge/kiwix_catalog.dart';
import 'package:anx_reader/service/knowledge/knowledge_download.dart';
import 'package:flutter_test/flutter_test.dart';

import 'zim_archive_test.dart' as zim;

void main() {
  late HttpServer server;
  late Uint8List pack;
  final ranges = <String?>[];
  var dropFirst = true;

  setUp(() async {
    pack = zim.buildZim(
      {for (var i = 0; i < 200; i++) '条目$i': '<p>${'内容 $i ' * 40}</p>'},
      {},
      {'Title': '下载测试'},
    );
    ranges.clear();
    dropFirst = true;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final response = request.response;
      if (request.uri.path.startsWith('/lb/')) {
        // The load balancer sends every request on to a mirror.
        response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, '/mirror/${request.uri.pathSegments.last}');
        await response.close();
        return;
      }
      final range = request.headers.value(HttpHeaders.rangeHeader);
      ranges.add(range);
      final from = int.tryParse(RegExp(r'bytes=(\d+)-').firstMatch(range ?? '')?.group(1) ?? '') ?? 0;
      response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes $from-${pack.length - 1}/${pack.length}');
      // The first response ends halfway, as a dropped connection would leave it.
      final end = dropFirst ? from + (pack.length - from) ~/ 2 : pack.length;
      dropFirst = false;
      response.add(pack.sublist(from, end));
      await response.close();
    });
  });

  tearDown(() => server.close(force: true));

  test('an interrupted download continues through the redirect where it stopped', () async {
    final dir = Directory.systemTemp.createTempSync('download_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final download = KnowledgeDownload(
      pack: KiwixPack(
        name: 'test',
        flavour: 'mini',
        title: '下载测试',
        summary: '',
        language: 'zho',
        updated: null,
        articleCount: 0,
        approximateSize: pack.length,
        downloadUrl: Uri.parse('http://127.0.0.1:${server.port}/lb/test_2026-06.zim'),
      ),
      root: dir,
    );

    await expectLater(download.start(), throwsA(anything));
    final partial = download.downloadedBytes;
    expect(partial, greaterThan(0));
    expect(partial, lessThan(pack.length));

    var lastProgress = (0, 0);
    final file = await download.start(onProgress: (received, total) => lastProgress = (received, total));
    expect(ranges, ['bytes=0-', 'bytes=$partial-']);
    expect(lastProgress, (pack.length, pack.length));
    expect(file.path, endsWith('test_2026-06.zim'));
    expect(await file.readAsBytes(), pack);
    expect(download.partFile.existsSync(), isFalse);
  });
}
