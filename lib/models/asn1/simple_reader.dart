import 'dart:typed_data';
import 'dart:convert';

class SimpleAsn1Reader {
  final Uint8List _data;
  int _offset = 0;

  SimpleAsn1Reader(this._data);

  bool get hasMore => _offset < _data.length;

  Asn1Node? readNext() {
    if (_offset >= _data.length) return null;

    final startOffset = _offset; // Capture start position for raw bytes

    // Read Tag
    int firstByte = _data[_offset++];
    int tagValue = firstByte;

    // Extended tag?
    if ((firstByte & 0x1F) == 0x1F) {
      // Multi-byte tag. The whole identifier is folded into one int so tags
      // compare as a single value: 'BF 2D' becomes 0xBF2D.
      while (_offset < _data.length) {
        int b = _data[_offset++];
        tagValue = (tagValue << 8) | b;
        if ((b & 0x80) == 0) break;
      }
    }

    // Read Length
    if (_offset >= _data.length) return null;
    int lengthByte = _data[_offset++];
    int length = 0;

    if ((lengthByte & 0x80) == 0) {
      length = lengthByte; // Short form
    } else {
      int numLengthBytes = lengthByte & 0x7F;
      if (numLengthBytes == 0) {
        length = -1; // Indefinite; handled below.
      } else {
        for (int i = 0; i < numLengthBytes; i++) {
          if (_offset >= _data.length) return null; // Error
          length = (length << 8) | _data[_offset++];
        }
      }
    }

    Uint8List value;
    if (length == -1) {
      // Indefinite length. SGP.22 always uses the definite form, so rather
      // than scan for the end-of-contents marker this yields an empty value.
      value = Uint8List(0);
    } else {
      if (_offset + length > _data.length) {
        // Truncated?
        length = _data.length - _offset;
      }
      value = _data.sublist(_offset, _offset + length);
      _offset += length;
    }

    // Capture the raw bytes from start to current offset
    final rawBytes = _data.sublist(startOffset, _offset);

    return Asn1Node(tagValue, value, rawBytes: rawBytes);
  }
}

class Asn1Node {
  final int tag;
  final Uint8List value;
  final Uint8List? _rawBytes; // Store original encoded bytes

  Asn1Node(this.tag, this.value, {Uint8List? rawBytes}) : _rawBytes = rawBytes;

  /// Get the original encoded bytes if available, otherwise re-encode
  Uint8List get encodedBytes {
    if (_rawBytes != null) return _rawBytes;

    // Re-encode if we don't have the original bytes
    final tagBytes = _encodeTag(tag);
    final lengthBytes = _encodeLength(value.length);
    final result = Uint8List(
      tagBytes.length + lengthBytes.length + value.length,
    );
    var offset = 0;
    result.setRange(offset, offset + tagBytes.length, tagBytes);
    offset += tagBytes.length;
    result.setRange(offset, offset + lengthBytes.length, lengthBytes);
    offset += lengthBytes.length;
    result.setRange(offset, offset + value.length, value);
    return result;
  }

  static Uint8List _encodeTag(int tag) {
    if (tag < 0x100) {
      return Uint8List.fromList([tag]);
    }
    // Multi-byte tag encoding
    final bytes = <int>[];
    var t = tag;
    while (t > 0) {
      bytes.insert(0, (t & 0x7F) | (bytes.isEmpty ? 0 : 0x80));
      t >>= 7;
    }
    return Uint8List.fromList(bytes);
  }

  static Uint8List _encodeLength(int length) {
    if (length < 128) {
      return Uint8List.fromList([length]);
    }
    final bytes = <int>[];
    var len = length;
    while (len > 0) {
      bytes.insert(0, len & 0xFF);
      len >>= 8;
    }
    bytes.insert(0, 0x80 | bytes.length);
    return Uint8List.fromList(bytes);
  }

  List<Asn1Node>? _children;

