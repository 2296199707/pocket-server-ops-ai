import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as path_util;

enum DocumentSourceFormat { markdown, html, text }

DocumentSourceFormat documentSourceFormatFor(String fileName) {
  switch (path_util.posix.extension(fileName).toLowerCase()) {
    case '.md':
    case '.markdown':
      return DocumentSourceFormat.markdown;
    case '.html':
    case '.htm':
      return DocumentSourceFormat.html;
    default:
      return DocumentSourceFormat.text;
  }
}

bool isDocumentSourceFile(String fileName) {
  final extension = path_util.posix.extension(fileName).toLowerCase();
  return extension == '.md' ||
      extension == '.markdown' ||
      extension == '.html' ||
      extension == '.htm' ||
      extension == '.txt';
}

class DocumentExportService {
  const DocumentExportService();

  Uint8List exportDocx({required String fileName, required String content}) {
    final format = documentSourceFormatFor(fileName);
    final blocks = _DocumentParser(format, content).parse();
    final files = <String, List<int>>{
      '[Content_Types].xml': utf8.encode(_contentTypesXml),
      '_rels/.rels': utf8.encode(_rootRelationshipsXml),
      'word/document.xml': utf8.encode(_documentXml(blocks)),
      'word/styles.xml': utf8.encode(_stylesXml),
      'word/_rels/document.xml.rels': utf8.encode(_documentRelationshipsXml),
    };
    return _StoredZip.encode(files);
  }

  String _documentXml(List<_DocumentBlock> blocks) {
    final body = StringBuffer();
    for (final block in blocks) {
      body.write(block.toXml());
    }
    if (body.isEmpty) body.write('<w:p/>');
    body.write(
      '<w:sectPr>'
      '<w:pgSz w:w="11906" w:h="16838"/>'
      '<w:pgMar w:top="1440" w:right="1417" w:bottom="1440" '
      'w:left="1701" w:header="708" w:footer="708" w:gutter="0"/>'
      '</w:sectPr>',
    );
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        '<w:body>$body</w:body></w:document>';
  }
}

class _DocumentBlock {
  _DocumentBlock.paragraph(
    this.runs, {
    this.headingLevel = 0,
    this.prefix,
    this.code = false,
  }) : rows = null;

  _DocumentBlock.table(this.rows)
    : runs = const [],
      headingLevel = 0,
      prefix = null,
      code = false;

  final List<_DocumentRun> runs;
  final List<List<List<_DocumentRun>>>? rows;
  final int headingLevel;
  final String? prefix;
  final bool code;

  String toXml() {
    final tableRows = rows;
    if (tableRows != null) {
      return _tableXml(tableRows);
    }
    final properties = StringBuffer('<w:pPr>');
    if (headingLevel > 0) {
      properties.write('<w:pStyle w:val="Heading$headingLevel"/>');
      properties.write('<w:keepNext/>');
    } else if (code) {
      properties.write('<w:pStyle w:val="Code"/>');
    }
    properties.write(
      '<w:spacing w:after="120" w:line="360" w:lineRule="auto"/>',
    );
    properties.write('</w:pPr>');
    final content = StringBuffer();
    if (prefix != null) {
      content.write(_DocumentRun(prefix!).toXml());
    }
    for (final run in runs) {
      content.write(run.toXml());
    }
    return '<w:p>$properties$content</w:p>';
  }
}

