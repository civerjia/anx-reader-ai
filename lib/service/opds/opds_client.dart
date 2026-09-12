import 'dart:convert';
import 'dart:io';

import 'package:anx_reader/models/opds_catalog.dart';
import 'package:anx_reader/service/opds/opds_feed.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Talks to one OPDS catalog: fetches feeds and downloads books.
class OpdsClient {
  OpdsClient(this.catalog, {Dio? dio}) : _dio = dio ?? Dio();

  final OpdsCatalog catalog;
  final Dio _dio;

  Uri get root => Uri.parse(catalog.url.trim());

  /// The Basic credential for this catalog, or null when it needs none.
  /// Covers are fetched with it too; a protected server protects its images.
  String? get authorizationHeader => catalog.hasCredentials
      ? 'Basic ${base64Encode(utf8.encode('${catalog.username}:${catalog.password}'))}'
      : null;

  Map<String, String> get _headers => {
        'Accept':
            'application/atom+xml;profile=opds-catalog, application/atom+xml, application/xml;q=0.9, */*;q=0.8',
        if (authorizationHeader != null) 'Authorization': authorizationHeader!,
      };

  Future<OpdsFeed> fetch(Uri url) async {
    final response = await _dio.getUri<String>(
      url,
      options: Options(headers: _headers, responseType: ResponseType.plain),
    );
    return parseOpdsFeed(response.data ?? '', response.realUri);
  }

  /// A search URL template for [feed], fetching the OpenSearch description
  /// when that is how the server advertises it.
  Future<String?> searchTemplate(OpdsFeed feed) async {
    if (feed.searchTemplate != null) return feed.searchTemplate;
    final description = feed.openSearchDescription;
    if (description == null) return null;
    try {
      final response = await _dio.getUri<String>(
        description,
        options: Options(headers: _headers, responseType: ResponseType.plain),
      );
      return parseOpenSearchTemplate(response.data ?? '', response.realUri);
    } catch (_) {
      return null;
    }
  }

  Uri searchUrl(String template, String query) =>
      Uri.parse(template.replaceAll('{searchTerms}', Uri.encodeQueryComponent(query)));

  /// Downloads [acquisition] into a temporary file named after the book, with
  /// the extension the importer needs to recognise it.
  Future<File> download(
    OpdsEntry entry,
    OpdsAcquisition acquisition, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final dir = Directory(p.join((await getTemporaryDirectory()).path, 'opds'));
    await dir.create(recursive: true);
    final extension = acquisition.extension ?? 'epub';
    final file = File(p.join(dir.path, '${safeFileName(entry.title)}.$extension'));
    await _dio.downloadUri(
      acquisition.href,
      file.path,
      options: Options(headers: _headers),
      onReceiveProgress: onProgress,
      cancelToken: cancelToken,
    );
    return file;
  }
}

/// A file name that is valid everywhere the app runs.
String safeFileName(String title) {
  final cleaned = title.replaceAll(RegExp(r'[\\/:*?"<>|\n\r\t]'), ' ').trim();
  final collapsed = cleaned.replaceAll(RegExp(r'\s+'), ' ');
  final name = collapsed.isEmpty ? 'book' : collapsed;
  return name.length > 80 ? name.substring(0, 80) : name;
}
