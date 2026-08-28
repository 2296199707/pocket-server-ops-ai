import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/agent/agent_tools.dart';
import 'package:mobile_agent/domain/models.dart';
import 'package:mobile_agent/local/document_export.dart';
import 'package:mobile_agent/local/project_files.dart';

void main() {
  test('exports formatted text as a readable DOCX package', () {
    final bytes = const DocumentExportService().exportDocx(
      fileName: '报告.md',
      content: '''# 报告标题

正文 **重点** [[color=#ff0000]]红色[[/color]]。

- 第一项
1. 第二项

| 名称 | 值 |
| --- | --- |
| CPU | 5% |
''',
    );
    final files = _readStoredZip(bytes);

    expect(bytes.sublist(0, 2), [0x50, 0x4b]);
    expect(
      files.keys,
      containsAll(<String>[
        '[Content_Types].xml',
        '_rels/.rels',
        'word/document.xml',
        'word/styles.xml',
      ]),
    );
    final document = files['word/document.xml']!;
    expect(document, contains('报告标题'));
    expect(document, contains('w:color w:val="FF0000"'));
    expect(document, contains('<w:tbl>'));
    expect(document, contains('CPU'));
    expect(document, contains('重点'));
  });

  test('HTML headings, colors, and tables are converted', () {
    final bytes = const DocumentExportService().exportDocx(
      fileName: '报告.html',
      content: '''<h1>HTML 标题</h1>
<p><span style="color: rgb(0, 128, 0)">绿色文字</span></p>
<table><tr><th>项目</th><th>状态</th></tr><tr><td>服务</td><td>正常</td></tr></table>''',
    );
    final document = _readStoredZip(bytes)['word/document.xml']!;

    expect(document, contains('HTML 标题'));
    expect(document, contains('w:color w:val="008000"'));
    expect(document, contains('服务'));
    expect(document, contains('<w:tbl>'));
  });

  test('non-document source names remain text-compatible', () {
    expect(isDocumentSourceFile('notes.txt'), isTrue);
    expect(isDocumentSourceFile('paper.md'), isTrue);
    expect(isDocumentSourceFile('paper.html'), isTrue);
    expect(isDocumentSourceFile('paper.dart'), isFalse);
  });

  test(
    'project Agent exposes DOCX export only when the module is enabled',
    () async {
      final root = Directory(
        '/www/mobile-agent-document-${DateTime.now().microsecondsSinceEpoch}',
      );
      final project = Project(
        id: 'document-project',
        name: '文档项目',
        localPath: root.path,
      );
      const files = ProjectFileStore();
      try {
        await files.ensureRoot(project);
        await files.writeText(project, 'report.md', '# 标题\n\n正文');
        final enabledTools = ProjectAgentTools(
          project,
          files,
          documentModuleEnabled: true,
        ).tools;
        final exportTool = enabledTools.firstWhere(
          (tool) => tool.definition.name == 'document.export_docx',
        );
        final result = await exportTool.call({'source_path': 'report.md'});
        expect(result, containsPair('output_path', 'report.docx'));
        final output = File('${root.path}/report.docx');
        expect(await output.exists(), isTrue);
        expect((await output.readAsBytes()).sublist(0, 2), [0x50, 0x4b]);

        final disabledTools = ProjectAgentTools(
          project,
          files,
          documentModuleEnabled: false,
        ).tools;
        expect(
          disabledTools.where(
            (tool) => tool.definition.name == 'document.export_docx',
          ),
          isEmpty,
        );
      } finally {
        if (await root.exists()) await root.delete(recursive: true);
      }
    },
  );
}

Map<String, String> _readStoredZip(Uint8List bytes) {
  final result = <String, String>{};
  var offset = 0;
  while (offset + 30 <= bytes.length && _u32(bytes, offset) == 0x04034b50) {
    final compressedSize = _u32(bytes, offset + 18);
    final nameLength = _u16(bytes, offset + 26);
    final extraLength = _u16(bytes, offset + 28);
    final nameStart = offset + 30;
    final dataStart = nameStart + nameLength + extraLength;
    final dataEnd = dataStart + compressedSize;
    final name = utf8.decode(bytes.sublist(nameStart, dataStart - extraLength));
    result[name] = utf8.decode(bytes.sublist(dataStart, dataEnd));
    offset = dataEnd;
  }
  return result;
}

int _u16(Uint8List bytes, int offset) {
  return bytes[offset] | (bytes[offset + 1] << 8);
}

int _u32(Uint8List bytes, int offset) {
  return bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
}