class _DocumentRun {
  const _DocumentRun(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.code = false,
    this.color,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool code;
  final String? color;

  _DocumentRun withStyle({String? colorOverride}) => _DocumentRun(
    text,
    bold: bold,
    italic: italic,
    code: code,
    color: colorOverride ?? color,
  );

  String toXml() {
    if (text.isEmpty) return '';
    final properties = StringBuffer('<w:rPr>');
    properties.write(
      '<w:rFonts w:ascii="Aptos" w:hAnsi="Aptos" '
      'w:eastAsia="Noto Sans CJK SC"/>',
    );
    if (bold) properties.write('<w:b/>');
    if (italic) properties.write('<w:i/>');
    if (code) properties.write('<w:rStyle w:val="CodeChar"/>');
    if (color != null) properties.write('<w:color w:val="$color"/>');
    properties.write('</w:rPr>');
    final content = StringBuffer();
    final parts = text.split('\n');
    for (var index = 0; index < parts.length; index++) {
      if (index > 0) content.write('<w:br/>');
      final part = parts[index];
      if (part.isNotEmpty) {
        content.write('<w:t xml:space="preserve">${_xmlEscape(part)}</w:t>');
      }
    }
    return '<w:r>$properties$content</w:r>';
  }
}

class _DocumentParser {
  _DocumentParser(this.format, this.content);

  final DocumentSourceFormat format;
  final String content;

  List<_DocumentBlock> parse() {
    final source = format == DocumentSourceFormat.html
        ? _htmlToMarkdownish(content)
        : content;
    final lines = source
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');
    final blocks = <_DocumentBlock>[];
    final paragraphLines = <String>[];
    var inCode = false;
    final codeLines = <String>[];

    void flushParagraph() {
      if (paragraphLines.isEmpty) return;
      final text = paragraphLines.join('\n').trimRight();
      paragraphLines.clear();
      if (text.trim().isEmpty) return;
      blocks.add(_DocumentBlock.paragraph(_inlineRuns(text)));
    }

    void flushCode() {
      if (codeLines.isEmpty) return;
      blocks.add(
        _DocumentBlock.paragraph([
          _DocumentRun(codeLines.join('\n'), code: true),
        ], code: true),
      );
      codeLines.clear();
    }

    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      final trimmed = line.trim();
      if (trimmed.startsWith('```')) {
        flushParagraph();
        if (inCode) {
          flushCode();
        }
        inCode = !inCode;
        continue;
      }
      if (inCode) {
        codeLines.add(line);
        continue;
      }
      if (trimmed.isEmpty) {
        flushParagraph();
        continue;
      }
      if (_looksLikeTableLine(trimmed)) {
        final tableLines = <String>[trimmed];
        while (index + 1 < lines.length &&
            _looksLikeTableLine(lines[index + 1].trim())) {
          index++;
          tableLines.add(lines[index].trim());
        }
        if (tableLines.length >= 2) {
          flushParagraph();
          blocks.add(_DocumentBlock.table(_tableRows(tableLines)));
          continue;
        }
      }
      final heading = RegExp(r'^(#{1,6})\s+(.+)$').firstMatch(trimmed);
      if (heading != null) {
        flushParagraph();
        blocks.add(
          _DocumentBlock.paragraph(
            _inlineRuns(heading.group(2)!),
            headingLevel: heading.group(1)!.length,
          ),
        );
        continue;
      }
      final unordered = RegExp(r'^\s*[-*+]\s+(.+)$').firstMatch(line);
      if (unordered != null) {
        flushParagraph();
        blocks.add(
          _DocumentBlock.paragraph(
            _inlineRuns(unordered.group(1)!),
            prefix: '- ',
          ),
        );
        continue;
      }
      final ordered = RegExp(r'^\s*(\d+)[.)]\s+(.+)$').firstMatch(line);
      if (ordered != null) {
        flushParagraph();
        blocks.add(
          _DocumentBlock.paragraph(
            _inlineRuns(ordered.group(2)!),
            prefix: '${ordered.group(1)}. ',
          ),
        );
        continue;
      }
      final quote = RegExp(r'^\s*>\s?(.*)$').firstMatch(line);
      if (quote != null) {
        flushParagraph();
        blocks.add(
          _DocumentBlock.paragraph(_inlineRuns(quote.group(1)!), prefix: '> '),
        );
        continue;
      }
      paragraphLines.add(line);
    }
    if (inCode) flushCode();
    flushParagraph();
    return blocks;
  }
}

