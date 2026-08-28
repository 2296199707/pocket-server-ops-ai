import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_agent/agent/tool_display.dart';

void main() {
  test('uses the real terminal command in the compact summary', () {
    const arguments = {'command': 'npm run build'};

    expect(toolArgumentSummary('terminal.exec', arguments), 'npm run build');
    expect(toolActionSummary('terminal.exec', arguments), '执行 npm run build');
  });

  test('uses the file target in the compact summary and overlay action', () {
    const arguments = {'path': '/var/www/index.html'};

    expect(toolArgumentSummary('file.write', arguments), '/var/www/index.html');
    expect(toolActionSummary('file.write', arguments), '写入 index.html');
  });

  test('keeps long command summaries on one compact line', () {
    final command = 'npm ${'run '.padRight(120, 'x')}build';
    final summary = toolArgumentSummary('terminal.exec', {'command': command});

    expect(summary.length, lessThanOrEqualTo(72));
    expect(summary, isNot(contains('\n')));
    expect(summary, endsWith('...'));
  });
}
