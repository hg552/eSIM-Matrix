import 'dart:typed_data';

/// Minimal BER-TLV parsing for SIM FCP templates and EF_DIR records, ported
/// from `sim/tlv.go`.

const int _tagFcpTemplate = 0x62;
const int _tagFileDescriptor = 0x82;
const int _tagFileSize = 0x80;
const int _tagApplication = 0x61;
const int _tagApplicationAid = 0x4f;
const int _tagApplicationName = 0x50;

const int _structureLinearFixed = 0x42;

class Tlv {
  final List<int> tag;
  final Uint8List value;
  final List<Tlv> children;
  Tlv(this.tag, this.value, this.children);

  static Tlv parse(List<int> data) {
    final result = _read(data, 0);
    if (result.next != data.length) {
      throw FormatException(
        'TLV has ${data.length - result.next} trailing bytes',
      );
    }
    return result.tlv;
  }
}

class _TlvRead {
  final Tlv tlv;
  final int next;
  const _TlvRead(this.tlv, this.next);
}

_TlvRead _read(List<int> data, int off) {
  if (off >= data.length) {
    throw const FormatException('TLV tag is missing');
  }
  final first = data[off];
  off++;
  final tag = <int>[first];
  if (first & 0x1f == 0x1f) {
    while (true) {
      if (off >= data.length) {
        throw const FormatException('TLV tag is truncated');
      }
      final b = data[off];
      off++;
      tag.add(b);
      if (b & 0x80 == 0) break;
    }
  }
  // Length.
  if (off >= data.length) {
    throw const FormatException('TLV length is missing');
  }
  var lenByte = data[off];
  off++;
  int length;
  if (lenByte & 0x80 == 0) {
    length = lenByte;
  } else {
    final count = lenByte & 0x7f;
    if (count == 0) {
      throw const FormatException('indefinite TLV length is unsupported');
    }
    if (count > 4) {
      throw FormatException('TLV length uses $count bytes, want at most 4');
    }
    if (off + count > data.length) {
      throw const FormatException('TLV length is truncated');
    }
    length = 0;
    for (var i = 0; i < count; i++) {
      length = (length << 8) | data[off + i];
    }
    off += count;
  }
  if (off + length > data.length) {
    throw const FormatException('TLV value is truncated');
  }
  final value = Uint8List.fromList(data.sublist(off, off + length));
  off += length;
  final children = <Tlv>[];
  if (first & 0x20 != 0) {
    var childOff = 0;
    while (childOff < value.length) {
      final child = _read(value, childOff);
      children.add(child.tlv);
      childOff = child.next;
    }
  }
  return _TlvRead(Tlv(tag, value, children), off);
}

/// Parsed EF file control parameters (linear fixed files expose record info).
class FileInfo {
  final int fileStructure;
  final int recordSize;
  final int recordCount;
  final int fileSize;
  const FileInfo({
    required this.fileStructure,
    required this.recordSize,
    required this.recordCount,
    required this.fileSize,
  });

  bool get isLinearFixed => fileStructure == _structureLinearFixed;

  static FileInfo parse(List<int> data) {
    final fcp = Tlv.parse(data);
    if (fcp.tag.length != 1 || fcp.tag[0] != _tagFcpTemplate) {
      throw const FormatException('missing FCP template');
    }
    var structure = 0, recordSize = 0, recordCount = 0, fileSize = 0;
    for (final item in fcp.children) {
      if (item.tag.length != 1) continue;
      if (item.tag[0] == _tagFileDescriptor) {
        if (item.value.length != 2 && item.value.length != 5) {
          throw const FormatException('unexpected file descriptor length');
        }
        structure = item.value[0];
        if (item.value.length == 5) {
          recordSize = (item.value[2] << 8) | item.value[3];
          recordCount = item.value[4];
        }
      } else if (item.tag[0] == _tagFileSize) {
        if (item.value.length != 2) {
          throw const FormatException('unexpected file size length');
        }
        fileSize = (item.value[0] << 8) | item.value[1];
      }
    }
    if (structure == 0) {
      throw const FormatException('missing file descriptor');
    }
    return FileInfo(
      fileStructure: structure,
      recordSize: recordSize,
      recordCount: recordCount,
      fileSize: fileSize,
    );
  }
}

/// An EF_DIR application record (AID + optional label).
class SimApplication {
  final Uint8List aid;
  final String label;
  const SimApplication({required this.aid, required this.label});

  /// Parses a single EF_DIR record; returns null for empty/padding records.
  static SimApplication? parseRecord(List<int> data) {
    var end = data.length;
    while (end > 0 && data[end - 1] == 0xff) {
      end--;
    }
    if (end == 0) return null;
    final record = Tlv.parse(data.sublist(0, end));
    if (record.tag.length != 1 || record.tag[0] != _tagApplication) {
      throw const FormatException('missing application template');
    }
    Uint8List? aid;
    var label = '';
    for (final item in record.children) {
      if (item.tag.length != 1) continue;
      if (item.tag[0] == _tagApplicationAid) {
        aid = Uint8List.fromList(item.value);
      } else if (item.tag[0] == _tagApplicationName) {
        label = String.fromCharCodes(item.value);
      }
    }
    if (aid == null || aid.isEmpty) {
      throw const FormatException('missing application AID');
    }
    return SimApplication(aid: aid, label: label);
  }
}

bool bytesStartsWith(List<int> data, List<int> prefix) {
  if (data.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (data[i] != prefix[i]) return false;
  }
  return true;
}