List<_DocumentRun> _inlineRuns(String input) {
  final runs = <_DocumentRun>[];
  var index = 0;
  var plainStart = 0;

  void addPlain(int end) {
    if (end > plainStart) {
      runs.add(_DocumentRun(input.substring(plainStart, end)));
    }
  }

  while (index < input.length) {
    if (input.startsWith('[[color=', index)) {
      final markerEnd = input.indexOf(']]', index + 8);
      if (markerEnd >= 0) {
        final close = input.indexOf('[[/color]]', markerEnd + 2);
        if (close >= 0) {
          addPlain(index);
          final color = _normalizeColor(input.substring(index + 8, markerEnd));
          final inner = _inlineRuns(input.substring(markerEnd + 2, close));
          runs.addAll(
            color == null
                ? inner
                : inner.map((run) => run.withStyle(colorOverride: color)),
          );
          index = close + '[[/color]]'.length;
          plainStart = index;
          continue;
        }
      }
    }
    if (input.startsWith('**', index)) {
      final close = input.indexOf('**', index + 2);
      if (close > index + 2) {
        addPlain(index);
        runs.addAll(
          _inlineRuns(input.substring(index + 2, close)).map(
            (run) => _DocumentRun(
              run.text,
              bold: true,
              italic: run.italic,
              code: run.code,
              color: run.color,
            ),
          ),
        );
        index = close + 2;
        plainStart = index;
        continue;
      }
    }
    if (input[index] == '`') {
      final close = input.indexOf('`', index + 1);
      if (close > index + 1) {
        addPlain(index);
        runs.add(_DocumentRun(input.substring(index + 1, close), code: true));
        index = close + 1;
        plainStart = index;
        continue;
      }
    }
    if (input[index] == '*' || input[index] == '_') {
      final marker = input[index];
      final close = input.indexOf(marker, index + 1);
      if (close > index + 1 && (index == 0 || input[index - 1] != marker)) {
        addPlain(index);
        runs.addAll(
          _inlineRuns(input.substring(index + 1, close)).map(
            (run) => _DocumentRun(
              run.text,
              bold: run.bold,
              italic: true,
              code: run.code,
              color: run.color,
            ),
          ),
        );
        index = close + 1;
        plainStart = index;
        continue;
      }
    }
    index++;
  }
  addPlain(input.length);
  return runs.isEmpty ? [const _DocumentRun('')] : runs;
}

bool _looksLikeTableLine(String line) {
  return line.contains('|') && line.split('|').length >= 3;
}

List<List<List<_DocumentRun>>> _tableRows(List<String> lines) {
  final rows = <List<List<_DocumentRun>>>[];
  for (final line in lines) {
    final cells = _tableCells(line);
    if (cells.isEmpty ||
        cells.every((cell) => RegExp(r'^:?-{2,}:?$').hasMatch(cell))) {
      continue;
    }
    rows.add([for (final cell in cells) _inlineRuns(cell)]);
  }
  return rows.isEmpty
      ? <List<List<_DocumentRun>>>[<List<_DocumentRun>>[]]
      : rows;
}

List<String> _tableCells(String line) {
  var value = line.trim();
  if (value.startsWith('|')) value = value.substring(1);
  if (value.endsWith('|')) value = value.substring(0, value.length - 1);
  return value.split('|').map((cell) => cell.trim()).toList(growable: false);
}

