import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../domain/models.dart';

Future<void> showServerEditor(
  BuildContext context,
  AppController controller, [
  ServerProfile? existing,
]) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) =>
        _ServerEditorSheet(controller: controller, existing: existing),
  );
}

class _ServerEditorSheet extends StatefulWidget {
  const _ServerEditorSheet({required this.controller, this.existing});

  final AppController controller;
  final ServerProfile? existing;

  @override
  State<_ServerEditorSheet> createState() => _ServerEditorSheetState();
}

class _ServerEditorSheetState extends State<_ServerEditorSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _secret;
  late final TextEditingController _passphrase;
  late final TextEditingController _directory;
  String _authType = 'password';
  bool _clearPassphrase = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final profile = widget.existing;
    _name = TextEditingController(text: profile?.name);
    _host = TextEditingController(text: profile?.host);
    _port = TextEditingController(text: '${profile?.port ?? 22}');
    _username = TextEditingController(text: profile?.username);
    _secret = TextEditingController();
    _passphrase = TextEditingController();
    _directory = TextEditingController(text: profile?.defaultWorkingDirectory);
    _authType = profile?.authType ?? 'password';
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _secret.dispose();
    _passphrase.dispose();
    _directory.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _SheetFrame(
      child: Form(
        key: _formKey,
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(
              widget.existing == null ? '添加目标服务器' : '编辑目标服务器',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: '名称'),
              validator: _required,
            ),
            TextFormField(
              controller: _host,
              decoration: const InputDecoration(labelText: '主机地址'),
              validator: _required,
            ),
            TextFormField(
              controller: _port,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'SSH 端口'),
              validator: _portValidator,
            ),
            TextFormField(
              controller: _username,
              decoration: const InputDecoration(labelText: '用户名'),
              validator: _required,
            ),
            DropdownButtonFormField<String>(
              initialValue: _authType,
              decoration: const InputDecoration(labelText: '认证方式'),
              items: const [
                DropdownMenuItem(value: 'password', child: Text('密码')),
                DropdownMenuItem(value: 'privateKey', child: Text('私钥 PEM')),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    if (value != _authType) {
                      _secret.clear();
                      if (value != 'privateKey') _passphrase.clear();
                    }
                    _authType = value;
                    if (value != 'privateKey') _clearPassphrase = false;
                  });
                }
              },
            ),
            TextFormField(
              controller: _secret,
              obscureText: _authType == 'password',
              maxLines: _authType == 'privateKey' ? 4 : 1,
              decoration: InputDecoration(
                labelText: _authType == 'password' ? 'SSH 密码' : '私钥 PEM',
                hintText: widget.existing == null ? null : '留空则保留已有凭据',
              ),
              validator: (value) {
                if (widget.existing == null && (value?.isEmpty ?? true)) {
                  return '请输入密码或私钥';
                }
                return null;
              },
            ),
            if (_authType == 'privateKey') ...[
              TextFormField(
                controller: _passphrase,
                enabled: !_clearPassphrase,
                obscureText: true,
                decoration: const InputDecoration(labelText: '私钥口令（可选）'),
              ),
              if (widget.existing?.credentialPassphraseRef != null)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('清除已有私钥口令'),
                  value: _clearPassphrase,
                  onChanged: (value) =>
                      setState(() => _clearPassphrase = value ?? false),
                ),
            ],
            TextFormField(
              controller: _directory,
              decoration: const InputDecoration(labelText: '默认工作目录'),
            ),
            const SizedBox(height: 8),
            Text(
              '密码和私钥只保存在手机安全存储，不会发送给 AI。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.controller.saveServer(
        existing: widget.existing,
        name: _name.text.trim(),
        host: _host.text.trim(),
        port: int.parse(_port.text),
        username: _username.text.trim(),
        secret: _secret.text,
        workingDirectory: _directory.text.trim(),
        authType: _authType,
        passphrase: _passphrase.text,
        clearPassphrase: _clearPassphrase,
      );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$error';
        });
      }
    }
  }
}

Future<void> showProviderEditor(
  BuildContext context,
  AppController controller, [
  ProviderProfile? existing,
]) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) =>
        _ProviderEditorSheet(controller: controller, existing: existing),
  );
}

class _ProviderEditorSheet extends StatefulWidget {
  const _ProviderEditorSheet({required this.controller, this.existing});

  final AppController controller;
  final ProviderProfile? existing;

  @override
  State<_ProviderEditorSheet> createState() => _ProviderEditorSheetState();
}