  /// Child TLVs of this node, parsed once and kept.
  ///
  /// The generated decoders look this up repeatedly — once per member of a
  /// SEQUENCE, and again to fetch the member they matched — so re-parsing on
  /// every access made decoding quadratic in the number of members.
  List<Asn1Node> get children {
    final cached = _children;
    if (cached != null) return cached;

    // Try to parse value as sequence
    final reader = SimpleAsn1Reader(value);
    final list = <Asn1Node>[];
    while (reader.hasMore) {
      final n = reader.readNext();
      if (n != null) list.add(n);
    }
    return _children = list;
  }

  // Helpers for checking tags
  bool isTag(int t) => tag == t;

  @override
  String toString() => prettyPrint();

  String prettyPrint([int indent = 0]) {
    final prefix = ' ' * indent;

    // Extract ASN.1 components from the tag
    int firstTagByte = tag;
    while (firstTagByte > 0xFF) {
      firstTagByte >>= 8;
    }

    final tagClass = (firstTagByte >> 6) & 0x03;
    final isConstructed = (firstTagByte & 0x20) != 0;

    final classNames = ['Universal', 'Application', 'Context', 'Private'];
    final className = classNames[tagClass];

    // Known Universal Tags
    final universalTagNames = {
      0x01: 'BOOLEAN',
      0x02: 'INTEGER',
      0x03: 'BIT STRING',
      0x04: 'OCTET STRING',
      0x05: 'NULL',
      0x06: 'OBJECT IDENTIFIER',
      0x0A: 'ENUMERATED',
      0x0C: 'UTF8String',
      0x12: 'NumericString',
      0x13: 'PrintableString',
      0x16: 'IA5String',
      0x17: 'UTCTime',
      0x18: 'GeneralizedTime',
      0x30: 'SEQUENCE',
      0x31: 'SET',
    };

    String tagLabel = '0x${tag.toRadixString(16).toUpperCase()}';
    if (tagClass == 0 && universalTagNames.containsKey(tag)) {
      tagLabel = '${universalTagNames[tag]} ($tagLabel)';
    } else {
      tagLabel = '[$className $tagLabel]';
    }

    final sb = StringBuffer();
    sb.write('$prefix$tagLabel');

    // Attempt parse children if constructed
    List<Asn1Node>? parsedChildren;
    if (isConstructed) {
      try {
        parsedChildren = children;
        // If it's constructed but parsing yielded nothing despite having value,
        // it might not actually be a TLV sequence.
        if (parsedChildren.isEmpty && value.isNotEmpty) {
          parsedChildren = null;
        }
      } catch (e) {
        parsedChildren = null;
      }
    }

    if (isConstructed && parsedChildren != null) {
      sb.writeln(' (${value.length} bytes) {');
      for (final child in parsedChildren) {
        sb.write(child.prettyPrint(indent + 2));
      }
      sb.writeln('$prefix}');
    } else {
      if (value.isEmpty) {
        if (tag == 0x05) {
          sb.writeln(); // NULL tag
        } else {
          sb.writeln(' [Empty]');
        }
      } else {
        // Check for string-like types
        bool looksLikeString = false;
        // Universal string tags
        if (tagClass == 0 &&
            (tag == 0x0C ||
                tag == 0x13 ||
                tag == 0x16 ||
                tag == 0x17 ||
                tag == 0x18)) {
          looksLikeString = true;
        }

        // If not a known string tag, check if it's printable anyway
        if (!looksLikeString) {
          bool allPrintable = true;
          for (final b in value) {
            if (b < 0x20 || b > 0x7E) {
              if (b != 0x0D && b != 0x0A && b != 0x09) {
                allPrintable = false;
                break;
              }
            }
          }
          if (allPrintable && value.length > 1) looksLikeString = true;
        }

        if (looksLikeString) {
          try {
            final str = utf8.decode(value);
            sb.writeln(' "$str"');
          } catch (_) {
            // Fallback to Latin1 or just hex if UTF-8 fails
            final str = String.fromCharCodes(value);
            sb.writeln(' (raw) "$str"');
          }
        } else {
          // Simple hex
          final hex = value
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join('');
          if (hex.length > 64) {
            sb.writeln(' [${value.length} bytes] ${hex.substring(0, 64)}...');
          } else {
            sb.writeln(' [${value.length} bytes] $hex');
          }
        }
      }
    }
    return sb.toString();
  }
}