String _htmlToMarkdownish(String source) {
  var value = source;
  value = value.replaceAll(
    RegExp(r'<(script|style)\b[^>]*>[\s\S]*?</\1>', caseSensitive: false),
    '',
  );
  for (var level = 6; level >= 1; level--) {
    value = value.replaceAllMapped(
      RegExp('<h$level\\b[^>]*>([\\s\\S]*?)</h$level>', caseSensitive: false),
      (match) => '\n${'#' * level} ${match.group(1)}\n',
    );
  }
  value = value.replaceAllMapped(
    RegExp(
      r'<(?:span|font)\b([^>]*)>([\s\S]*?)</(?:span|font)>',
      caseSensitive: false,
    ),
    (match) {
      final color = _colorFromAttributes(match.group(1) ?? '');
      final text = match.group(2) ?? '';
      return color == null ? text : '[[color=$color]]$text[[/color]]';
    },
  );
  value = value.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  value = value.replaceAll(
    RegExp(r'<(?:td|th)\b[^>]*>', caseSensitive: false),
    '| ',
  );
  value = value.replaceAll(
    RegExp(r'</(?:td|th)>', caseSensitive: false),
    ' | ',
  );
  value = value.replaceAll(RegExp(r'<tr\b[^>]*>', caseSensitive: false), '\n');
  value = value.replaceAll(RegExp(r'</tr>', caseSensitive: false), '');
  value = value.replaceAll(
    RegExp(r'<li\b[^>]*>', caseSensitive: false),
    '\n- ',
  );
  value = value.replaceAll(
    RegExp(
      r'</(?:p|div|section|article|li|ul|ol|pre|blockquote|body|html)>',
      caseSensitive: false,
    ),
    '\n',
  );
  value = value.replaceAll(
    RegExp(
      r'<(?:p|div|section|article|ul|ol|pre|blockquote)\b[^>]*>',
      caseSensitive: false,
    ),
    '\n',
  );
  value = value.replaceAll(RegExp(r'<[^>]+>'), '');
  return _decodeHtmlEntities(value).replaceAll(RegExp(r'\n{3,}'), '\n\n');
}

String? _colorFromAttributes(String attributes) {
  final style = RegExp(
    r'''color\s*:\s*([^;"']+)''',
    caseSensitive: false,
  ).firstMatch(attributes)?.group(1);
  final attribute = RegExp(
    r'''(?:^|\s)color\s*=\s*["']?([^"'\s>]+)''',
    caseSensitive: false,
  ).firstMatch(attributes)?.group(1);
  return _normalizeColor((style ?? attribute)?.trim());
}

String? _normalizeColor(String? value) {
  if (value == null || value.isEmpty) return null;
  final lower = value.toLowerCase();
  const names = <String, String>{
    'black': '000000',
    'blue': '0000FF',
    'green': '008000',
    'gray': '808080',
    'grey': '808080',
    'orange': 'FFA500',
    'red': 'FF0000',
    'white': 'FFFFFF',
  };
  if (names.containsKey(lower)) return names[lower];
  final hex = lower.startsWith('#') ? lower.substring(1) : lower;
  if (RegExp(r'^[0-9a-f]{6}$').hasMatch(hex)) return hex.toUpperCase();
  if (RegExp(r'^[0-9a-f]{3}$').hasMatch(hex)) {
    return hex.split('').map((part) => '$part$part').join().toUpperCase();
  }
  final rgb = RegExp(r'^rgb\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)$')
      .firstMatch(lower);
  if (rgb != null) {
    final values = [
      int.tryParse(rgb.group(1)!) ?? 0,
      int.tryParse(rgb.group(2)!) ?? 0,
      int.tryParse(rgb.group(3)!) ?? 0,
    ];
    if (values.any((value) => value < 0 || value > 255)) return null;
    return values
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
  }
  return null;
}

String _decodeHtmlEntities(String value) {
  return value
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");
}