class _ProviderEditorSheetState extends State<_ProviderEditorSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  late final TextEditingController _secret;
  String _reasoningEffort = 'default';
  String _wireApi = 'responses';
  String _contextWindowMode = defaultContextWindowMode;
  bool _isDefault = false;
  bool _saving = false;
  bool _loadingModels = false;
  List<String> _models = const [];
  Map<String, ProviderModelMetadata> _modelMetadata = const {};
  String? _error;

  @override
  void initState() {
    super.initState();
    final profile = widget.existing;
    _name = TextEditingController(text: profile?.name);
    _baseUrl = TextEditingController(text: profile?.baseUrl);
    _model = TextEditingController(text: profile?.model);
    _secret = TextEditingController();
    _reasoningEffort = profile?.reasoningEffort ?? 'default';
    _wireApi = profile?.wireApi ?? 'responses';
    _contextWindowMode = normalizeContextWindowMode(profile?.contextWindowMode);
    _isDefault = profile?.isDefault ?? false;
    _modelMetadata = profile?.modelMetadata ?? const {};
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _model.dispose();
    _secret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _SheetFrame(
      child: Form(
        key: _formKey,
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(
              widget.existing == null ? '添加 AI 供应商' : '编辑 AI 供应商',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _ProviderPresetButton(
                  label: 'WFL AI',
                  onPressed: () => _applyPreset(
                    name: 'WFL AI',
                    baseUrl: 'https://api.ai-pixel.online/v1',
                    model: 'gpt-5.6-luna',
                    wireApi: 'responses',
                  ),
                ),
                _ProviderPresetButton(
                  label: 'DeepSeek',
                  onPressed: () => _applyPreset(
                    name: 'DeepSeek',
                    baseUrl: 'https://api.deepseek.com/v1',
                    model: 'deepseek-chat',
                    wireApi: 'chat-completions',
                  ),
                ),
                _ProviderPresetButton(
                  label: 'OpenCode',
                  onPressed: () => _applyPreset(
                    name: 'OpenCode',
                    baseUrl: 'https://opencode.ai/zen/go/v1',
                    model: '',
                    wireApi: 'chat-completions',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: '名称'),
              validator: _required,
            ),
            TextFormField(
              controller: _baseUrl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'Base URL'),
              validator: _required,
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _model,
                    decoration: const InputDecoration(labelText: '默认模型'),
                    validator: _required,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '读取模型列表',
                  onPressed: _loadingModels ? null : _loadModels,
                  icon: _loadingModels
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
              ],
            ),
            if (_models.isNotEmpty)
              DropdownButtonFormField<String>(
                initialValue: _models.contains(_model.text)
                    ? _model.text
                    : null,
                decoration: const InputDecoration(labelText: '已发现模型'),
                items: [
                  for (final model in _models)
                    DropdownMenuItem(value: model, child: Text(model)),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _model.text = value);
                },
              ),
            DropdownButtonFormField<String>(
              initialValue: wireApiOptions.contains(_wireApi)
                  ? _wireApi
                  : 'responses',
              decoration: const InputDecoration(labelText: '协议'),
              items: [
                for (final api in wireApiOptions)
                  DropdownMenuItem(value: api, child: Text(wireApiLabel(api))),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _wireApi = value);
              },
            ),
            DropdownButtonFormField<String>(
              initialValue: _reasoningEffort,
              decoration: const InputDecoration(labelText: '默认推理强度'),
              items: [
                for (final effort in reasoningEffortOptions)
                  DropdownMenuItem(
                    value: effort,
                    child: Text('${reasoningEffortLabel(effort)}（$effort）'),
                  ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _reasoningEffort = value);
              },
            ),
            DropdownButtonFormField<String>(
              initialValue: _contextWindowMode,
              decoration: const InputDecoration(labelText: '上下文窗口'),
              items: [
                for (final mode in contextWindowModeOptions)
                  DropdownMenuItem(
                    value: mode,
                    child: Text(contextWindowModeLabel(mode)),
                  ),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => _contextWindowMode = value);
                }
              },
            ),
            Text(
              '默认使用 Codex 的 context_window；扩展使用模型提供的 '
              'max_context_window。模型没有更大上限时两档相同。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            TextFormField(
              controller: _secret,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'API Key',
                hintText: widget.existing == null ? null : '留空则保留已有 Key',
              ),
              validator: (value) {
                if (widget.existing == null && (value?.isEmpty ?? true)) {
                  return '请输入 API Key';
                }
                return null;
              },
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('设为默认供应商'),
              value: _isDefault,
              onChanged: (value) => setState(() => _isDefault = value),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.controller.saveProvider(
        existing: widget.existing,
        name: _name.text.trim(),
        baseUrl: _baseUrl.text.trim(),
        model: _model.text.trim(),
        reasoningEffort: _reasoningEffort,
        wireApi: _wireApi,
        contextWindowMode: _contextWindowMode,
        secret: _secret.text,
        isDefault: _isDefault,
        modelMetadata: _modelMetadata,
      );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$error';
        });
      }
    }
  }

  Future<void> _loadModels() async {
    final profile = ProviderProfile(
      id: widget.existing?.id ?? 'model-test',
      name: _name.text.trim().isEmpty ? '模型测试' : _name.text.trim(),
      baseUrl: _baseUrl.text.trim(),
      model: _model.text.trim().isEmpty ? 'unknown' : _model.text.trim(),
      reasoningEffort: _reasoningEffort,
      wireApi: _wireApi,
      contextWindowMode: _contextWindowMode,
      apiKeyRef: widget.existing?.apiKeyRef,
      isDefault: _isDefault,
    );
    setState(() {
      _loadingModels = true;
      _error = null;
    });
    try {
      final metadata = await widget.controller.loadProviderModelMetadata(
        profile,
        secret: _secret.text.isEmpty ? null : _secret.text,
      );
      if (mounted) {
        setState(() {
          _models = [for (final item in metadata) item.model];
          _modelMetadata = {
            ..._modelMetadata,
            for (final item in metadata)
              item.model: _modelMetadata[item.model]?.mergedWith(item) ?? item,
          };
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '读取模型失败：$error');
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  void _applyPreset({
    required String name,
    required String baseUrl,
    required String model,
    required String wireApi,
  }) {
    setState(() {
      _name.text = name;
      _baseUrl.text = baseUrl;
      _model.text = model;
      _wireApi = wireApi;
    });
  }
}

class _ProviderPresetButton extends StatelessWidget {
  const _ProviderPresetButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10),
      ),
      child: Text(label),
    );
  }
}

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: child,
    );
  }
}

String? _required(String? value) {
  return value == null || value.trim().isEmpty ? '必填' : null;
}

String? _portValidator(String? value) {
  final port = int.tryParse(value ?? '');
  return port != null && port > 0 && port <= 65535 ? null : '请输入有效端口';
}
