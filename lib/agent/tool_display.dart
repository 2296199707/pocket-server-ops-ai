/// Small, user-facing summaries for tool activity.
///
/// These values are derived from the actual tool call arguments. They are
/// intentionally short because they are used in both the chat timeline and
/// the cross-app overlay.
String toolArgumentSummary(Object? name, Object? arguments) {
  final toolName = name is String ? name : '';
  final values = arguments is Map ? arguments : const <Object?, Object?>{};

  String? value(String key) {
    final item = values[key];
    if (item is String && item.trim().isNotEmpty) return item.trim();
    return null;
  }

  if (toolName.startsWith('terminal.')) {
    return _compactLine(
      value('command') ?? value('input') ?? value('process_id'),
    );
  }
  if (toolName == 'server.download_to_project') {
    final remote = value('remote_path');
    final project = value('project_path');
    if (remote != null && project != null) {
      return _compactLine('$remote -> $project');
    }
    return _compactLine(remote ?? project);
  }
  if (toolName == 'server.upload_from_project') {
    final project = value('project_path');
    final remote = value('remote_path');
    if (project != null && remote != null) {
      return _compactLine('$project -> $remote');
    }
    return _compactLine(project ?? remote);
  }
  for (final key in const [
    'path',
    'entrypoint',
    'working_directory',
    'prompt',
  ]) {
    final item = value(key);
    if (item != null) return _compactLine(item);
  }
  return _compactLine(value('content') ?? value('old') ?? value('new'));
}

String toolActionSummary(Object? name, Object? arguments) {
  final toolName = name is String ? name : '';
  final values = arguments is Map ? arguments : const <Object?, Object?>{};

  String? value(String key) {
    final item = values[key];
    if (item is String && item.trim().isNotEmpty) return item.trim();
    return null;
  }

  if (toolName == 'terminal.poll') return '查看进程';
  if (toolName == 'terminal.write') return '输入终端';
  if (toolName == 'terminal.stop') return '停止进程';
  if (toolName.startsWith('terminal.')) {
    final command = value('command');
    return '执行 ${_compactLine(command ?? '命令', 40)}';
  }
  if (toolName == 'image.generate') return '生成图片';
  if (toolName == 'local.test_web') return '测试页面';
  if (toolName.startsWith('preview.')) return '预览页面';
  if (toolName == 'local.request_access') return '申请文件权限';

  final path =
      value('path') ??
      value('project_path') ??
      value('remote_path') ??
      value('entrypoint');
  final target = path == null ? '文件' : _lastPathPart(path);
  if (toolName == 'server.download_to_project') return '下载 $target';
  if (toolName == 'server.upload_from_project') return '上传 $target';
  if (toolName.endsWith('.read')) return '查看 $target';
  if (toolName.endsWith('.list')) return '浏览 $target';
  if (toolName.endsWith('.write')) return '写入 $target';
  if (toolName.endsWith('.replace')) return '修改 $target';

  final detail = toolArgumentSummary(toolName, arguments);
  return detail.isEmpty ? '调用 ${toolName.isEmpty ? '工具' : toolName}' : detail;
}

String _lastPathPart(String value) {
  final normalized = value.trim().replaceAll(RegExp(r'[/\\]+$'), '');
  if (normalized.isEmpty) return '文件';
  final parts = normalized.split(RegExp(r'[/\\]'));
  return _compactLine(parts.last, 32);
}

String _compactLine(String? value, [int maxLength = 72]) {
  if (value == null) return '';
  final compact = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (compact.length <= maxLength) return compact;
  return '${compact.substring(0, maxLength - 3)}...';
}
