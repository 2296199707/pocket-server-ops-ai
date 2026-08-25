import 'dart:async';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../domain/models.dart';
import '../local/project_files.dart';

class ProjectFileManagerPage extends StatefulWidget {
  const ProjectFileManagerPage({
    required this.controller,
    required this.project,
    this.initialPath,
    super.key,
  });

  final AppController controller;
  final Project project;
  final String? initialPath;

  @override
  State<ProjectFileManagerPage> createState() => _ProjectFileManagerPageState();
}

class _ProjectFileManagerPageState extends State<ProjectFileManagerPage> {
  late final TextEditingController _path;
  final Map<String, String> _textCache = {};
  List<ProjectFileEntry> _entries = const [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final initial = _normalizePath(widget.initialPath ?? '');
    _path = TextEditingController(text: _displayPath(initial));
    final cached = widget.controller.cachedProjectDirectory(
      widget.project,
      initial,
    );
    if (cached == null) {
      unawaited(_load());
    } else {
      _entries = cached;
      _loading = true;
      unawaited(_refresh(initial));
    }
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentPath = _normalizePath(_path.text);
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.project.name} · 文件'),
        actions: [
          IconButton(
            tooltip: '新建文件',
            onPressed: _loading ? null : _createFile,
            icon: const Icon(Icons.note_add_outlined),
          ),
          IconButton(
            tooltip: '新建文件夹',
            onPressed: _loading ? null : _createDirectory,
            icon: const Icon(Icons.create_new_folder_outlined),
          ),
          IconButton(
            tooltip: '刷新目录',
            onPressed: _loading ? null : () => _load(forceRefresh: true),
            icon: _loading
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Row(
              children: [
                IconButton(
                  tooltip: '返回上级目录',
                  onPressed: _loading || currentPath.isEmpty ? null : _goParent,
                  icon: const Icon(Icons.arrow_upward),
                ),
                Expanded(
                  child: TextField(
                    controller: _path,
                    enabled: !_loading,
                    textInputAction: TextInputAction.go,
                    onSubmitted: (_) => _load(),
                    decoration: const InputDecoration(
                      labelText: '项目路径',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '打开目录',
                  onPressed: _loading ? null : _load,
                  icon: const Icon(Icons.arrow_forward),
                ),
              ],
            ),
          ),
          if (_error != null)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.errorContainer,
              padding: const EdgeInsets.all(12),
              child: Text(_error!),
            ),
          Expanded(
            child: _loading && _entries.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _entries.isEmpty
                ? const Center(child: Text('目录为空'))
                : ListView.separated(
                    itemCount: _entries.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final entry = _entries[index];
                      return ListTile(
                        leading: Icon(
                          entry.isDirectory
                              ? Icons.folder_outlined
                              : Icons.description_outlined,
                        ),
                        title: Text(
                          entry.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: entry.isDirectory
                            ? const Text('文件夹')
                            : Text(_formatSize(entry.size)),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _open(entry),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _load({bool forceRefresh = false}) async {
    final path = _normalizePath(_path.text);
    final cached = widget.controller.cachedProjectDirectory(
      widget.project,
      path,
    );
    if (!forceRefresh && cached != null) {
      if (mounted) {
        setState(() {
          _entries = cached;
          _error = null;
          _loading = true;
        });
      }
      await _refresh(path);
      return;
    }
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    await _refresh(path, forceRefresh: forceRefresh);
  }

  Future<void> _refresh(String path, {bool forceRefresh = true}) async {
    try {
      final entries = await widget.controller.listProjectDirectory(
        widget.project,
        path,
        forceRefresh: forceRefresh,
      );
      if (mounted && _normalizePath(_path.text) == path) {
        setState(() => _entries = entries);
      }
    } catch (error) {
      if (mounted && _normalizePath(_path.text) == path) {
        setState(
          () => _error = _entries.isEmpty
              ? '读取项目目录失败：$error'
              : '刷新失败，继续显示缓存：$error',
        );
      }
    } finally {
      if (mounted && _normalizePath(_path.text) == path) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _open(ProjectFileEntry entry) async {
    if (entry.isDirectory) {
      _path.text = _displayPath(entry.path);
      await _load();
      return;
    }
    final cached = _textCache[entry.path];
    final saved = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => ProjectFileEditorPage(
          controller: widget.controller,
          project: widget.project,
          path: entry.path,
          name: entry.name,
          initialContent: cached,
        ),
      ),
    );
    if (saved != null) _textCache[entry.path] = saved;
    if (mounted) unawaited(_load(forceRefresh: true));
  }

  void _goParent() {
    final path = _normalizePath(_path.text);
    if (path.isEmpty) return;
    final separator = path.lastIndexOf('/');
    final parent = separator < 0 ? '' : path.substring(0, separator);
    _path.text = _displayPath(parent);
    unawaited(_load());
  }

  Future<void> _createFile() async {
    final name = await _askName('新建文件', '文件名');
    if (name == null || name.trim().isEmpty) return;
    try {
      await widget.controller.createProjectFile(
        widget.project,
        _joinPath(_normalizePath(_path.text), name),
      );
      if (mounted) await _load(forceRefresh: true);
    } catch (error) {
      if (mounted) setState(() => _error = '新建文件失败：$error');
    }
  }

  Future<void> _createDirectory() async {
    final name = await _askName('新建文件夹', '文件夹名称');
    if (name == null || name.trim().isEmpty) return;
    try {
      await widget.controller.createProjectDirectory(
        widget.project,
        _joinPath(_normalizePath(_path.text), name),
      );
      if (mounted) await _load(forceRefresh: true);
    } catch (error) {
      if (mounted) setState(() => _error = '新建文件夹失败：$error');
    }
  }

  Future<String?> _askName(String title, String label) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('创建'),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }
}

class ProjectFileEditorPage extends StatefulWidget {
  const ProjectFileEditorPage({
    required this.controller,
    required this.project,
    required this.path,
    required this.name,
    this.initialContent,
    super.key,
  });

  final AppController controller;
  final Project project;
  final String path;
  final String name;
  final String? initialContent;

  @override
  State<ProjectFileEditorPage> createState() => _ProjectFileEditorPageState();
}

class _ProjectFileEditorPageState extends State<ProjectFileEditorPage> {
  late final TextEditingController _content;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _content = TextEditingController(text: widget.initialContent ?? '');
    if (widget.initialContent == null) {
      unawaited(_load());
    } else {
      _loading = false;
    }
  }

  @override
  void dispose() {
    _content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '保存文件',
            onPressed: _loading || _saving ? null : _save,
            icon: _saving
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_error != null)
                  Container(
                    width: double.infinity,
                    color: Theme.of(context).colorScheme.errorContainer,
                    padding: const EdgeInsets.all(12),
                    child: Text(_error!),
                  ),
                Expanded(
                  child: TextField(
                    controller: _content,
                    expands: true,
                    maxLines: null,
                    minLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    decoration: const InputDecoration(
                      hintText: '文本内容',
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.all(12),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Future<void> _load() async {
    try {
      final value = await widget.controller.readProjectFile(
        widget.project,
        widget.path,
      );
      if (mounted) {
        _content.text = value;
        setState(() => _loading = false);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '读取文件失败：$error';
        });
      }
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.controller.writeProjectFile(
        widget.project,
        widget.path,
        _content.text,
      );
      if (mounted) Navigator.pop(context, _content.text);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '保存文件失败：$error';
        });
      }
    }
  }
}

String _normalizePath(String value) {
  final path = value.trim().replaceAll('\\', '/');
  if (path.isEmpty || path == '/' || path == '.') return '';
  return path.startsWith('/') ? path.substring(1) : path;
}

String _displayPath(String value) => value.isEmpty ? '/' : value;

String _joinPath(String directory, String name) {
  final cleanName = name.trim();
  return directory.isEmpty ? cleanName : '$directory/$cleanName';
}

String _formatSize(int? bytes) {
  if (bytes == null) return '大小未知';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
