import 'dart:convert';
import 'dart:io';

import 'package:anx_reader/models/book_series.dart';
import 'package:archive/archive_io.dart';
import 'package:xml/xml.dart';

/// Reads the series from an OPF package document.
///
/// EPUB 3 states it with `belongs-to-collection`, and a collection typed
/// `series` wins; `set` collections are publisher lines, not reading order.
/// Calibre writes `calibre:series` metas, which is where most series
/// information in real files lives. An untyped collection is the last resort.
BookSeries? parseOpfSeries(String opf) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(_withoutBom(opf));
  } on XmlException {
    return null;
  }
  final metas = doc.descendants
      .whereType<XmlElement>()
      .where((element) => element.localName == 'meta')
      .toList();

  String? refinement(String id, String property) {
    for (final meta in metas) {
      if (meta.getAttribute('refines') == '#$id' &&
          meta.getAttribute('property') == property) {
        return meta.innerText.trim();
      }
    }
    return null;
  }

  String? named(String name) {
    for (final meta in metas) {
      if (meta.getAttribute('name') == name) {
        return meta.getAttribute('content')?.trim();
      }
    }
    return null;
  }

  BookSeries? typed;
  BookSeries? untyped;
  for (final meta in metas) {
    if (meta.getAttribute('property') != 'belongs-to-collection' ||
        meta.getAttribute('refines') != null) {
      continue;
    }
    final name = meta.innerText.trim();
    if (name.isEmpty) continue;
    final id = meta.getAttribute('id');
    final type = id == null ? null : refinement(id, 'collection-type');
    final series = BookSeries(
      name,
      id == null ? null : _position(refinement(id, 'group-position')),
    );
    if (type == 'series') {
      typed ??= series;
    } else if (type == null || type.isEmpty) {
      untyped ??= series;
    }
  }
  if (typed != null) return typed;

  final calibre = named('calibre:series');
  if (calibre != null && calibre.isNotEmpty) {
    return BookSeries(calibre, _position(named('calibre:series_index')));
  }
  return untyped;
}

/// Reads the series of the EPUB at [path]: null when it names none or the file
/// cannot be read as an EPUB.
BookSeries? readEpubSeries(String path) {
  InputFileStream? input;
  try {
    input = InputFileStream(path);
    final archive = ZipDecoder().decodeBuffer(input);

    String? text(String name) {
      final file = archive.findFile(name);
      if (file == null) return null;
      return utf8.decode(file.content as List<int>, allowMalformed: true);
    }

    final container = text('META-INF/container.xml');
    if (container == null) return null;
    String? rootfile;
    for (final element in XmlDocument.parse(_withoutBom(container))
        .descendants
        .whereType<XmlElement>()) {
      final fullPath = element.getAttribute('full-path');
      if (element.localName == 'rootfile' &&
          fullPath != null &&
          fullPath.isNotEmpty) {
        rootfile = fullPath;
        break;
      }
    }
    if (rootfile == null) return null;
    final opf = text(rootfile) ?? text(Uri.decodeFull(rootfile));
    return opf == null ? null : parseOpfSeries(opf);
  } catch (_) {
    return null;
  } finally {
    input?.closeSync();
  }
}

/// Series of each book file, keyed like [paths]. Files that are not there yet —
/// a synced book not downloaded — are left out, so they are read once they
/// arrive; files that are not EPUB map to null.
Map<int, BookSeries?> readSeriesOfFiles(Map<int, String> paths) {
  final found = <int, BookSeries?>{};
  for (final MapEntry(key: id, value: path) in paths.entries) {
    if (!File(path).existsSync()) continue;
    found[id] =
        path.toLowerCase().endsWith('.epub') ? readEpubSeries(path) : null;
  }
  return found;
}

/// Orders by series name, then by place in the series. Books outside any series
/// come after every series whichever way names run, and so do books in a series
/// without a position after those with one; 0 leaves the tie to the caller.
int compareBySeries(
  BookSeries? a,
  BookSeries? b, {
  required int Function(String, String) compareNames,
  bool descending = false,
}) {
  if (a == null || b == null) {
    if (a == null && b == null) return 0;
    return a == null ? 1 : -1;
  }
  final byName = compareNames(a.name, b.name);
  if (byName != 0) return descending ? -byName : byName;
  final pa = a.position;
  final pb = b.position;
  if (pa == pb) return 0;
  if (pa == null) return 1;
  if (pb == null) return -1;
  return pa.compareTo(pb);
}

typedef SeriesShelfBook = ({int id, int groupId, BookSeries? series});

class SeriesGroupPlan {
  const SeriesGroupPlan({
    required this.name,
    required this.groupId,
    required this.createNew,
    required this.bookIds,
  });

  final String name;
  final int groupId;
  final bool createNew;

  /// In series order.
  final List<int> bookIds;

  @override
  String toString() =>
      'SeriesGroupPlan($name, $groupId, createNew: $createNew, $bookIds)';
}

/// Folders to put series in.
///
/// Only books still loose on the shelf move: a book someone already put in a
/// folder stays there. A series joins an existing folder with its name;
/// otherwise it gets a new folder, but only for two or more loose books, since a
/// folder around a single book just hides it. A new folder reuses a member's
/// book id, as folders made by dragging do.
List<SeriesGroupPlan> planSeriesGroups(
  Iterable<SeriesShelfBook> books,
  Map<int, String> existingGroups,
) {
  final loose = <String, List<SeriesShelfBook>>{};
  for (final book in books) {
    final name = book.series?.name.trim();
    if (book.groupId != 0 || name == null || name.isEmpty) continue;
    (loose[name] ??= []).add(book);
  }

  final groupByName = <String, int>{};
  for (final MapEntry(key: id, value: name) in existingGroups.entries) {
    groupByName.putIfAbsent(name.trim(), () => id);
  }
  final takenIds = {...existingGroups.keys};

  final plans = <SeriesGroupPlan>[];
  for (final MapEntry(key: name, value: members) in loose.entries) {
    members.sort((a, b) {
      final byPosition =
          compareBySeries(a.series, b.series, compareNames: (_, __) => 0);
      return byPosition != 0 ? byPosition : a.id.compareTo(b.id);
    });
    final ids = [for (final member in members) member.id];

    final existing = groupByName[name];
    if (existing != null) {
      plans.add(SeriesGroupPlan(
          name: name, groupId: existing, createNew: false, bookIds: ids));
      continue;
    }
    if (ids.length < 2) continue;
    int? groupId;
    for (final id in ids) {
      if (!takenIds.contains(id)) {
        groupId = id;
        break;
      }
    }
    if (groupId == null) continue;
    takenIds.add(groupId);
    plans.add(SeriesGroupPlan(
        name: name, groupId: groupId, createNew: true, bookIds: ids));
  }
  return plans;
}

String _withoutBom(String text) =>
    text.startsWith('﻿') ? text.substring(1) : text;

double? _position(String? value) =>
    value == null ? null : double.tryParse(value.trim());