String _xmlEscape(String value) {
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

String _tableXml(List<List<List<_DocumentRun>>> rows) {
  final body = StringBuffer();
  for (final row in rows) {
    body.write('<w:tr>');
    for (final cell in row) {
      body.write('<w:tc><w:tcPr><w:tcW w:w="0" w:type="auto"/></w:tcPr><w:p>');
      for (final run in cell) {
        body.write(run.toXml());
      }
      body.write('</w:p></w:tc>');
    }
    body.write('</w:tr>');
  }
  return '<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/>'
      '<w:tblBorders><w:top w:val="single" w:sz="4" w:color="B7C3D0"/>'
      '<w:left w:val="single" w:sz="4" w:color="B7C3D0"/>'
      '<w:bottom w:val="single" w:sz="4" w:color="B7C3D0"/>'
      '<w:right w:val="single" w:sz="4" w:color="B7C3D0"/>'
      '<w:insideH w:val="single" w:sz="4" w:color="B7C3D0"/>'
      '<w:insideV w:val="single" w:sz="4" w:color="B7C3D0"/></w:tblBorders>'
      '</w:tblPr>$body</w:tbl>';
}

const _contentTypesXml =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    '<Default Extension="xml" ContentType="application/xml"/>'
    '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
    '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
    '</Types>';

const _rootRelationshipsXml =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
    '</Relationships>';

const _documentRelationshipsXml =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
    '</Relationships>';

const _stylesXml =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
    '<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Aptos" w:hAnsi="Aptos" w:eastAsia="Noto Sans CJK SC"/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr></w:rPrDefault>'
    '<w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="360" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>'
    '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>'
    '<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:rPr><w:b/><w:sz w:val="34"/><w:szCs w:val="34"/></w:rPr></w:style>'
    '<w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:rPr><w:b/><w:sz w:val="29"/><w:szCs w:val="29"/></w:rPr></w:style>'
    '<w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:rPr><w:b/><w:sz w:val="26"/><w:szCs w:val="26"/></w:rPr></w:style>'
    '<w:style w:type="paragraph" w:styleId="Heading4"><w:name w:val="heading 4"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:rPr><w:b/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr></w:style>'
    '<w:style w:type="paragraph" w:styleId="Heading5"><w:name w:val="heading 5"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:rPr><w:b/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:style>'
    '<w:style w:type="paragraph" w:styleId="Heading6"><w:name w:val="heading 6"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:rPr><w:b/><w:sz w:val="20"/><w:szCs w:val="20"/></w:rPr></w:style>'
    '<w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/><w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas"/><w:sz w:val="20"/><w:szCs w:val="20"/></w:rPr></w:style>'
    '<w:style w:type="character" w:styleId="CodeChar"><w:name w:val="Code Char"/><w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas"/></w:rPr></w:style>'
    '</w:styles>';

class _StoredZip {
  static Uint8List encode(Map<String, List<int>> files) {
    final output = BytesBuilder(copy: false);
    final central = BytesBuilder(copy: false);
    var offset = 0;
    var count = 0;
    for (final entry in files.entries) {
      final name = utf8.encode(entry.key);
      final data = entry.value;
      final crc = _crc32(data);
      _u32(output, 0x04034b50);
      _u16(output, 20);
      _u16(output, 0);
      _u16(output, 0);
      _u16(output, 0);
      _u16(output, 0);
      _u32(output, crc);
      _u32(output, data.length);
      _u32(output, data.length);
      _u16(output, name.length);
      _u16(output, 0);
      output.add(name);
      output.add(data);

      _u32(central, 0x02014b50);
      _u16(central, 20);
      _u16(central, 20);
      _u16(central, 0);
      _u16(central, 0);
      _u16(central, 0);
      _u16(central, 0);
      _u32(central, crc);
      _u32(central, data.length);
      _u32(central, data.length);
      _u16(central, name.length);
      _u16(central, 0);
      _u16(central, 0);
      _u16(central, 0);
      _u16(central, 0);
      _u32(central, 0);
      _u32(central, offset);
      central.add(name);

      offset += 30 + name.length + data.length;
      count++;
    }
    final centralBytes = central.takeBytes();
    final centralOffset = offset;
    output.add(centralBytes);
    _u32(output, 0x06054b50);
    _u16(output, 0);
    _u16(output, 0);
    _u16(output, count);
    _u16(output, count);
    _u32(output, centralBytes.length);
    _u32(output, centralOffset);
    _u16(output, 0);
    return output.takeBytes();
  }
}

void _u16(BytesBuilder builder, int value) {
  builder.add([value & 0xff, (value >> 8) & 0xff]);
}

void _u32(BytesBuilder builder, int value) {
  builder.add([
    value & 0xff,
    (value >> 8) & 0xff,
    (value >> 16) & 0xff,
    (value >> 24) & 0xff,
  ]);
}

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}
