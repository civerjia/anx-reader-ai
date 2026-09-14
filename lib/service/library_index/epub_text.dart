import 'dart:convert';

import 'package:archive/archive_io.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:xml/xml.dart';

/// One document of an EPUB's reading order, as plain text.
class EpubSection {
  const EpubSection({
    required this.index,
    required this.href,
    required this.title,
    required this.text,
  });

  /// Position in the spine.
  final int index;

  /// Path inside the archive.
  final String href;

  /// The table-of-contents entry this document falls under, or ''.
  final String title;

  /// Paragraphs separated by '\n', whitespace inside them collapsed.
  final String text;
}

/// A stretch of a section's text, by character offsets.
class TextChunk {
  const TextChunk(this.section, this.start, this.end);
  final int section;
  final int start;
  final int end;
}

const _blockTags = {
  'p', 'div', 'section', 'article', 'blockquote', 'li', 'ul', 'ol', 'tr',
  'table', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'br', 'hr', 'pre', 'dd', 'dt',
  'figcaption', 'header', 'footer', 'aside', 'nav',
};

String _normalizePath(String path) {
  final parts = <String>[];
  for (final part in path.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else {
      parts.add(part);
    }
  }
  return parts.join('/');
}

String _resolve(String base, String href) {
  final clean = href.split('#').first;
  final dir = base.contains('/') ? base.substring(0, base.lastIndexOf('/') + 1) : '';
  return _normalizePath(dir + clean);
}

String _decode(String href) {
  try {
    return Uri.decodeFull(href);
  } catch (_) {
    return href;
  }
}

String _withoutBom(String s) => s.startsWith('﻿') ? s.substring(1) : s;

/// Plain text of an XHTML document: block elements start new paragraphs.
String htmlToText(String source) {
  final document = html.parse(source);
  final root = document.body ?? document.documentElement;
  if (root == null) return '';
  final out = StringBuffer();
  void walk(dom.Node node) {
    if (node is dom.Text) {
      out.write(node.data);
    } else if (node is dom.Element) {
      final tag = node.localName ?? '';
      if (tag == 'script' || tag == 'style' || tag == 'head') return;
      final block = _blockTags.contains(tag);
      if (block) out.write('\n');
      for (final child in node.nodes) {
        walk(child);
      }
      if (block) out.write('\n');
    }
  }

  walk(root);
  return out
      .toString()
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
      .where((line) => line.isNotEmpty)
      .join('\n');
}

/// The reading order of the EPUB at [path], as text. With [only], documents
/// outside that set of spine positions are not decompressed, and come back
/// with empty text; titles are still assigned to every section.
List<EpubSection> readEpubSections(String path, {Set<int>? only}) {
  final input = InputFileStream(path);
  try {
    final archive = ZipDecoder().decodeBuffer(input);
    String? read(String name) {
      final file = archive.findFile(name) ?? archive.findFile(_decode(name));
      if (file == null) return null;
      return _withoutBom(
          utf8.decode(file.content as List<int>, allowMalformed: true));
    }

    final container = read('META-INF/container.xml');
    if (container == null) return const [];
    final rootfile = XmlDocument.parse(container)
        .descendants
        .whereType<XmlElement>()
        .firstWhere((e) => e.localName == 'rootfile',
            orElse: () => XmlElement(XmlName('none')))
        .getAttribute('full-path');
    if (rootfile == null) return const [];
    final opfPath = _decode(rootfile);
    final opfSource = read(opfPath);
    if (opfSource == null) return const [];
    final opf = XmlDocument.parse(opfSource);
    final elements = opf.descendants.whereType<XmlElement>().toList();

    final manifest = <String, (String href, String type, String props)>{};
    for (final item in elements.where((e) => e.localName == 'item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id == null || href == null) continue;
      manifest[id] = (
        _resolve(opfPath, _decode(href)),
        item.getAttribute('media-type') ?? '',
        item.getAttribute('properties') ?? '',
      );
    }
    final spine = [
      for (final ref in elements.where((e) => e.localName == 'itemref'))
        if (manifest[ref.getAttribute('idref')] case final entry?)
          if (entry.$2.contains('html')) entry.$1,
    ];

    // Titles from the EPUB 3 nav document, else the NCX.
    final titles = <String, String>{};
    final nav = manifest.values.where((m) => m.$3.split(' ').contains('nav'));
    final ncxId = elements
        .firstWhere((e) => e.localName == 'spine',
            orElse: () => XmlElement(XmlName('none')))
        .getAttribute('toc');
    final ncx = manifest.values.where(
        (m) => m.$2 == 'application/x-dtbncx+xml') .followedBy([
      if (ncxId != null && manifest[ncxId] != null) manifest[ncxId]!,
    ]);
    if (nav.isNotEmpty) {
      final navPath = nav.first.$1;
      final source = read(navPath);
      if (source != null) {
        for (final a in html.parse(source).querySelectorAll('nav a[href]')) {
          final target = _resolve(navPath, _decode(a.attributes['href']!));
          final label = a.text.replaceAll(RegExp(r'\s+'), ' ').trim();
          if (label.isNotEmpty) titles.putIfAbsent(target, () => label);
        }
      }
    } else if (ncx.isNotEmpty) {
      final ncxPath = ncx.first.$1;
      final source = read(ncxPath);
      if (source != null) {
        for (final point in XmlDocument.parse(source)
            .descendants
            .whereType<XmlElement>()
            .where((e) => e.localName == 'navPoint')) {
          final label = point.descendants
              .whereType<XmlElement>()
              .firstWhere((e) => e.localName == 'text',
                  orElse: () => XmlElement(XmlName('none')))
              .innerText
              .trim();
          final src = point.descendants
              .whereType<XmlElement>()
              .firstWhere((e) => e.localName == 'content',
                  orElse: () => XmlElement(XmlName('none')))
              .getAttribute('src');
          if (label.isEmpty || src == null) continue;
          titles.putIfAbsent(_resolve(ncxPath, _decode(src)), () => label);
        }
      }
    }

    final sections = <EpubSection>[];
    var title = '';
    for (var i = 0; i < spine.length; i++) {
      final href = spine[i];
      title = titles[href] ?? title;
      final text = only == null || only.contains(i)
          ? htmlToText(read(href) ?? '')
          : '';
      sections.add(EpubSection(index: i, href: href, title: title, text: text));
    }
    return sections;
  } finally {
    input.closeSync();
  }
}

/// Splits a section into passages of about [size] characters, ending at
/// paragraph breaks where it can and at sentence ends inside long paragraphs.
List<TextChunk> chunkSection(EpubSection section, {int size = 1000}) {
  final text = section.text;
  final chunks = <TextChunk>[];
  var start = 0;
  while (start < text.length) {
    var end = start + size;
    if (end >= text.length) {
      end = text.length;
    } else {
      final paragraph = text.lastIndexOf('\n', end);
      if (paragraph > start + size ~/ 2) {
        end = paragraph;
      } else {
        final hardEnd = start + size * 3 ~/ 2;
        final searchTo = hardEnd < text.length ? hardEnd : text.length;
        final sentence = RegExp(r'[。！？!?；;\n]').allMatches(
            text.substring(end, searchTo));
        end = sentence.isEmpty ? searchTo : end + sentence.first.end;
      }
    }
    if (text.substring(start, end).trim().isNotEmpty) {
      chunks.add(TextChunk(section.index, start, end));
    }
    start = end;
  }
  return chunks;
}
