import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Reads the bits of ONNX metadata that sherpa-onnx models carry but the
/// sherpa-onnx API does not expose.
///
/// Kokoro and Kitten models record which speaker id is which voice in a
/// `speaker_names` metadata entry (`af_heart,...,zf_xiaoxiao,...`). Without
/// it the voice list can only show bare numbers.
class SherpaOnnxMeta {
  /// ONNX stores `metadata_props` after the graph, so the entries sit at the
  /// very end of the file; reading the tail avoids touching a model that can
  /// be hundreds of megabytes.
  static const int _tailBytes = 512 * 1024;

  /// Speaker names in speaker id order, or an empty list when the model does
  /// not carry them.
  static List<String> speakerNames(String modelPath) {
    final value = _metadata(modelPath, 'speaker_names');
    if (value == null) return const [];
    return value
        .split(',')
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toList();
  }

  /// Value of one `metadata_props` entry, read straight out of the protobuf.
  ///
  /// An entry is a `StringStringEntryProto`, so the key is followed by field
  /// 2 (tag `0x12`), a varint length and the UTF-8 value. Anything
  /// unexpected returns null rather than throwing: the metadata is a nicety,
  /// not something to fail a model load over.
  static String? _metadata(String modelPath, String key) {
    RandomAccessFile? file;
    try {
      final onnx = File(modelPath);
      if (!onnx.existsSync()) return null;
      file = onnx.openSync();
      final length = file.lengthSync();
      final start = length > _tailBytes ? length - _tailBytes : 0;
      file.setPositionSync(start);
      final bytes = file.readSync(length - start);

      final keyBytes = ascii.encode(key);
      final at = _lastIndexOf(bytes, keyBytes);
      if (at < 0) return null;

      var pos = at + keyBytes.length;
      if (pos >= bytes.length || bytes[pos] != 0x12) return null;
      pos++;

      var valueLength = 0;
      var shift = 0;
      while (true) {
        if (pos >= bytes.length || shift > 28) return null;
        final byte = bytes[pos++];
        valueLength |= (byte & 0x7f) << shift;
        if (byte & 0x80 == 0) break;
        shift += 7;
      }

      if (valueLength <= 0 || pos + valueLength > bytes.length) return null;
      return utf8.decode(bytes.sublist(pos, pos + valueLength),
          allowMalformed: true);
    } catch (_) {
      return null;
    } finally {
      file?.closeSync();
    }
  }

  static int _lastIndexOf(Uint8List haystack, List<int> needle) {
    outer:
    for (var i = haystack.length - needle.length; i >= 0; i--) {
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }
}
